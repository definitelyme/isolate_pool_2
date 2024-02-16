library isolate_pool;

import 'dart:async';
import 'dart:isolate';

/// One-off operation to be queued and executed in isolate pool
/// Whatever fields are dedfined in the instance will be passed to isolate.
/// The generic type `E` determines the return type of the job.
/// Be considerate of Dart's rule defining what types can cross isolate bounaries, i.e. you will
/// have challenges with objects that wrap native resources (e.g. fil handles).
/// You may reffer to Dart's [SendPort.send] for details on the limitations.
abstract class PooledJob<E> {
  Future<E> job();
}

// Requests have global scope
int _reuestIdCounter = 0;
// instances are scoped to pools
int _instanceIdCounter = 0;
//TODO consider adding timeouts, check fulfilled requests are deleted
Map<int, Completer> _isolateRequestCompleters = {}; // requestId is key

/// Inherti when using pooled instances and defining actions.
/// Action objects are holders of action type and payload/params when calling pooled intances
abstract class Action {}

class _Request {
  final int instanceId;
  final int id;
  final Action action;
  _Request(this.instanceId, this.action) : id = _reuestIdCounter++;
}

class _Response {
  final int requestId;
  final dynamic result;
  final dynamic error;
  _Response(this.requestId, this.result, this.error);
}

/// Use this function defitition to set up callbacks from the isolate pool
typedef PooledCallbak<T> = T Function(Action action);

/// Instance of this class is returned from [IsolatePool.createInstance]
/// and is used to communication with [PooledInstance] via [Action]'s
class PooledInstanceProxy<T> {
  final int _instanceId;
  final IsolatePool _pool;
  PooledInstanceProxy._(this._instanceId, this._pool, this.remoteCallback);

  /// Pass [Action] with required params to the remote instance and get result. Re-throws expcetion
  /// should the action fail in the executing isolate
  Future<R> callRemoteMethod<R>(Action action) {
    if (_pool.state == IsolatePoolState.stoped) {
      throw 'Isolate pool has been stoped, cant call pooled instnace method';
    }
    return _pool._sendRequest<R>(_instanceId, action);
  }

  /// If not null isolate instance can send actions back to main isolate and this callback will be called
  PooledCallbak<T>? remoteCallback;
}

/// Subclass this type in order to define data transfered to isalte pool
/// and logic executed upon object being transfered to external isolate ([init method)
abstract class PooledInstance {
  final int _instanceId;
  late SendPort _sendPort;
  PooledInstance() : _instanceId = _instanceIdCounter++;
  Future<R> callRemoteMethod<R>(Action action) async {
    return _sendRequest<R>(action);
  }

  Future<R> _sendRequest<R>(Action action) {
    var request = _Request(_instanceId, action);
    _sendPort.send(request);
    var c = Completer<R>();
    _isolateRequestCompleters[request.id] = c;
    return c.future;
  }

  /// This method is called in isolate whenever a pool receives a request to create a pooled instance
  Future init();

  /// Overide this method to respond to actions, typically a `switch` statement
  /// is used to route specific actions to code bracnhes or handlers
  Future<dynamic> receiveRemoteCall(Action action);
}

class _CreationResponse {
  final int _instanceId;

  /// If null - creation went successfully
  final dynamic error;

  _CreationResponse(this._instanceId, this.error);
}

class _DestroyRequest {
  final int _instanceId;
  _DestroyRequest(this._instanceId);
}

enum _PooledInstanceStatus { starting, started }

class _InstanceMapEntry<T> {
  final PooledInstanceProxy<T> instance;
  final int isolateIndex;
  _PooledInstanceStatus state = _PooledInstanceStatus.starting;

  _InstanceMapEntry(this.instance, this.isolateIndex);
}

/// Isolate pool can be in 3 states: not started, started and stoped.
/// Stoped pool can't be restarted, create a new one instead
enum IsolatePoolState { notStarted, started, stoped }

