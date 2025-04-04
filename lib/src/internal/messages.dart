import 'dart:async';
import 'dart:isolate';

import '../enums.dart';
import '../pooled_instance.dart';
import '../pooled_job.dart';
import 'export.dart';

/// Message to request an action on a pooled instance
class Request {
  Request(this.instanceId, this.action) : id = requestIdCounter++;

  final Action action;
  final int id;
  final int instanceId;

  @override
  String toString() {
    return 'Request(instanceId: $instanceId, action: $action, id: $id)';
  }
}

/// Message with the response from a request
class Response {
  const Response(this.requestId, this.result, this.error, [this.stackTrace, this.isolateIndex = -1]);

  final dynamic error;
  final int isolateIndex;
  final int requestId;
  final dynamic result;
  final StackTrace? stackTrace;

  @override
  String toString() {
    return 'Response(requestId: $requestId, result: $result, error: $error, stackTrace: $stackTrace, isolateIndex: $isolateIndex)';
  }
}

/// Message with the response from a creation request
class CreationResponse {
  const CreationResponse(this.instanceId, this.error, [this.stackTrace]);

  final dynamic error;
  final int instanceId;
  final StackTrace? stackTrace;

  @override
  String toString() {
    return 'CreationResponse(instanceId: $instanceId, error: $error, stackTrace: $stackTrace)';
  }
}

/// Message to request destruction of a pooled instance
class DestroyRequest {
  const DestroyRequest(this.instanceId);

  final int instanceId;

  @override
  String toString() {
    return 'DestroyRequest(instanceId: $instanceId)';
  }
}

/// Instance status
enum PooledInstanceStatus { starting, started }

/// Entry in the instance map
class InstanceMapEntry<T> {
  InstanceMapEntry(this.instance, this.isolateIndex);

  final PooledInstanceProxy<T> instance;
  final int isolateIndex;

  PooledInstanceStatus state = PooledInstanceStatus.starting;

  @override
  String toString() {
    return 'InstanceMapEntry(instance: $instance, isolateIndex: $isolateIndex, state: $state)';
  }
}

/// Parameters for pooled isolate initialization
class PooledIsolateParams {
  const PooledIsolateParams(
    this.sendPort,
    this.errorSendPort,
    this.isolateIndex,
    this.stopwatch, {
    this.initFunc,
    this.nextIsolateIndex,
    this.policy,
    this.initializationError,
    required this.debugName,
  });

  final FutureOr<void> Function()? initFunc;
  final SendPort? errorSendPort;
  final dynamic initializationError;
  final int isolateIndex;
  final int? nextIsolateIndex;
  final InitializationPolicy? policy;
  final SendPort sendPort;
  final Stopwatch stopwatch;
  final String debugName;

  @override
  String toString() {
    return 'PooledIsolateParams(sendPort: $sendPort, errorSendPort: $errorSendPort, isolateIndex: $isolateIndex, initFunc: $initFunc, nextIsolateIndex: $nextIsolateIndex, policy: $policy, initializationError: $initializationError)';
  }

  PooledIsolateParams copyWith({
    SendPort? sendPort,
    SendPort? errorSendPort,
    int? isolateIndex,
    FutureOr<void> Function()? initFunc,
    Stopwatch? stopwatch,
    int? nextIsolateIndex,
    InitializationPolicy? policy,
    dynamic initializationError,
    String? debugName,
  }) {
    return PooledIsolateParams(
      sendPort ?? this.sendPort,
      errorSendPort ?? this.errorSendPort,
      isolateIndex ?? this.isolateIndex,
      stopwatch ?? this.stopwatch,
      initFunc: initFunc ?? this.initFunc,
      nextIsolateIndex: nextIsolateIndex ?? this.nextIsolateIndex,
      policy: policy ?? this.policy,
      initializationError: initializationError ?? this.initializationError,
      debugName: debugName ?? this.debugName,
    );
  }
}

/// Internal representation of a job
class PooledJobRequest<T> {
  const PooledJobRequest(this.job, this.jobIndex, this.isolateIndex, {this.started = false});

  final int isolateIndex;
  final PooledJob<T> job;
  final int jobIndex;
  final bool started;

  @override
  String toString() {
    return 'PooledJobRequest(job: $job, jobIndex: $jobIndex, isolateIndex: $isolateIndex, started: $started)';
  }

  PooledJobRequest<T> copyWith({
    int? isolateIndex,
    bool? started,
  }) {
    return PooledJobRequest(
      job,
      jobIndex,
      isolateIndex ?? this.isolateIndex,
      started: started ?? this.started,
    );
  }
}

/// Result of a job execution
class PooledJobResult {
  const PooledJobResult(
    this.data,
    this.jobIndex,
    this.isolateIndex,
    this.error,
    this.stackTrace,
  );

  final dynamic data;
  final dynamic error;
  final int isolateIndex;
  final int jobIndex;
  final StackTrace? stackTrace;

  @override
  String toString() {
    return 'PooledJobResult(data: $data, jobIndex: $jobIndex, isolateIndex: $isolateIndex, error: $error, stackTrace: $stackTrace)';
  }
}

/// Callback argument wrapper
class IsolateCallbackArg<A> {
  const IsolateCallbackArg(this.value);

  final A value;
}
