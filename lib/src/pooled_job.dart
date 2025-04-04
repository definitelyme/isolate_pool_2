import 'dart:async';
import 'internal/external_job.dart';

/// One-off operation to be queued and executed in the isolate pool.
///
/// Fields defined in the instance will be passed to the isolate.
/// The generic type [E] determines the return type of the job.
///
/// Be considerate of Dart's rules for what types can cross isolate boundaries;
/// objects that wrap native resources (e.g., file handles) may cause issues.
/// See [SendPort.send] for details on the limitations.
abstract class PooledJob<E> {
  /// Creates a new [PooledJob].
  const PooledJob();

  /// The actual work to be performed in the isolate.
  /// Returns a [Future] that completes with the result.
  Future<E> job();

  // For internal use
  // ignore: library_private_types_in_public_api
  ExternalJob<E> wrap() => ExternalJob(this);
}