/// Isolate pool creates and starts a given number of isolates (passed to constructor)
/// and schedules execution of single jobs (see [PooledJob]) or puts and keeps
/// their instacnes of [PooledInstance] allowing to comunicate with those.
/// Job is a one-time object that allows to schedule a single unit of computation,
/// run it on one of the isolates and return back the result. Jobs do not persist between calls.
/// Pooled instances persist in isolates, can store own state and respond to a
/// number of calls.
class IsolatePool {
  final int numberOfIsolates;
  final List<SendPort?> _isolateSendPorts = [];
  final List<Isolate> _isolates = [];

  // Job specific fields
  final List<bool> _isolateBusyWithJob = [];
  final Map<int, _PooledJobInternal> _jobs = {}; // index, job
  int lastJobStartedIndex = 0; // index of last job started
  final Map<int, Completer> jobCompleters = {}; // index, job completer

  IsolatePoolState _state = IsolatePoolState.notStarted;

  IsolatePoolState get state => _state;

  final Completer _started = Completer();

  /// A pool can be started early on upon app launch and checked latter and awaited to if not started yet
  Future get started => _started.future;

  final Map<int, _InstanceMapEntry> _pooledInstances = {};

  int get numberOfPooledInstances => _pooledInstances.length;
  int get numberOfPendingRequests => _requestCompleters.length;

  /// Returns the number of isolate the Pooled Instance lives in, -1 if instance is not found
  int indexOfPi(PooledInstanceProxy instance) {
    if (!_pooledInstances.containsKey(instance._instanceId)) return -1;
    return _pooledInstances[instance._instanceId]!.isolateIndex;
  }

  //TODO consider adding timeouts
  final Map<int, Completer> _requestCompleters = {}; // requestId is key
  Map<int, Completer<PooledInstanceProxy>> creationCompleters = {}; // instanceId is key

  /// Prepare the pool of [numberOfIsolates] isolates to be latter started by [IsolatePool.start]
  IsolatePool(this.numberOfIsolates);

  /// Schedules a job on one of pool's isolates, executes and returns the result. Re-throws expcetion
  /// should the action fail in the executing isolate
  Future<T> scheduleJob<T>(PooledJob job) {
    if (state == IsolatePoolState.stoped) {
      throw 'Isolate pool has been stoped, cant schedule a job';
    }
    _jobs[lastJobStartedIndex] = _PooledJobInternal(job, lastJobStartedIndex, -1);
    var completer = Completer<T>();
    jobCompleters[lastJobStartedIndex] = completer;
    lastJobStartedIndex++;
    _runJobWithVacantIsolate();
    return completer.future;
  }

  /// Remove the instance from internal isolate dictionary and make it available for garbage collection
  void destroyInstance(PooledInstanceProxy instance) {
    var index = indexOfPi(instance);
    if (index == -1) {
      throw 'Cant find instance with id ${instance._instanceId} among active to destroy it';
    }

    _isolateSendPorts[index]!.send(_DestroyRequest(instance._instanceId));
    _pooledInstances.remove(instance._instanceId);
  }

  /// Transfer [PooledInstance] to one of isolates, call it's [PooledInstance.init] method
  /// and make it avaialble for communication via the [PooledInstanceProxy] returned
  Future<PooledInstanceProxy<T>> addInstance<T>(PooledInstance instance, [PooledCallbak<T>? callbak]) async {
    var pi = PooledInstanceProxy<T>._(instance._instanceId, this, callbak);

    var min = 10000000; // max number of instances that can be assigned to a single isolate (theoretically)
    var minIndex = 0; // index of isolate with the least instances

    for (var i = 0; i < numberOfIsolates; i++) {
      // find the isolate with the fewest instances
      var x = _pooledInstances.entries.where((e) => e.value.isolateIndex == i).fold(0, (int previousValue, _) => previousValue + 1);
      if (x < min) {
        min = x; // sets number of instances in isolate at index [i]
        minIndex = i; // sets minIndex of isolate at index [i]
      }
    }

    _pooledInstances[pi._instanceId] = _InstanceMapEntry<T>(pi, minIndex);

    var completer = Completer<PooledInstanceProxy<T>>();
    creationCompleters[pi._instanceId] = completer;

    _isolateSendPorts[minIndex]!.send(instance); // send the [PooledInstance] to the isolate

    return completer.future;
  }

