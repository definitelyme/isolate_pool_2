import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'enums.dart';
import 'exceptions.dart';
import 'internal/messages.dart';
import 'internal/worker.dart';
import 'pooled_instance.dart';
import 'pooled_job.dart';

/// Creates and manages a pool of isolates for parallel processing.
///
/// The isolate pool creates and starts a given number of isolates and
/// provides facilities for:
/// 1. Scheduling one-off jobs ([PooledJob])
/// 2. Creating persistent instances ([PooledInstance]) in the isolates
///
/// Jobs are one-time operations that execute and return a result.
/// Pooled instances persist in the isolates, can maintain state, and
/// respond to multiple calls.
class IsolatePool {
  /// Number of isolates in the pool.
  final int numberOfIsolates;

  final Map<int, Isolate> _isolates = {};
  final List<bool> _isolateBusyWithJob = [];
  final Map<int, PooledJobRequest> _jobs = {};
  int _lastJobStartedIndex = 0;
  final Map<int, Completer> _jobCompleters = {};
  final Map<int, InstanceMapEntry> _pooledInstances = {};
  final Map<int, Completer> _requestCompleters = {};
  final Map<int, Completer<PooledInstanceProxy>> _creationCompleters = {};

  int _isolatesStarted = 0;
  double _avgMicroseconds = 0;

  final Map<String, ReceivePort> _poolReceivePorts = {};
  final Map<String, SendPort> _poolSendPorts = {};
  final Map<String, ReceivePort> _poolErrorReceivePorts = {};
  final Map<String, SendPort> _poolErrorSendPorts = {};

  IsolatePoolState _state = IsolatePoolState.notStarted;
  final Completer _started = Completer();

  /// Creates a new [IsolatePool] with the specified number of isolates.
  ///
  /// The pool is initially in the [IsolatePoolState.notStarted] state.
  /// Call [start] to start the pool before using it.
  IsolatePool(this.numberOfIsolates);

  /// Current state of the isolate pool.
  IsolatePoolState get state => _state;

  /// Future that completes when the pool has started.
  ///
  /// You can await this future to ensure the pool is ready before using it.
  Future get started => _started.future;

  /// Map of pooled instances, keyed by instance ID.
  Map<int, InstanceMapEntry> get pooledInstances => _pooledInstances;

  /// Map of request completers, keyed by request ID.
  Map<int, Completer> get requestCompleters => _requestCompleters;

  /// Number of pooled instances currently managed by this pool.
  int get numberOfPooledInstances => _pooledInstances.length;

  /// Number of pending requests awaiting response.
  int get numberOfPendingRequests => _requestCompleters.length;

  /// Maps of receive ports for each isolate, keyed by debug name.
  Map<String, Stream<dynamic>> get receivePortsMap => _poolReceivePorts;

  /// Maps of error receive ports for each isolate, keyed by debug name.
  Map<String, Stream<dynamic>> get errorReceivePortsMap => _poolErrorReceivePorts;

  /// Maps of send ports for each isolate, keyed by debug name.
  Map<String, SendPort> get sendPortsMap => _poolSendPorts;

  /// List of send ports for all running isolates.
  ///
  /// Can be used to directly send messages to these isolates.
  /// Send ports are guaranteed to be in the same order as the isolates.
  List<SendPort> get sendPorts => _poolSendPorts.values.whereType<SendPort>().toList();

  /// Returns the isolate index where the given instance is running.
  ///
  /// Returns -1 if the instance is not found.
  int indexOfInstance(PooledInstanceProxy instance) {
    if (!_pooledInstances.containsKey(instance.instanceId)) return -1;
    return _pooledInstances[instance.instanceId]!.isolateIndex;
  }

  /// Check if a PooledInstance is initialized and ready to receive calls
  bool isInstanceReady(PooledInstanceProxy instance) {
    return indexOfInstance(instance) != -1 && instance.instanceId != 0 && state == IsolatePoolState.started;
  }

