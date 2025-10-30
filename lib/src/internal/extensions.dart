import 'dart:async';
import 'dart:isolate';

import '../enums.dart';
import '../exceptions.dart';
import '../isolate_pool.dart';
import '../pooled_instance.dart';
import 'messages.dart';

extension IsolatePoolExtensions on IsolatePool {
  /// Sends a request to an instance in the pool.
  ///
  /// This method sends an action to a specific instance in the pool and returns
  /// a future that completes with the result of the action.
  ///
  /// Parameters:
  /// - [instanceId]: The ID of the instance to send the request to
  /// - [action]: The action to send to the instance
  /// - [isolateIndex]: Optional index of the isolate to execute the action on.
  ///   If specified, this overrides the isolate where the instance was created.
  ///   If not specified or negative, the instance's original isolate is used.
  ///
  /// Throws exceptions if:
  /// - The instance does not exist
  /// - The instance is not yet started
  /// - The pool has been stopped
  /// - The specified isolate index is invalid
  Future<R> sendRequest<R>(int instanceId, Action action, [int? isolateIndex]) async {
    isolateIndex ??= -1;

    if (state == IsolatePoolState.stopped) {
      throw IsolatePoolStoppedException('Isolate pool has been stopped, cannot send request');
    }

    if (!pooledInstances.containsKey(instanceId)) {
      throw NoSuchIsolateInstanceException('Cannot send request to non-existing instance, instanceId $instanceId');
    }

    final instance = pooledInstances[instanceId]!;

    if (instance.state == PooledInstanceStatus.starting) {
      throw IsolateNotYetStartedException('Cannot send request to instance in Starting state, instanceId $instanceId');
    }

    // Use the specified isolate index if provided, otherwise use the instance's original isolate
    final targetIsolate = (isolateIndex >= 0) ? isolateIndex : instance.isolateIndex;

    // Validate the isolate index
    if (targetIsolate > mainToWorkerSendPorts.length - 1) {
      throw IsolatePoolException(
        "Invalid isolate index $targetIsolate (only ${mainToWorkerSendPorts.length} isolates available). Valid indices are 0...${mainToWorkerSendPorts.length - 1}",
      );
    }

    // Warning: Cross-isolate call detection
    if (isolateIndex >= 0 && isolateIndex != instance.isolateIndex) {
      print('⚠️ Warning: Attempting to call instance $instanceId on isolate $targetIsolate, '
          'but instance was created in isolate ${instance.isolateIndex}. '
          'This may fail if the instance does not exist in the target isolate.');
    }

    if (healthConfig.enabled && healthConfig.checkBeforeDispatching) {
      final isHealthy = await ensureIsolateHealthyInternal(targetIsolate);
      if (!isHealthy) {
        throw IsolateDeadException(
          targetIsolate,
          'Isolate #$targetIsolate hosting instance $instanceId is not responsive',
        );
      }
    }

    final request = Request(instanceId, action);

    // print('[Sending PooledInstanceRequest to isolate $targetIsolate]');

    mainToWorkerSendPorts[targetIsolate]!.send(request);

    final completer = Completer<R>();
    requestCompleters[request.id] = completer;

    // Track which instance this request belongs to (for proper cleanup on isolate death)
    trackRequestToInstanceInternal(request.id, instanceId);

    return completer.future;
  }
}

abstract class InternalPooledInstance {
  late SendPort _sendPort;

  /// The [SendPort] of the isolate where this instance is executed.
  // ignore: unnecessary_getters_setters
  SendPort get sendPort => _sendPort;

  /// @nodoc
  ///
  /// Internal method to set the send port.
  /// This method is only intended for internal use by the isolate_pool_2 package.
  ///
  /// WARNING: Do not call this method from your application code.
  set sendPort(SendPort port) => _sendPort = port;
}

extension DynamicX on dynamic {
  R let<R>(R Function(dynamic it) func) {
    if (this != null) return func(this);
    return this as R;
  }

  R also<R>(R Function(dynamic it) func) {
    return func(this);
  }
}

extension FunctionObjX<T> on T {
  R let<R>(R Function(T it) func) {
    if (this != null) return func(this);
    return this as R;
  }

  R also<R>(R Function(T it) func) {
    return func(this);
  }
}