  void _runJobWithVacantIsolate() {
    var availableIsolate = _isolateBusyWithJob.indexOf(false);
    if (availableIsolate > -1 && _jobs.entries.where((j) => j.value.started == false).isNotEmpty) {
      var job = _jobs.entries.where((j) => j.value.started == false).first.value;
      job.isolateIndex = availableIsolate;
      job.started = true;
      _isolateSendPorts[availableIsolate]!.send(job);
      _isolateBusyWithJob[availableIsolate] = true;
    }
  }

  int _isolatesStarted = 0;
  double _avgMicroseconds = 0;
  List<ReceivePort> receivePorts = [];

  /// Starts the pool
  ///
  /// Params:
  ///
  /// - [init] - A function to be called on each isolate before it starts processing requests. You can use it to initialize
  ///  isolate's state, (e.g. load data from file, connect to database, etc).
  ///
  /// Throws if:
  /// - [init] is not a `top-level` function or a `static` method.
  /// - invoking init() throws
  Future start({FutureOr<void> Function()? init, bool errorsAreFatal = false}) async {
    print('Creating a pool of $numberOfIsolates running isolates');

    _isolatesStarted = 0;
    _avgMicroseconds = 0;

    var last = Completer();
    for (var i = 0; i < numberOfIsolates; i++) {
      _isolateBusyWithJob.add(false);
      _isolateSendPorts.add(null);
    }

    var spawnSw = Stopwatch();
    spawnSw.start();

    for (var i = 0; i < numberOfIsolates; i++) {
      var receivePort = ReceivePort();
      receivePorts.add(receivePort);
      var sw = Stopwatch();

      sw.start();
      var params = _PooledIsolateParams(receivePort.sendPort, i, sw, initFunc: init);

      final isolate = await Isolate.spawn<_PooledIsolateParams>(
        _pooledIsolateBody,
        params,
        errorsAreFatal: errorsAreFatal,
        debugName: 'pooled_isolate_$i',
      );

      _isolates.add(isolate);

      receivePort.listen((data) {
        if (_state == IsolatePoolState.stoped) {
          print('Received isolate message when pool is already stopped');
          return;
        }
        if (data is _CreationResponse) {
          _processCreationResponse(data);
        } else if (data is _Request) {
          _processRequest(data);
        } else if (data is _Response) {
          _processResponse(data, _requestCompleters);
        } else if (data is _PooledIsolateParams) {
          _processIsolateStartResult(data, last);
        } else if (data is _PooledJobResult) {
          _processJobResult(data);
        }
      });
    }

    spawnSw.stop();

    print('spawn() called on $numberOfIsolates isolates'
        '(${spawnSw.elapsedMicroseconds} microseconds)');

    return last.future;
  }

  void _processCreationResponse(_CreationResponse r) {
    if (!creationCompleters.containsKey(r._instanceId)) {
      print('Invalid _instanceId ${r._instanceId} receivd in _CreationRepnse');
    } else {
      var c = creationCompleters[r._instanceId]!;
      if (r.error != null) {
        if (!c.isCompleted) {
          c.completeError(r.error);
        }
        creationCompleters.remove(r._instanceId);
        _pooledInstances.remove(r._instanceId);
      } else {
        if (!c.isCompleted) {
          c.complete(_pooledInstances[r._instanceId]!.instance);
        }
        creationCompleters.remove(r._instanceId);
        _pooledInstances[r._instanceId]!.state = _PooledInstanceStatus.started;
      }
    }
  }