  /// Starts the isolate pool.
  ///
  /// Parameters:
  /// - [init]: Optional function to initialize each isolate's environment
  /// - [errorsAreFatal]: If true, errors in isolates propagate to the main isolate
  /// - [debugLabel]: Function to generate debug labels for isolates
  /// - [initializationPolicy]: Controls whether isolates start sequentially or concurrently
  ///
  /// Throws if:
  /// - [init] is not a top-level function or static method
  /// - Initializing an isolate fails
  Future<void> start({
    FutureOr<void> Function()? init,
    bool errorsAreFatal = false,
    String Function(int)? debugLabel,
    InitializationPolicy policy = InitializationPolicy.concurrent,
  }) async {
    print('Creating a pool of $numberOfIsolates running isolates');

    _isolatesStarted = 0;
    _avgMicroseconds = 0;

    final last = Completer();
    final futures = <int, Future<Isolate>>{};
    final stopWatches = <int, Stopwatch>{};

    for (var i = 0; i < numberOfIsolates; i++) {
      _isolateBusyWithJob.add(false);

      final debugName = debugLabel?.call(i) ?? 'pooled_isolate_$i';

      final rp = ReceivePort();
      final receivePort = rp.asBroadcastStream();
      _poolReceivePorts[debugName] = rp;
      _poolSendPorts[debugName] = rp.sendPort;

      final errorRp = ReceivePort();
      _poolErrorReceivePorts[debugName] = errorRp;
      final errorSendPort = _poolErrorSendPorts[debugName] = errorRp.sendPort;

      final sw = Stopwatch();

      if (policy == InitializationPolicy.concurrent) {
        sw.start();
      } else {
        stopWatches.putIfAbsent(i, () => sw);
      }

      final params = PooledIsolateParams(
        rp.sendPort,
        errorSendPort,
        i,
        sw,
        initFunc: init,
        policy: policy,
        debugName: debugName,
      );

      futures.putIfAbsent(
        i,
        () => Isolate.spawn<PooledIsolateParams>(
          pooledIsolateBody,
          params,
          errorsAreFatal: errorsAreFatal,
          debugName: debugName,
          onError: errorSendPort,
          paused: policy == InitializationPolicy.sequential,
        ),
      );

      receivePort.listen((data) {
        if (_state == IsolatePoolState.stopped) {
          // print('Received isolate message when pool is already stopped');
          errorSendPort.send(IsolatePoolStoppedException(
            'Isolate pool has been stopped, cannot receive messages. Type: ${data.runtimeType}',
          ));
          return;
        }

        switch (data) {
          case CreationResponse():
            _processCreationResponse(data);
          case Request():
            _processRequest(data);
          case Response():
            processResponse(data, _requestCompleters);
          case PooledIsolateParams():
            _processIsolateStartResult(data, last);

            if (policy == InitializationPolicy.sequential) {
              final thisIsolateIndex = data.isolateIndex;
              final nextIsolateIndex = data.nextIsolateIndex;
              final thisIsolateSw = stopWatches[thisIsolateIndex];

              thisIsolateSw?.stop();

              print('✅ Isolate #$thisIsolateIndex initialized, '
                  'took ${thisIsolateSw?.elapsedMilliseconds} milliseconds');

              if (nextIsolateIndex == null) return;

              if (nextIsolateIndex == thisIsolateIndex + 1 && nextIsolateIndex < numberOfIsolates) {
                final nextIsolate = _isolates[nextIsolateIndex];
                stopWatches[nextIsolateIndex]?.start();
                nextIsolate?.resume(nextIsolate.pauseCapability!);
              }
            }
          case PooledJobResult():
            _processJobResult(data);
        }
      });
    }

    final spawnSw = Stopwatch()..start();

    for (final entry in futures.entries) {
      final isolate = await entry.value;

      _isolates.putIfAbsent(entry.key, () => isolate);

      // Resume only the first isolate for sequential initialization
      if (entry.key == 0 && policy == InitializationPolicy.sequential) {
        stopWatches[entry.key]?.start();
        isolate.resume(isolate.pauseCapability!);
      }
    }

    spawnSw.stop();

    print('spawn() called on $numberOfIsolates isolates (${spawnSw.elapsedMicroseconds} microseconds)');

    return last.future;
  }

  /// Schedules a job on one of the pool's isolates.
  ///
  /// Parameters:
  /// - [job]: The job to schedule
  /// - [isolateIndex]: Index of isolate to run the job on, or -1 for any available isolate
  ///
  /// Returns a [Future] that completes with the job result or throws if the job fails.
  /// If the job fails, the error is propagated with its original type and a combined
  /// stack trace showing both where the error originated in the isolate and where it
  /// was caught in the main isolate.
  ///
  /// Throws [IsolatePoolStoppedException] if the pool has been stopped.
  Future<T> scheduleJob<T>(PooledJob<T> job, [int? isolateIndex]) {
    isolateIndex ??= -1;

    if (state == IsolatePoolState.stopped) {
      throw IsolatePoolStoppedException('Isolate pool has been stopped, cannot schedule a job');
    }

    final jobIndex = _lastJobStartedIndex++;
    final completer = Completer<T>();

    _jobCompleters[jobIndex] = completer;
    _jobs[jobIndex] = PooledJobRequest<T>(job, jobIndex, isolateIndex);

    _runJobWithVacantIsolate();

    return completer.future;
  }

