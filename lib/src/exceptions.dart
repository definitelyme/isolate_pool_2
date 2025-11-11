/// Base exception class for all isolate pool related exceptions.
class IsolatePoolException implements Exception {
  /// Error message describing the exception.
  final String message;

  /// Stack trace of the exception, if available.
  final StackTrace? stackTrace;

  /// Creates a new [IsolatePoolException] with the given [message].
  const IsolatePoolException(this.message, [this.stackTrace]);

  @override
  String toString() {
    final msg = switch (stackTrace) {
      _ when stackTrace != StackTrace.empty => '$message\n$stackTrace',
      _ => message,
    };

    return msg;
  }
}

/// Thrown when attempting to use a non-existent isolate instance.
class NoSuchIsolateInstanceException extends IsolatePoolException {
  const NoSuchIsolateInstanceException(super.message, [super.stackTrace]);
}

/// Thrown when attempting to use a pool that has been stopped.
class IsolatePoolStoppedException extends IsolatePoolException {
  const IsolatePoolStoppedException(super.message, [super.stackTrace]);
}

/// Thrown when jobs are cancelled due to pool stoppage.
class IsolatePoolJobCancelledException extends IsolatePoolException {
  const IsolatePoolJobCancelledException(super.message, [super.stackTrace]);
}

/// Thrown when attempting to use an isolate instance that hasn't completed initialization.
class IsolateNotYetStartedException extends IsolatePoolException {
  const IsolateNotYetStartedException(super.message, [super.stackTrace]);
}

/// Thrown when receiving an unexpected response from an isolate.
class BadResponseReceivedException extends IsolatePoolException {
  const BadResponseReceivedException(super.message, [super.stackTrace]);
}

/// Encapsulates an error that occurred in an isolate.
///
/// This class is used to transport errors from isolates back to the main isolate
/// with proper context and stack trace information.
class IsolateError extends IsolatePoolException {
  /// The original error object.
  final Object originalError;

  /// The isolate index where the error occurred.
  final int isolateIndex;

  /// Original stack trace from where the error occurred in the isolate
  final StackTrace originalStackTrace;

  /// Creates a new [IsolateError] with the given [originalError].
  const IsolateError(
    this.originalError,
    this.isolateIndex,
    String message, [
    this.originalStackTrace = StackTrace.empty,
  ]) : super(message, originalStackTrace);

  @override
  String toString() {
    final msg = switch (originalStackTrace) {
      _ when originalStackTrace != StackTrace.empty => '$message\n$originalStackTrace',
      _ => message,
    };

    return 'Error in isolate #$isolateIndex: $msg';
  }

  /// Returns the original error unwrapped.
  /// This is useful for catching the error in the main isolate with its original type.
  Object get unwrappedError => originalError;

  /// Creates a copy of this error but with a combined stack trace.
  /// The combined stack trace includes both the original isolate stack trace
  /// and the main isolate stack trace where the error was caught.
  IsolateError withCombinedStackTrace(StackTrace mainStackTrace) {
    final combinedStack = _combineStackTraces(originalStackTrace, mainStackTrace);
    return IsolateError(originalError, isolateIndex, message, combinedStack);
  }

  /// Combines two stack traces into one, showing both where the error originated
  /// in the isolate and where it was caught in the main isolate.
  static StackTrace _combineStackTraces(StackTrace original, StackTrace main) {
    final originalString = original.toString();
    final mainString = main.toString();

    return StackTrace.fromString('=== Stack trace in isolate (where error originated) ===\n'
        '$originalString\n'
        '=== Stack trace in main isolate (where error was caught) ===\n'
        '$mainString');
  }
}

/// Thrown when an error occurs during initialization of an isolate.
class IsolateInitializationException extends IsolatePoolException {
  /// The isolate index that failed to initialize.
  final int isolateIndex;

  const IsolateInitializationException(
    this.isolateIndex,
    super.message, [
    super.stackTrace,
  ]);

  @override
  String toString() {
    final msg = switch (stackTrace) {
      _ when stackTrace != StackTrace.empty => '$message\n$stackTrace',
      _ => message,
    };

    return 'Failed to initialize isolate #$isolateIndex: $msg';
  }
}

/// Thrown when a timeout occurs while waiting for an isolate operation.
class IsolateTimeoutException extends IsolatePoolException {
  final String operation;

  /// The timeout duration in milliseconds.
  final int timeoutMs;

  const IsolateTimeoutException(
    this.operation,
    this.timeoutMs,
    super.message, [
    super.stackTrace,
  ]);

  @override
  String toString() {
    final msg = switch (stackTrace) {
      _ when stackTrace != StackTrace.empty => '$message\n$stackTrace',
      _ => message,
    };

    return '$operation timed out after $timeoutMs ms: $msg';
  }
}

/// Thrown when an isolate is detected as dead or unresponsive.
///
/// This exception is thrown when health checks fail or when an isolate
/// does not respond to ping requests within the configured timeout.
class IsolateDeadException extends IsolatePoolException {
  /// The isolate index that is dead or unresponsive.
  final int isolateIndex;

  const IsolateDeadException(
    this.isolateIndex,
    super.message, [
    super.stackTrace,
  ]);

  @override
  String toString() {
    final msg = switch (stackTrace) {
      _ when stackTrace != StackTrace.empty => '$message\n$stackTrace',
      _ => message,
    };

    return 'Isolate #$isolateIndex is dead or unresponsive: $msg';
  }
}
