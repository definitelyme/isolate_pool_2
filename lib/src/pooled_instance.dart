import 'dart:async';
import 'dart:isolate';

import 'enums.dart';
import 'exceptions.dart';
import 'internal/export.dart';
import 'isolate_pool.dart';

/// Base class for actions that can be sent to pooled instances.
///
/// Action objects contain both the action type and any parameters needed
/// when calling pooled instances. Typically implemented using class inheritance
/// with specific action types as subclasses.
abstract class Action {}

/// Function signature for callbacks from the isolate pool.
typedef PooledCallback<T> = T Function(Action action);

/// Represents a persistent instance that lives in an isolate managed by [IsolatePool].
///
/// Subclass this type to define data transferred to the isolate pool
/// and logic to be executed upon initialization in the worker isolate.
abstract class PooledInstance extends InternalPooledInstance {
  /// Creates a new [PooledInstance] with a unique instance ID.
  PooledInstance() : instanceId = instanceIdCounter++;

  /// Internal instance ID
  final int instanceId;

  /// Sends an [Action] to the main isolate and returns the result.
  ///
  /// Used by implementations to communicate back to the main isolate.
  Future<R> callRemoteMethod<R>(Action action) async {
    return _sendRequest<R>(action);
  }

  /// Initializes the instance in the worker isolate.
  ///
  /// This method is called automatically when the instance is created
  /// in the worker isolate. Use it to initialize resources, load data, etc.
  Future<void> init();

  /// Cleans up resources when the instance is being destroyed.
  ///
  /// This method is called automatically when the instance is removed
  /// from the worker isolate. Override it to release any resources
  /// that need to be explicitly cleaned up.
  Future<void> dispose() async {}

  /// Processes actions received from the main isolate.
  ///
  /// This method is called whenever an action is sent to this instance.
  /// Typically implemented using a switch statement to route specific actions
  /// to appropriate handlers.
  Future<dynamic> receiveRemoteCall(Action action);

  /// Internal method to send a request back to the main isolate
  Future<R> _sendRequest<R>(Action action) {
    final request = Request(instanceId, action);
    sendPort.send(request);
    final completer = Completer<R>();
    isolateRequestCompleters[request.id] = completer;
    return completer.future;
  }
}

/// Proxy object that represents a [PooledInstance] in the main isolate.
///
/// This class is returned from [IsolatePool.addInstance] and is used to
/// communicate with the [PooledInstance] in the worker isolate via [Action] objects.
class PooledInstanceProxy<T> {
  const PooledInstanceProxy({
    required this.instanceId,
    required this.isolateId,
    required IsolatePool pool,
    required this.remoteCallback,
    SendPort? sendPort,
  })  : _pool = pool,
        _sendPort = sendPort;

  /// Internal instance ID
  final int instanceId;

  /// The index of the isolate where this instance is running
  final int isolateId;

  /// Callback function called when the worker isolate sends an action to the main isolate.
  ///
  /// If null, the worker isolate can't send actions to the main isolate.
  final PooledCallback<T>? remoteCallback;

  final SendPort? _sendPort;

  /// Reference to the pool that created this proxy
  final IsolatePool _pool;

  /// SendPort for direct communication with the isolate
  SendPort? get sendPort => _sendPort;

  /// Sends an [Action] to the remote instance and returns the result.
  ///
  /// Throws an exception if the action fails in the executing isolate
  /// or if the pool has been stopped.
  ///
  /// Parameters:
  /// - [action]: The action to send to the remote instance
  /// - [isolate]: Optional index of the isolate to execute the action on.
  ///   If not specified, the action will be executed on the isolate where the instance was created.
  ///
  /// Re-throws any exception that occurs in the executing isolate
  /// with the original exception type and a combined stack trace
  /// showing both where the error occurred in the isolate and
  /// where it was caught in the main isolate.
  Future<R> callRemoteMethod<R>(Action action, {int? isolate}) {
    isolate ??= -1;

    if (_pool.state == IsolatePoolState.stopped) {
      throw IsolatePoolStoppedException('Isolate pool has been stopped, cannot call pooled instance method');
    }

    // If no specific isolate is requested, use the one where the instance was created
    final targetIsolateIndex = isolate >= 0 ? isolate : isolateId;

    return _pool.sendRequest<R>(instanceId, action, targetIsolateIndex);
  }
}