  /// Creates a persistent instance in one of the pool's isolates.
  ///
  /// Parameters:
  /// - [instance]: The instance to create
  /// - [callback]: Optional callback function for the instance to call back to the main isolate
  /// - [isolateIndex]: Optional index of the isolate to create the instance in (defaults to -1,
  ///   which means the instance will be created in the isolate with the fewest instances)
  ///
  /// Returns a [Future] that completes with a proxy to the instance.
  Future<PooledInstanceProxy<T>> addInstance<T>(
    PooledInstance instance, {
    PooledCallback<T>? callback,
    int? isolateIndex,
  }) async {
    isolateIndex ??= -1;

    if (state == IsolatePoolState.stopped) {
      throw IsolatePoolStoppedException('Isolate pool has been stopped, cannot add an instance');
    }

    // If a specific isolate is requested and it's valid, use it
    int targetIsolateIndex;
    if (isolateIndex >= 0 && isolateIndex < numberOfIsolates) {
      targetIsolateIndex = isolateIndex;
    } else if (isolateIndex >= numberOfIsolates) {
      throw IsolatePoolException(
        "Invalid isolate index $isolateIndex (only $numberOfIsolates isolates available). Valid indices are 0...${numberOfIsolates - 1}.",
      );
    } else {
      // Otherwise find the isolate with the fewest instances
      var min = 10000000; // max number of instances that can be assigned to a single isolate
      var minIndex = 0; // index of isolate with the least instances

      // Find the isolate with the fewest instances
      for (var i = 0; i < numberOfIsolates; i++) {
        final instanceCount = _pooledInstances.entries.where((e) => e.value.isolateIndex == i).fold(0, (int prev, _) => prev + 1);

        if (instanceCount < min) {
          min = instanceCount;
          minIndex = i;
        }
      }

      targetIsolateIndex = minIndex;
    }

    final sendPort = sendPorts[targetIsolateIndex];
    final proxy = PooledInstanceProxy(
      instanceId: instance.instanceId,
      isolateId: targetIsolateIndex,
      pool: this,
      remoteCallback: callback,
      sendPort: sendPort,
    );

    _pooledInstances[proxy.instanceId] = InstanceMapEntry<T>(proxy, targetIsolateIndex);

    final completer = Completer<PooledInstanceProxy<T>>();
    _creationCompleters[proxy.instanceId] = completer;

    sendPort.send(instance); // Send the instance to the isolate

    return completer.future;
  }

  /// Removes an instance from the pool.
  ///
  /// Makes the instance available for garbage collection.
  /// Throws [NoSuchIsolateInstanceException] if the instance is not found.
  void destroyInstance(PooledInstanceProxy instance) {
    final index = indexOfInstance(instance);
    if (index == -1) {
      throw NoSuchIsolateInstanceException('Cannot find instance with ID ${instance.instanceId} to destroy it');
    }

    sendPorts[index].send(DestroyRequest(instance.instanceId));
    _pooledInstances.remove(instance.instanceId);
  }

  /// Stops the isolate pool.
  ///
  /// All isolates are killed, and pending jobs and requests are cancelled.
  /// After calling this method, the pool cannot be restarted.
  void stop() {
    for (final isolate in _isolates.values) {
      isolate.kill();

      for (final completer in _jobCompleters.values) {
        if (!completer.isCompleted) {
          completer.completeError(IsolatePoolJobCancelledException('Isolate pool stopped upon request, cancelling jobs'));
        }
      }
      _jobCompleters.clear();

      for (final completer in _creationCompleters.values) {
        if (!completer.isCompleted) {
          completer
              .completeError(IsolatePoolJobCancelledException('Isolate pool stopped upon request, cancelling instance creation requests'));
        }
      }
      _creationCompleters.clear();

      for (final completer in _requestCompleters.values) {
        if (!completer.isCompleted) {
          completer.completeError(IsolatePoolJobCancelledException('Isolate pool stopped upon request, cancelling pending request'));
        }
      }
      _requestCompleters.clear();

      for (final receivePort in _poolReceivePorts.values) {
        receivePort.close();
      }
    }

    _poolReceivePorts.clear();
    _poolSendPorts.clear();
    _state = IsolatePoolState.stopped;
  }

