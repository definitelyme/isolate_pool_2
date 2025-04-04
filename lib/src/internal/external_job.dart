import 'package:isolate_pool_2/src/pooled_job.dart';

/// A wrapper used to pass jobs directly from the main isolate to the pool, bypassing the job queue
class ExternalJob<T> {
  final PooledJob<T> job;

  const ExternalJob(this.job);
}
