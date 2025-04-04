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
  /// Throws an exception if the instance does not exist or is not yet started.
  Future<R> sendRequest<R>(int instanceId, Action action) {
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

    final index = instance.isolateIndex;
    final request = Request(instanceId, action);

    sendPorts[index].send(request);

    final completer = Completer<R>();
    requestCompleters[request.id] = completer;

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