  void _processCreationResponse(CreationResponse response) {
    if (!_creationCompleters.containsKey(response.instanceId)) {
      print('Invalid instance ID ${response.instanceId} received in creation response');
      return;
    }

    final completer = _creationCompleters[response.instanceId]!;

    if (response.error != null) {
      if (!completer.isCompleted) {
        completer.completeError(response.error);
      }
      _creationCompleters.remove(response.instanceId);
      _pooledInstances.remove(response.instanceId);
    } else {
      if (!completer.isCompleted) {
        completer.complete(_pooledInstances[response.instanceId]!.instance);
      }
      _creationCompleters.remove(response.instanceId);
      _pooledInstances[response.instanceId]!.state = PooledInstanceStatus.started;
    }
  }

  void _processIsolateStartResult(PooledIsolateParams params, Completer completer) {
    _isolatesStarted++;
    _avgMicroseconds += params.stopwatch.elapsedMicroseconds;

    // CRITICAL: Update the SendPort to the one received from the worker isolate
    // This is essential for two-way communication
    _poolSendPorts[params.debugName] = params.sendPort;

    if (params.initializationError != null) {
      final error = params.initializationError;

      // print('Isolate #${params.isolateIndex} encountered initialization error: $error');

      // Still continue with pool startup to avoid hanging
      if (!_errorHandlers.containsKey(IsolateErrorType.initialization)) {
        // No custom error handler, propagate the error to the started completer
        if (!_started.isCompleted) {
          _started.completeError(error);
        }
      } else {
        _errorHandlers[IsolateErrorType.initialization]?.call(error);
      }
    }

    if (_isolatesStarted == numberOfIsolates) {
      _avgMicroseconds /= numberOfIsolates;
      print('Average time to start an isolate: $_avgMicroseconds microseconds');

      if (!completer.isCompleted) {
        completer.complete();
      }

      if (!_started.isCompleted) {
        _started.complete();
      }

      _state = IsolatePoolState.started;

      // Setup global error handling for isolate errors
      for (final errorPort in _poolErrorReceivePorts.values) {
        errorPort.listen(_handleIsolateError);
      }

      if (_jobs.isNotEmpty) {
        print('[🔄 Processing ${_jobs.length} jobs that were queued before isolates were ready]');
        _runJobWithVacantIsolate();
      }
    }
  }

  void _processJobResult(PooledJobResult result) {
    _isolateBusyWithJob[result.isolateIndex] = false; // Mark isolate as available

    assert(_jobCompleters.containsKey(result.jobIndex));

    final completer = _jobCompleters[result.jobIndex];

    if (completer == null) {
      print('Job result received for non-existent job (ID: ${result.jobIndex})');
      return;
    }

    if (!completer.isCompleted) {
      if (result.error == null) {
        completer.complete(result.data);
      } else {
        final error = result.error;
        final stackTrace = result.stackTrace ?? StackTrace.current;
        final callerStackTrace = StackTrace.current;

        // Direct error propagation based on error type
        if (error is IsolateError) {
          // Create a combined stack trace for better debugging
          final combinedError = error.withCombinedStackTrace(callerStackTrace);

          // Propagate the original error to preserve its type
          completer.completeError(combinedError.unwrappedError, combinedError.originalStackTrace);
        } else {
          // For other error types, propagate directly
          completer.completeError(error, stackTrace);
        }
      }
    }

    if (_jobs.containsKey(result.jobIndex)) {
      _jobs.remove(result.jobIndex);
      _jobCompleters.remove(result.jobIndex);
    }

    _runJobWithVacantIsolate(); // Schedule the next job
  }

  Future<void> _processRequest(Request request) async {
    if (!_pooledInstances.containsKey(request.instanceId)) {
      print('Received request for unknown instance ${request.instanceId}');
      return;
    }

    final instance = _pooledInstances[request.instanceId]!;
    final sendPort = sendPorts[instance.isolateIndex];

    if (instance.instance.remoteCallback == null) {
      print('Instance ${request.instanceId} does not have a callback initialized');
      return;
    }

    try {
      final result = instance.instance.remoteCallback!(request.action);
      final response = Response(request.id, result, null);
      sendPort.send(response);
    } catch (e) {
      final response = Response(request.id, null, e);
      sendPort.send(response);
    }
  }