  void _processIsolateStartResult(_PooledIsolateParams params, Completer last) {
    _isolatesStarted++;
    _isolateSendPorts[params.isolateIndex] = params.sendPort;
    _avgMicroseconds += params.stopwatch.elapsedMicroseconds;
    if (_isolatesStarted == numberOfIsolates) {
      _avgMicroseconds /= numberOfIsolates;
      print('Avg time to complete starting an isolate is '
          '$_avgMicroseconds microseconds');
      last.complete();
      _started.complete();
      _state = IsolatePoolState.started;
    }
  }

  void _processJobResult(_PooledJobResult result) {
    _isolateBusyWithJob[result.isolateIndex] = false;
    assert(jobCompleters.containsKey(result.jobIndex));

    if (result.error == null) {
      jobCompleters[result.jobIndex]?.complete(result.result);
    } else {
      jobCompleters[result.jobIndex]?.completeError(result.error);
    }

    if (_jobs.containsKey(result.jobIndex)) {
      _jobs.remove(result.jobIndex);
      jobCompleters.remove(result.jobIndex);
    }
    _runJobWithVacantIsolate();
  }

  Future<R> _sendRequest<R>(int instanceId, Action action) {
    if (!_pooledInstances.containsKey(instanceId)) {
      throw 'Cant send request to non-existing instance, instanceId $instanceId';
    }
    var instanceMapEntry = _pooledInstances[instanceId]!;
    if (instanceMapEntry.state == _PooledInstanceStatus.starting) {
      throw 'Cant send request to instance in Starting state, instanceId $instanceId}';
    }
    var index = instanceMapEntry.isolateIndex;
    var request = _Request(instanceId, action);
    _isolateSendPorts[index]!.send(request);
    var c = Completer<R>();
    _requestCompleters[request.id] = c;
    return c.future;
  }

  Future _processRequest(_Request request) async {
    if (!_pooledInstances.containsKey(request.instanceId)) {
      print('Isolate pool received request to unknown instance ${request.instanceId}');
      return;
    }
    var i = _pooledInstances[request.instanceId]!;
    final sendPort = _isolateSendPorts[i.isolateIndex];

    if (i.instance.remoteCallback == null) {
      print('Isolate pool received request to instance ${request.instanceId} which doesnt have callback intialized');
      return;
    }

    try {
      var result = i.instance.remoteCallback!(request.action);
      var response = _Response(request.id, result, null);

      sendPort?.send(response);
    } catch (e) {
      var response = _Response(request.id, null, e);
      sendPort?.send(response);
    }
  }

  /// Throws if there're pending jobs or requests
  void stop() {
    for (var i in _isolates) {
      i.kill();
      for (var c in jobCompleters.values) {
        if (!c.isCompleted) {
          c.completeError('Isolate pool stopped upon request, cancelling jobs');
        }
      }
      jobCompleters.clear();

      for (var c in creationCompleters.values) {
        if (!c.isCompleted) {
          c.completeError('Isolate pool stopped upon request, cancelling instance creation requests');
        }
      }
      creationCompleters.clear();

      for (var c in _requestCompleters.values) {
        if (!c.isCompleted) {
          c.completeError('Isolate pool stopped upon request, cancelling pending request');
        }
      }
      _requestCompleters.clear();
      for (var rPort in receivePorts) {
        rPort.close(); // Issue #3
      }
    }

    _state = IsolatePoolState.stoped;
  }
}

void _processResponse(_Response response, [Map<int, Completer>? requestCompleters]) {
  var cc = requestCompleters ?? _isolateRequestCompleters;
  if (!cc.containsKey(response.requestId)) {
    throw 'Responnse to non-existing request (id ${response.requestId}) recevied';
  }
  var c = cc[response.requestId]!;
  if (response.error != null) {
    c.completeError(response.error);
  } else {
    c.complete(response.result);
  }
  cc.remove(response.requestId);
}

class _PooledIsolateParams<E> {
  final SendPort sendPort;
  final int isolateIndex;
  final FutureOr<void> Function()? initFunc;
  final Stopwatch stopwatch;

