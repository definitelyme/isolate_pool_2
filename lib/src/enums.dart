/// Defines the initialization behavior of isolates in the pool
enum InitializationPolicy {
  /// Initialization is done sequentially, one isolate at a time.
  /// This reduces the risk of collisions or race conditions during initialization.
  sequential,

  /// All isolates are initialized concurrently, which is faster but might
  /// lead to resource contention.
  concurrent;
}

/// Represents the current state of an [IsolatePool].
enum IsolatePoolState {
  /// Pool has been created but not yet started.
  /// Call [IsolatePool.start] to start the pool.
  notStarted,

  /// Pool is running and ready to accept jobs.
  started,

  /// Pool has been stopped and can't be restarted.
  /// Create a new pool instance instead.
  stopped
}

/// Categorization of different error types that can occur in isolates.
///
/// Used with [IsolatePool.setErrorHandler] to register handlers for
/// specific error categories.
enum IsolateErrorType {
  /// All error types, used as a catch-all handler.
  all,

  /// Errors that occur during isolate initialization.
  initialization,

  /// Errors related to job execution.
  job,

  /// Errors related to pooled instance operations.
  instance,

  /// Errors related to communication between isolates.
  communication,

  /// Errors that don't fit into any other category.
  unknown
}