  void _runJobWithVacantIsolate() {
    if (state != IsolatePoolState.started) {
      throw IsolatePoolException("WARNING: Attempting to run job when pool is not started (state: $state)");
    }

    if (sendPorts.isEmpty) {
      throw IsolatePoolException("ERROR: No send ports available! Isolates may not be properly initialized.");
    }

    var availableIsolateIndex = _isolateBusyWithJob.indexOf(false);
    final pendingJobs = _jobs.entries.where((i) => i.value.started == false);

    // print("Available isolate index: $availableIsolateIndex, Pending jobs: ${pendingJobs.length}, Total isolates: ${_isolates.length}");

    if (pendingJobs.isEmpty) {
      print("[🟧 Job queue is empty.]");
      return;
    }

    if (availableIsolateIndex == -1) {
      // Even if all isolates are busy, pick any random isolate to process the job
      final randomIndex = math.Random().nextInt(sendPorts.length);
      availableIsolateIndex = randomIndex;
    }

    var job = pendingJobs.first.value;

    // Use the isolate index specified in the job if it exists, otherwise use the available isolate index
    if (job.isolateIndex < 0 && availableIsolateIndex > -1) {
      if (availableIsolateIndex > sendPorts.length - 1) {
        throw BadResponseReceivedException(
          "ERROR: Invalid isolate index $availableIsolateIndex (only ${sendPorts.length} isolates available). Valid indices are 0...${sendPorts.length - 1}.",
          StackTrace.current,
        );
      }

      job = job.copyWith(isolateIndex: availableIsolateIndex);
    } else if (job.isolateIndex > sendPorts.length - 1) {
      throw BadResponseReceivedException(
        "ERROR: Invalid isolate index ${job.isolateIndex} (only ${sendPorts.length} isolates available). Valid indices are 0...${sendPorts.length - 1}.",
        StackTrace.current,
      );
    }

    if (pendingJobs.isNotEmpty) {
      try {
        job = job.copyWith(started: true);

        print("[Sending job ${job.jobIndex} to isolate ${job.isolateIndex}]");

        // Mark the isolate as busy before sending the job
        _isolateBusyWithJob[job.isolateIndex] = true;

        final sendPort = sendPorts[job.isolateIndex];
        sendPort.send(job);
      } catch (e) {
        print("❌ ERROR sending job to isolate: $e");
        job = job.copyWith(started: false);
        _isolateBusyWithJob[job.isolateIndex] = false;
      }

      // Update the job in the map
      _jobs[job.jobIndex] = job;
    }
  }

  // Add these properties and methods for error handling

  // Map of error handlers by type
  final Map<IsolateErrorType, void Function(Object error)> _errorHandlers = {};

  /// Sets a custom error handler for specific types of isolate errors.
  ///
  /// When an error of the specified [errorType] occurs in any isolate,
  /// the [handler] function will be called with the error object.
  ///
  /// This allows for centralized error handling and reporting without
  /// having to catch errors in each individual job or instance method.
  void setErrorHandler(IsolateErrorType errorType, void Function(Object error) handler) {
    _errorHandlers[errorType] = handler;
  }

  /// Removes a previously set error handler for the specified [errorType].
  void removeErrorHandler(IsolateErrorType errorType) {
    _errorHandlers.remove(errorType);
  }

  /// Clears all custom error handlers.
  void clearErrorHandlers() {
    _errorHandlers.clear();
  }

  /// Central handler for errors received from isolates via error ports.
  void _handleIsolateError(dynamic error) {
    // Check if this is an IsolateError with a wrapped error
    final unwrappedError = error is IsolateError ? error.unwrappedError : error;
    final errorStackTrace = error is IsolateError ? error.originalStackTrace : StackTrace.current;

    IsolateErrorType errorType;

    if (error is IsolateInitializationException) {
      errorType = IsolateErrorType.initialization;
    } else if (error is IsolateError) {
      // Determine error type based on error message content
      if (error.message.contains('job execution')) {
        errorType = IsolateErrorType.job;
      } else if (error.message.contains('instance')) {
        errorType = IsolateErrorType.instance;
      } else if (error.message.contains('request')) {
        errorType = IsolateErrorType.communication;
      } else {
        errorType = IsolateErrorType.unknown;
      }
    } else {
      errorType = IsolateErrorType.unknown;
    }

    // Call specific error handler if registered
    if (_errorHandlers.containsKey(errorType)) {
      try {
        // Pass the original error, not the wrapper
        _errorHandlers[errorType]?.call(unwrappedError);
      } catch (e) {
        print('Error in custom error handler for $errorType: $e');
      }
    } else if (_errorHandlers.containsKey(IsolateErrorType.all)) {
      try {
        // Pass the original error, not the wrapper
        _errorHandlers[IsolateErrorType.all]?.call(unwrappedError);
      } catch (e) {
        print('Error in global error handler: $e');
      }
    } else {
      // No handler registered, just print the error
      print('❌ Unhandled isolate error of type $errorType: $unwrappedError\n$errorStackTrace');
    }
  }
}
