import 'dart:async';
import 'dart:isolate';

import 'package:isolate_pool_2/src/internal/utils.dart';

import '../enums.dart';
import '../exceptions.dart';
import '../pooled_instance.dart';
import 'export.dart';

/// Processes a response message
void processResponse(Response response, [Map<int, Completer>? requestCompleters]) {
  final completers = requestCompleters ?? isolateRequestCompleters;

  if (!completers.containsKey(response.requestId)) {
    throw BadResponseReceivedException('Response to non-existent request (ID: ${response.requestId}) received');
  }

  final completer = completers[response.requestId]!;

  if (!completer.isCompleted) {
    if (response.error != null) {
      final error = response.error;
      final stackTrace = response.stackTrace ?? StackTrace.current;
      final callerStackTrace = StackTrace.current; // Capture where the error is being caught in main isolate

      if (error is Exception || error is Error) {
        completer.completeError(error, stackTrace);
      } else if (error is IsolateError) {
        final combinedError = error.withCombinedStackTrace(callerStackTrace);
        completer.completeError(combinedError.unwrappedError, combinedError.originalStackTrace);
      } else {
        completer.completeError(IsolateError(error, response.isolateIndex, error.toString(), stackTrace), callerStackTrace);
      }
    } else {
      completer.complete(response.result);
    }
  } else {
    throw BadResponseReceivedException('Response to non-existent request (ID: ${response.requestId}) received\n'
        'This can happen if the request was already completed/cancelled.');
  }

  completers.remove(response.requestId);
}

/// Main function for the worker isolate
void pooledIsolateBody(PooledIsolateParams params) async {
  final isolatePort = ReceivePort();

  // Split counters into ranges to avoid overlaps between isolates
  requestIdCounter = 1000000000 * (params.isolateIndex + 1);

  isolatePort.listen((message) async {
    if (message is Request) {
      if (!workerInstances.containsKey(message.instanceId)) {
        final errorMsg = 'Isolate [${params.isolateIndex}] received request for unknown instance ${message.instanceId}';
        print(errorMsg);

        final error = NoSuchIsolateInstanceException(errorMsg);
        final response = Response(message.id, null, error, StackTrace.current, params.isolateIndex);
        params.sendPort.send(response);
        params.errorSendPort?.send(error);
        return;
      }

      final instance = workerInstances[message.instanceId]!;

      try {
        final result = await instance.receiveRemoteCall(message.action);
        final response = Response(message.id, result, null, null, params.isolateIndex);
        params.sendPort.send(response);
      } catch (e, st) {
        final response = Response(message.id, null, e, st, params.isolateIndex);
        params.sendPort.send(response);
        params.errorSendPort?.send(IsolateError(e, params.isolateIndex, 'Error processing request: ${e.toString()}', st));
      }
    } else if (message is Response) {
      if (!isolateRequestCompleters.containsKey(message.requestId)) {
        final errorMsg = 'Isolate ${params.isolateIndex} received response for unknown request ${message.requestId}';
        // print(errorMsg);
        params.errorSendPort?.send(BadResponseReceivedException(errorMsg, StackTrace.current));
        return;
      }

      processResponse(message);
    } else if (message is PooledInstance) {
      try {
        await message.init();
        message.sendPort = params.sendPort;
        workerInstances[message.instanceId] = message;
        params.sendPort.send(CreationResponse(message.instanceId, null));
      } catch (e, st) {
        params.sendPort.send(CreationResponse(message.instanceId, e, st));
        params.errorSendPort?.send(IsolateError(e, params.isolateIndex, 'Error creating instance: ${e.toString()}', st));
      }
    } else if (message is DestroyRequest) {
      if (!workerInstances.containsKey(message.instanceId)) {
        final errorMsg = 'Isolate ${params.isolateIndex} received destroy request for unknown instance ${message.instanceId}';
        // print(errorMsg);

        params.errorSendPort?.send(BadResponseReceivedException(errorMsg, StackTrace.current));

        // Attempt to remove the instance from the map, just to be safe
        workerInstances.remove(message.instanceId);
        return;
      }

      try {
        final instance = workerInstances[message.instanceId];
        await instance?.dispose();
      } catch (e, st) {
        // print('Error during instance disposal: $e\n$st');
        params.errorSendPort?.send(IsolateError(e, params.isolateIndex, 'Error disposing instance: ${e.toString()}', st));
      } finally {
        workerInstances.remove(message.instanceId);
      }
    } else if (message is PooledJobRequest) {
      try {
        final result = await message.job.job();
        params.sendPort.send(PooledJobResult(result, message.jobIndex, message.isolateIndex, null, null));
      } catch (e, st) {
        final error = IsolateError(e, params.isolateIndex, 'Error executing job: ${e.toString()}', st);
        params.sendPort.send(PooledJobResult(null, message.jobIndex, message.isolateIndex, error, st));
        params.errorSendPort?.send(error);
      }
    } else if (message is ExternalJob) {
      try {
        await message.job.job();
      } catch (e, st) {
        final error = IsolateError(e, params.isolateIndex, 'Error executing external job: ${e.toString()}', st);
        params.errorSendPort?.send(error);
      }
    } else {
      // print('Isolate ${params.isolateIndex} received unknown message type: ${message.runtimeType}');

      params.errorSendPort?.send(IsolateError(
        ArgumentError('Unknown message type: ${message.runtimeType}'),
        params.isolateIndex,
        'Unknown message type received',
        StackTrace.current,
      ));
    }
  });

  try {
    await params.initFunc?.call();
  } catch (e, st) {
    final error = IsolateInitializationException(params.isolateIndex, 'Error during initialization: ${e.toString()}', st);
    params.errorSendPort?.send(error);
    params.stopwatch.stop();

    // We must still send back the response to avoid deadlock, but include the error (short-circuit)
    return params.sendPort.send(params.copyWith(
      sendPort: isolatePort.sendPort,
      nextIsolateIndex: params.isolateIndex + 1,
      initializationError: error,
    ));
  }

  params.stopwatch.stop();

  // Send response back to main isolate AFTER initialization is complete
  params.sendPort.send(params.copyWith(
    sendPort: isolatePort.sendPort,
    nextIsolateIndex: params.isolateIndex + 1,
  ));

  if (params.policy == InitializationPolicy.concurrent) {
    if (!isInTest) {
      print('[isolate_pool_2]: Isolate #${params.isolateIndex} initialized, '
          'took ${params.stopwatch.elapsedMilliseconds} milliseconds');
    }
  }
}
