import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'enums.dart';
import 'exceptions.dart';
import 'health_config.dart';
import 'internal/messages.dart';
import 'internal/worker.dart';
import 'isolate_pool_validation.dart';
import 'pooled_instance.dart';
import 'pooled_job.dart';

part 'internal/health_info.dart';

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
  /// Creates a new [IsolatePool] with the specified number of isolates.
  ///
  /// The pool is initially in the [IsolatePoolState.notStarted] state.
  /// Call [start] to start the pool before using it.
  ///
  /// Optionally provide [healthConfig] to customize health checking behavior.
  /// By default, health checking is enabled with sensible defaults.
  IsolatePool(
    this.numberOfIsolates, {
    this.healthConfig = const IsolateHealthConfig(),
  });

  /// Configuration for isolate health checking.
  final IsolateHealthConfig healthConfig;

  /// Number of isolates in the pool.
  final int numberOfIsolates;

  final Map<int, Completer<PooledInstanceProxy>> _creationCompleters = {};
  final List<bool> _isolateBusyWithJob = [];
  final Map<int, Isolate> _isolates = {};
  final Map<int, Completer> _jobCompleters = {};
  final Map<int, PooledJobRequest> _jobs = {};
  final Map<String, ReceivePort> _mainReceivePorts = {};
  final Map<String, Stream<dynamic>> _mainReceivePortsStreams = {};
  final Map<int, SendPort?> _mainToWorkerSendPorts = {};
  final Map<String, ReceivePort> _poolErrorReceivePorts = {};
  final Map<String, Stream<dynamic>> _poolErrorReceivePortsStreams = {};
  final Map<String, SendPort> _poolErrorSendPorts = {};
  final Map<int, InstanceMapEntry> _pooledInstances = {};
  final Map<int, Completer> _requestCompleters = {};
  final Map<int, int> _requestToInstance = {}; // Maps requestId -> instanceId
  final Completer _started = Completer();
  final Map<String, SendPort> _workerToMainSendPorts = {};

  double _avgMicroseconds = 0;
  // Add these properties and methods for error handling

  // Map of error handlers by type
  final Map<IsolateErrorType, void Function(Object error)> _errorHandlers = {};

  // Health tracking
  final Map<int, IsolateHealthInfo> _isolateHealth = {};

  int _isolatesStarted = 0;
  int _lastJobStartedIndex = 0;
  IsolatePoolState _state = IsolatePoolState.notStarted;

  /// Maps of Streams of error messages from each isolate, keyed by debug name.
  Map<String, Stream<dynamic>> get errorReceivePortsStreamsMap => _poolErrorReceivePortsStreams;

  /// Gets health status information for all isolates.
  ///
  /// Returns a map of isolate index to health information.
  Map<int, IsolateHealthInfo> get healthStatus {
    if (!healthConfig.enabled) return {};

    return Map.fromEntries(
      _isolateHealth.entries.map((entry) {
        final health = entry.value;
        return MapEntry(entry.key, health);
      }),
    );
  }

  /// Get map of receive ports in the main isolate.
  ///
  /// WARNING: The Streams in this map are not broadcast Streams. DO NOT ATTACH LISTENERS TO THEM.
  ///
  /// Use [receivePortsStreamsMap] instead.
  Map<String, ReceivePort> get mainReceivePorts => Map.from(_mainReceivePorts);

  /// Get map of send ports from main isolate to worker isolates
  Map<int, SendPort?> get mainToWorkerSendPorts => _mainToWorkerSendPorts;

  /// Number of pending requests awaiting response.
  int get numberOfPendingRequests => _requestCompleters.length;

  /// Number of pooled instances currently managed by this pool.
  int get numberOfPooledInstances => _pooledInstances.length;

  /// Map of pooled instances, keyed by instance ID.
  Map<int, InstanceMapEntry> get pooledInstances => _pooledInstances;

  /// Maps of Streams of messages from each isolate, keyed by debug name.
  Map<String, Stream<dynamic>> get receivePortsStreamsMap => Map.from(_mainReceivePortsStreams);

  /// Map of request completers, keyed by request ID.
  Map<int, Completer> get requestCompleters => _requestCompleters;

  /// List of send ports for all running isolates.
  ///
  /// Can be used to directly send messages to these isolates.
  /// Send ports are guaranteed to be in the same order as the isolates.
  List<SendPort> get sendPorts => _mainToWorkerSendPorts.values.whereType<SendPort>().toList();

  /// Future that completes when the pool has started.
  ///
  /// You can await this future to ensure the pool is ready before using it.
  Future get started => _started.future;

  /// Current state of the isolate pool.
  IsolatePoolState get state => _state;

  /// Get map of send ports from worker isolates back to main isolate
  Map<String, SendPort> get workerToMainSendPorts => _workerToMainSendPorts;

  /// Returns the isolate index where the given instance is running.
  ///
  /// Returns -1 if the instance is not found.
  int indexOfInstance(PooledInstanceProxy instance) {
    if (!_pooledInstances.containsKey(instance.instanceId)) return -1;
    return _pooledInstances[instance.instanceId]!.isolateIndex;
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
      _mainToWorkerSendPorts[i] = null;

      final debugName = debugLabel?.call(i) ?? 'pooled_isolate_$i';

      final receivePort = ReceivePort();
      _mainReceivePorts[debugName] = receivePort;
      _mainReceivePortsStreams[debugName] = receivePort.asBroadcastStream();
      _workerToMainSendPorts[debugName] = receivePort.sendPort;

      final errorRp = ReceivePort();
      _poolErrorReceivePorts[debugName] = errorRp;
      _poolErrorReceivePortsStreams[debugName] = errorRp.asBroadcastStream();
      final errorSendPort = _poolErrorSendPorts[debugName] = errorRp.sendPort;

      final sw = Stopwatch();

      if (policy == InitializationPolicy.concurrent) {
        sw.start();
      } else {
        stopWatches.putIfAbsent(i, () => sw);
      }

      final params = PooledIsolateParams(
        receivePort.sendPort,
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

      receivePortsStreamsMap[debugName]!.listen((data) {
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
            // Clean up request tracking (response completes the request)
            _requestToInstance.remove(data.requestId);
            // Update health status - successful response means isolate is healthy
            _updateHealthSuccess(data.isolateIndex);
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

      // Initialize health tracking for this isolate
      if (healthConfig.enabled) {
        _isolateHealth.putIfAbsent(entry.key, () => IsolateHealthInfo._(isolateIndex: entry.key));
      }

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
  /// Throws [IsolatePoolException] if the specified isolate index is invalid.
  Future<T> scheduleJob<T>(PooledJob<T> job, [int? isolateIndex]) {
    isolateIndex ??= -1;

    if (state == IsolatePoolState.stopped) {
      throw IsolatePoolStoppedException('Isolate pool has been stopped, cannot schedule a job');
    }

    // Validate isolate index early
    if (isolateIndex >= numberOfIsolates) {
      throw IsolatePoolException(
        'Invalid isolate index $isolateIndex (only $numberOfIsolates isolates available). Valid indices are 0...${numberOfIsolates - 1}, or -1 to use any available isolate.',
      );
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
    // Validate that the instance can be sent to an isolate
    final validationErrors = instance.validateForIsolate();

    if (validationErrors.isNotEmpty) {
      throw IsolatePoolException(
        'Instance contains validation errors:\n'
        '${validationErrors.join('\n')}',
        StackTrace.current,
      );
    }

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

    final sendPort = _mainToWorkerSendPorts[targetIsolateIndex];
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

    if (healthConfig.enabled && healthConfig.checkBeforeDispatching) {
      final isHealthy = await _ensureIsolateHealthy(targetIsolateIndex);
      if (!isHealthy) {
        _creationCompleters.remove(proxy.instanceId);
        _pooledInstances.remove(proxy.instanceId);
        throw IsolateDeadException(
          targetIsolateIndex,
          'Cannot create instance on isolate #$targetIsolateIndex - isolate is not responsive',
        );
      }
    }

    try {
      sendPort!.send(instance); // Send the instance to the isolate
    } catch (e, st) {
      completer.completeError(e);
      _creationCompleters.remove(proxy.instanceId);
      _pooledInstances.remove(proxy.instanceId);

      print('[DEBUG]: error sending instance to isolate: $e\n$st');

      rethrow;
    }

    return completer.future;
  }

  /// Removes an instance from the pool.
  ///
  /// Makes the instance available for garbage collection.
  ///
  /// Parameters:
  /// - [instance]: The instance proxy to destroy
  /// - [isolate]: Optional index of the isolate where the instance should be destroyed.
  ///   If not specified, uses the isolate where the instance was originally created.
  ///
  /// Throws [NoSuchIsolateInstanceException] if the instance is not found.
  /// Throws [IsolatePoolException] if the specified isolate index is invalid.
  void destroyInstance(PooledInstanceProxy instance, {int? isolate}) {
    // Guard: Check if already destroyed or never existed
    if (!_pooledInstances.containsKey(instance.instanceId)) {
      print('⚠️ Warning: Instance ${instance.instanceId} already destroyed or does not exist. Skipping destroyInstance call.');
      return; // Silently ignore instead of throwing
    }

    // Determine target isolate index
    final targetIndex = isolate ?? indexOfInstance(instance);

    if (targetIndex == -1) {
      throw NoSuchIsolateInstanceException(
        'Cannot find instance with ID ${instance.instanceId} to destroy it!',
      );
    }

    // Validate isolate index
    if (targetIndex < 0 || targetIndex >= _mainToWorkerSendPorts.length) {
      throw IsolatePoolException(
        'Invalid isolate index $targetIndex (only ${_mainToWorkerSendPorts.length} isolates available). Valid indices are 0...${_mainToWorkerSendPorts.length - 1}.',
      );
    }

    _mainToWorkerSendPorts[targetIndex]!.send(DestroyRequest(instance.instanceId));
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

      for (final receivePort in _mainReceivePorts.values) {
        receivePort.close();
      }
    }

    _mainReceivePorts.clear();
    _workerToMainSendPorts.clear();
    _mainToWorkerSendPorts.clear();
    _state = IsolatePoolState.stopped;
  }

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

      final isolateIndex = _pooledInstances[response.instanceId]!.isolateIndex;
      _updateHealthSuccess(isolateIndex);
    }
  }

  void _processIsolateStartResult(PooledIsolateParams params, Completer completer) {
    _isolatesStarted++;
    _avgMicroseconds += params.stopwatch.elapsedMicroseconds;

    // CRITICAL: Update the SendPort to the one received from the worker isolate
    // This is essential for two-way communication
    _mainToWorkerSendPorts[params.isolateIndex] = params.sendPort;

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

    // Update health status - successful job completion means isolate is healthy
    _updateHealthSuccess(result.isolateIndex);

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
    final sendPort = _mainToWorkerSendPorts[instance.isolateIndex];

    if (instance.instance.remoteCallback == null) {
      print('Instance ${request.instanceId} does not have a callback initialized');
      return;
    }

    try {
      final result = instance.instance.remoteCallback!(request.action);
      final response = Response(request.id, result, null);
      sendPort!.send(response);
    } catch (e) {
      final response = Response(request.id, null, e);
      sendPort!.send(response);
    }
  }

  void _runJobWithVacantIsolate() {
    if (state != IsolatePoolState.started) {
      throw IsolatePoolException("WARNING: Attempting to run job when pool is not started (state: $state)");
    }

    if (_mainToWorkerSendPorts.isEmpty) {
      throw IsolatePoolException("ERROR: No send ports available! Isolates may not be properly initialized.");
    }

    var availableIsolateIndex = _isolateBusyWithJob.indexOf(false);
    final pendingJobs = _jobs.entries.where((i) => i.value.started == false);

    // print("Available isolate index: $availableIsolateIndex, Pending jobs: ${pendingJobs.length}, Total isolates: ${_isolates.length}");

    if (pendingJobs.isEmpty) {
      // print("[🟧 Job queue is empty.]");
      return;
    }

    if (availableIsolateIndex == -1) {
      // Even if all isolates are busy, pick any random isolate to process the job
      final randomIndex = math.Random().nextInt(_mainToWorkerSendPorts.length);
      availableIsolateIndex = randomIndex;
    }

    var job = pendingJobs.first.value;

    // Use the isolate index specified in the job if it exists, otherwise use the available isolate index
    if (job.isolateIndex < 0 && availableIsolateIndex > -1) {
      if (availableIsolateIndex > _mainToWorkerSendPorts.length - 1) {
        throw BadResponseReceivedException(
          "ERROR: Invalid isolate index $availableIsolateIndex (only ${_mainToWorkerSendPorts.length} isolates available). Valid indices are 0...${_mainToWorkerSendPorts.length - 1}.",
          StackTrace.current,
        );
      }

      job = job.copyWith(isolateIndex: availableIsolateIndex);
    } else if (job.isolateIndex > _mainToWorkerSendPorts.length - 1) {
      throw BadResponseReceivedException(
        "ERROR: Invalid isolate index ${job.isolateIndex} (only ${_mainToWorkerSendPorts.length} isolates available). Valid indices are 0...${_mainToWorkerSendPorts.length - 1}.",
        StackTrace.current,
      );
    }

    if (pendingJobs.isNotEmpty) {
      if (healthConfig.enabled && healthConfig.checkBeforeDispatching) {
        _ensureIsolateHealthy(job.isolateIndex).then((isHealthy) {
          if (!isHealthy) {
            print("❌ Isolate ${job.isolateIndex} is not healthy, failing job ${job.jobIndex}");
            _handleDeadIsolate(job.isolateIndex);

            // Job completer should already be failed by _handleDeadIsolate
            // Remove the job from pending
            _jobs.remove(job.jobIndex);
            return;
          }

          _dispatchJobToIsolate(job);
        });
      } else {
        _dispatchJobToIsolate(job);
      }
    }
  }

  /// Dispatches a job to its assigned isolate.
  void _dispatchJobToIsolate(PooledJobRequest job) {
    try {
      job = job.copyWith(started: true);

      print("[Sending job ${job.jobIndex} to isolate ${job.isolateIndex}]");

      // Mark the isolate as busy before sending the job
      _isolateBusyWithJob[job.isolateIndex] = true;

      final sendPort = _mainToWorkerSendPorts[job.isolateIndex];
      sendPort!.send(job);
    } catch (e) {
      print("❌ ERROR sending job to isolate: $e");
      job = job.copyWith(started: false);
      _isolateBusyWithJob[job.isolateIndex] = false;
    }

    // Update the job in the map
    _jobs[job.jobIndex] = job;
  }

  /// Central handler for errors received from isolates via error ports.
  void _handleIsolateError(dynamic error) async {
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

    // Health check: verify if isolate is actually dead after error
    if (healthConfig.enabled && error is IsolateError) {
      final isolateIndex = error.isolateIndex;
      final isHealthy = await _pingIsolate(isolateIndex);
      if (!isHealthy) {
        print('⚠️  Isolate #$isolateIndex is unresponsive after error, marking as dead');
        _handleDeadIsolate(isolateIndex);
      }
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

  // ============================================================================
  // Public Health API
  // ============================================================================

  /// Checks if a specific isolate is currently healthy.
  ///
  /// Returns `true` if the isolate is responsive and not marked as dead.
  /// Returns `false` if the isolate is dead, or if the index is invalid.
  bool isIsolateHealthy(int isolateIndex) {
    if (!healthConfig.enabled) return true;
    final health = _isolateHealth[isolateIndex];
    return health != null && !health.confirmedDead;
  }

  /// Manually triggers a health check on a specific isolate.
  ///
  /// This performs an immediate ping to verify the isolate is responsive.
  /// Returns `true` if the isolate responds, `false` otherwise.
  ///
  /// Use this when you want to explicitly verify an isolate's health
  /// outside of the normal automatic checking.
  Future<bool> pingIsolate(int isolateIndex) async {
    if (!healthConfig.enabled) return true;
    if (isolateIndex < 0 || isolateIndex >= numberOfIsolates) {
      return false;
    }
    return await _pingIsolate(isolateIndex);
  }

  // ============================================================================
  // Internal Methods (for extensions and internal use)
  // ============================================================================

  /// Internal method: Ensures isolate is healthy before use.
  ///
  /// This is exposed for use by extensions. Do not call directly from
  /// application code - use [pingIsolate] or [isIsolateHealthy] instead.
  Future<bool> ensureIsolateHealthyInternal(int isolateIndex) async {
    return await _ensureIsolateHealthy(isolateIndex);
  }

  /// Internal method: Tracks request-to-instance mapping.
  ///
  /// This is exposed for use by extensions to properly handle dead isolate cleanup.
  void trackRequestToInstanceInternal(int requestId, int instanceId) {
    _requestToInstance[requestId] = instanceId;
  }

  // ============================================================================
  // Health Checking Methods
  // ============================================================================

  /// Updates health status when an isolate successfully completes work.
  void _updateHealthSuccess(int isolateIndex) {
    if (!healthConfig.enabled) return;

    final health = _isolateHealth[isolateIndex];
    if (health == null) return;

    health._lastKnownGood = DateTime.now();
    health._consecutiveFailures = 0;
    health._confirmedDead = false;
  }

  /// Updates health status when an isolate fails a health check.
  void _updateHealthFailure(int isolateIndex) {
    if (!healthConfig.enabled) return;

    final health = _isolateHealth[isolateIndex];
    if (health == null) return;

    health._consecutiveFailures++;

    if (health.consecutiveFailures >= healthConfig.maxConsecutiveFailures) {
      health._confirmedDead = true;
    }
  }

  /// Performs a ping health check on a specific isolate.
  ///
  /// Returns `true` if the isolate responds within the timeout, `false` otherwise.
  Future<bool> _pingIsolate(int isolateIndex) async {
    final isolate = _isolates[isolateIndex];
    final sendPort = _mainToWorkerSendPorts[isolateIndex];

    if (isolate == null || sendPort == null) {
      return false;
    }

    final responsePort = ReceivePort();
    final completer = Completer<bool>();

    // Setup listener for ping response
    late StreamSubscription subscription;
    subscription = responsePort.listen((_) {
      if (!completer.isCompleted) {
        completer.complete(true);
        _updateHealthSuccess(isolateIndex);
        subscription.cancel();
        responsePort.close();
      }
    });

    // Setup timeout
    final timeoutTimer = Timer(healthConfig.pingTimeout, () {
      if (!completer.isCompleted) {
        completer.complete(false);
        _updateHealthFailure(isolateIndex);
        subscription.cancel();
        responsePort.close();
      }
    });

    try {
      // Send ping with immediate priority for quick response
      isolate.ping(responsePort.sendPort, response: null, priority: Isolate.immediate);
      final result = await completer.future;
      timeoutTimer.cancel();
      return result;
    } catch (e) {
      timeoutTimer.cancel();
      await subscription.cancel();
      responsePort.close();
      _updateHealthFailure(isolateIndex);
      return false;
    }
  }

  /// Ensures an isolate is healthy before using it.
  ///
  /// Uses smart caching: if the isolate recently completed work successfully,
  /// it's considered healthy without an explicit ping. Otherwise, performs
  /// a ping health check.
  ///
  /// Returns `true` if the isolate is healthy, `false` if it's dead or unresponsive.
  Future<bool> _ensureIsolateHealthy(int isolateIndex) async {
    if (!healthConfig.enabled) return true;

    final health = _isolateHealth[isolateIndex];
    if (health == null) return false;

    // If already confirmed dead, no need to check again
    if (health.confirmedDead) return false;

    // Check if health status is fresh (recently validated)
    final timeSinceLastGood = DateTime.now().difference(health.lastKnownGood);
    if (timeSinceLastGood < healthConfig.stalenessThreshold) {
      return true; // Recent successful activity = healthy
    }

    // Health status is stale, perform explicit ping
    return await _pingIsolate(isolateIndex);
  }

  /// Handles a dead isolate by failing pending work and triggering error handlers.
  void _handleDeadIsolate(int isolateIndex) {
    final health = _isolateHealth[isolateIndex];
    if (health == null) return;

    health._confirmedDead = true;

    // Fail all pending jobs for this isolate
    final jobsToFail = <int>[];
    for (final entry in _jobs.entries) {
      if (entry.value.isolateIndex == isolateIndex) {
        jobsToFail.add(entry.key);
      }
    }

    for (final jobId in jobsToFail) {
      final completer = _jobCompleters[jobId];
      if (completer != null && !completer.isCompleted) {
        completer.completeError(
          IsolateDeadException(
            isolateIndex,
            'Isolate #$isolateIndex is not responsive',
          ),
        );
      }
      _jobs.remove(jobId);
      _jobCompleters.remove(jobId);
    }

    // Fail all pending requests for instances on this isolate
    // First, collect instance IDs on the dead isolate
    final instancesOnDeadIsolate = <int>{};
    for (final entry in _pooledInstances.entries) {
      if (entry.value.isolateIndex == isolateIndex) {
        instancesOnDeadIsolate.add(entry.key); // entry.key is instanceId
      }
    }

    // Then, fail only requests that belong to those instances
    final requestsToFail = <int>[];
    for (final requestEntry in _requestToInstance.entries) {
      final requestId = requestEntry.key;
      final instanceId = requestEntry.value;

      if (instancesOnDeadIsolate.contains(instanceId)) {
        requestsToFail.add(requestId);
      }
    }

    for (final requestId in requestsToFail) {
      final completer = _requestCompleters[requestId];
      if (completer != null && !completer.isCompleted) {
        completer.completeError(
          IsolateDeadException(
            isolateIndex,
            'Isolate #$isolateIndex hosting the instance is not responsive',
          ),
        );
      }
      _requestCompleters.remove(requestId);
      _requestToInstance.remove(requestId); // Clean up tracking
    }

    // Call error handler if registered
    final exception = IsolateDeadException(
      isolateIndex,
      'Isolate #$isolateIndex failed health checks and is considered dead',
    );

    if (_errorHandlers.containsKey(IsolateErrorType.communication)) {
      try {
        _errorHandlers[IsolateErrorType.communication]?.call(exception);
      } catch (e) {
        print('Error in communication error handler: $e');
      }
    } else if (_errorHandlers.containsKey(IsolateErrorType.all)) {
      try {
        _errorHandlers[IsolateErrorType.all]?.call(exception);
      } catch (e) {
        print('Error in global error handler: $e');
      }
    } else {
      print('❌ Dead isolate detected: $exception');
    }
  }
}