  _PooledIsolateParams(this.sendPort, this.isolateIndex, this.stopwatch, {this.initFunc});
}

class _PooledJobInternal {
  _PooledJobInternal(this.job, this.jobIndex, this.isolateIndex);
  final PooledJob job;
  final int jobIndex;
  int isolateIndex;
  bool started = false;
}

class _PooledJobResult {
  _PooledJobResult(this.result, this.jobIndex, this.isolateIndex);
  final dynamic result;
  final int jobIndex;
  final int isolateIndex;
  dynamic error;
}

var _workerInstances = <int, PooledInstance>{};

void _pooledIsolateBody(_PooledIsolateParams params) async {
  params.stopwatch.stop();
  print('Isolate #${params.isolateIndex} started (${params.stopwatch.elapsedMicroseconds} microseconds)');
  var isolatePort = ReceivePort();
  params.sendPort.send(_PooledIsolateParams(isolatePort.sendPort, params.isolateIndex, params.stopwatch));

  _reuestIdCounter = 1000000000 *
      (params.isolateIndex +
          1); // split counters into ranges to deal with overlaps between isolates. Theoretically after one billion requests a collision might happen
  isolatePort.listen((message) async {
    if (message is _Request) {
      var req = message;
      if (!_workerInstances.containsKey(req.instanceId)) {
        print('Isolate ${params.isolateIndex} received request to unknown instance ${req.instanceId}');
        return;
      }
      var i = _workerInstances[req.instanceId]!;
      try {
        var result = await i.receiveRemoteCall(req.action);
        var response = _Response(req.id, result, null);
        params.sendPort.send(response);
      } catch (e) {
        var response = _Response(req.id, null, e);
        params.sendPort.send(response);
      }
    } else if (message is _Response) {
      var res = message;
      if (!_isolateRequestCompleters.containsKey(res.requestId)) {
        print('Isolate ${params.isolateIndex} received response to unknown request ${res.requestId}');
        return;
      }
      _processResponse(res);
    } else if (message is PooledInstance) {
      try {
        var pw = message;
        await pw.init();
        pw._sendPort = params.sendPort;
        _workerInstances[message._instanceId] = message;
        var success = _CreationResponse(message._instanceId, null);
        params.sendPort.send(success);
      } catch (e) {
        var error = _CreationResponse(message._instanceId, e);
        params.sendPort.send(error);
      }
    } else if (message is _DestroyRequest) {
      if (!_workerInstances.containsKey(message._instanceId)) {
        print('Isolate ${params.isolateIndex} received destroy request of unknown instance ${message._instanceId}');
        return;
      }
      _workerInstances.remove(message._instanceId);
    } else if (message is _PooledJobInternal) {
      try {
        // params.stopwatch.reset();
        // params.stopwatch.start();
        //print('Job index ${message.jobIndex}');

        var result = await message.job.job();
        // params.stopwatch.stop();
        // print('Job done in ${params.stopwatch.elapsedMilliseconds} ms');
        // params.stopwatch.reset();
        // params.stopwatch.start();
        params.sendPort.send(_PooledJobResult(result, message.jobIndex, message.isolateIndex));
        // params.stopwatch.stop();
        // print('Job result sent in ${params.stopwatch.elapsedMilliseconds} ms');
      } catch (e) {
        var r = _PooledJobResult(null, message.jobIndex, message.isolateIndex);
        r.error = e;
        params.sendPort.send(r);
      }
    }
  });

  // Call init() after the isolate is started and sendPort is passed back to the main isolate
  await params.initFunc?.call();
}

class _IsolateCallbackArg<A> {
  final A value;
  _IsolateCallbackArg(this.value);
}

/// Derive from this class if you want to create isolare jobs that can call back to main isolate (e.g. report progress)
abstract class CallbackIsolateJob<R, A> {
  final bool synchronous;
  CallbackIsolateJob(this.synchronous);
  Future<R> jobAsync();
  R jobSync();
  void sendDataToCallback(A arg) {
    // Wrap arg in _IsolateCallbackArg to avoid cases when A == E
    _sendPort!.send(_IsolateCallbackArg<A>(arg));
  }

  SendPort? _sendPort;
  SendPort? _errorPort;
}

/// This class allows spawning a new isolate with callback job ([CallbackIsolateJob]) without using isolate pool
class CallbackIsolate<R, A> {
  final CallbackIsolateJob<R, A> job;
  CallbackIsolate(this.job);
  Future<R> run(Function(A arg)? callback) async {
    var completer = Completer<R>();
    var receivePort = ReceivePort();
    var errorPort = ReceivePort();

    job._sendPort = receivePort.sendPort;
    job._errorPort = errorPort.sendPort;

    var isolate = await Isolate.spawn<CallbackIsolateJob<R, A>>(_isolateBody, job, errorsAreFatal: true);

    receivePort.listen((data) {
      if (data is _IsolateCallbackArg) {
        if (callback != null) callback(data.value);
      } else if (data is R) {
        completer.complete(data);
        isolate.kill();
      }
    });

    errorPort.listen((e) {
      completer.completeError(e);
    });

    return completer.future;
  }
}

void _isolateBody(CallbackIsolateJob job) async {
  try {
    //print('Job index ${message.jobIndex}');
    var result = job.synchronous ? job.jobSync() : await job.jobAsync();
    job._sendPort!.send(result);
  } catch (e) {
    job._errorPort!.send(e);
  }
}

//                                                            │
//                         Main isolate                       │  Isolate in the pool
//                                                            │
//                         ┌─────────────────────────────┐    │
// Step 1 - Instantiate    │                             │    │     Pooled instance with params
// a decendant of          │  PooledInstance             │    │     is passed to isolate within
// PooledInstance          │                             │    │     the pool. init() method is
//                         │    - Params                 │    │     called initializing whatever
//                         │                             │    │     fileds necessary and creating
//                         └──────────────┬──────────────┘    │     whatever objects required
//                                        │                   │     (aka State)
//                                    Passed to               │
//                                        │                   │   ┌─────────────────────────────┐
//                                        │                   │   │                             │
//                         ┌──────────────┼──────────────┐    │   │  PooledInstance             │
// Step 2 - Pass the       │              │              │    │   │                             │
// PooledInstance to       │  IsolatePool │              │    │   │    - Params                 │
// isolate pool, it        │              ▼         ┌────┼────┼───►        ▼                    │
// will transfer the       │    - createInstance()──┘    │    │   │    - init()───┐             │
// object (together with   │                             │    │   │               │             │
// fields) to isolate and  └──────────────┬──────────────┘    │   │    - State ◄──┘             │
// call init(). Returned                  │                   │   │                             │
//                                     Returns                │   │    - receiveRemoteCall()    │
//                                        │                   │   │              ▲              │
//                                        │                   │   └──────────────┬──────────────┘
//                         ┌──────────────▼──────────────┐    │                  │
// Step 3 - use returned   │                             │    │                  │
// PooledInstanceProxy     │  PooledInstanceProxy        │    │                  │
// can be used to pass     │                             │    │                  │
// actions to the          │    - callRemoteMethod() ◄───┼────┼──────────────────┘
// instance in the pool    │                             │    │
//                         └──────────────▲──────────────┘    │
//                                        │                   │      Action descendants are
//                                        │                   │      passed to isolates via proxy
//                                        │                   │      instance in the main isolate.
//                                        │                   │      Pooled instance uses switch
//                         ┌──────────────┴──────────────┐    │      statement in receiveRemoteCall()
// Create a set of         │                             │    │      processing requests and returning
// Action descendants      │  Action                     │    │      results back to the requester
// defining pooled         │                             │    │
// instance capabilities,  │    - Params                 │    │
// use the with            │                             │    │
// callMethodRemote()      └─────────────────────────────┘    │
//                                                            │dart
