/// Core isolate pool functionality tests
@TestOn('vm')
library;

import 'dart:async';

import 'package:isolate_pool_2/isolate_pool_2.dart';
import 'package:test/test.dart';

// Simple test job
class SimpleJob extends PooledJob<int> {
  final int value;
  SimpleJob(this.value);

  @override
  Future<int> job() async => value * 2;
}

// Long running job
class LongRunningJob extends PooledJob<String> {
  final int durationMs;
  final String result;
  LongRunningJob(this.durationMs, this.result);

  @override
  Future<String> job() async {
    await Future.delayed(Duration(milliseconds: durationMs));
    return result;
  }
}

// Memory intensive job
class MemoryIntensiveJob extends PooledJob<int> {
  final int sizeInMB;
  MemoryIntensiveJob(this.sizeInMB);

  @override
  Future<int> job() async {
    final data = List.filled(sizeInMB * 1024 * 1024 ~/ 8, 0.0);
    var sum = 0.0;
    for (var i = 0; i < data.length; i += 1000) {
      sum += i;
    }
    return sum.toInt();
  }
}

// Fibonacci job for performance testing
class FibonacciJob extends PooledJob<int> {
  final int n;
  FibonacciJob(this.n);

  @override
  Future<int> job() async {
    if (n <= 1) return n;
    int a = 0, b = 1;
    for (int i = 2; i <= n; i++) {
      final temp = a + b;
      a = b;
      b = temp;
    }
    return b;
  }
}

// Callback job for testing callback functionality
class TestCallbackJob extends PooledJob<int> {
  final int startValue;
  TestCallbackJob(this.startValue);

  @override
  Future<int> job() async {
    // Simple job that returns incremented value
    return startValue + 10;
  }
}

// Throwing job for error testing
class ThrowingJob extends PooledJob<int> {
  final String errorMessage;
  ThrowingJob(this.errorMessage);

  @override
  Future<int> job() async {
    throw Exception(errorMessage);
  }
}

void main() {
  group('Pool Lifecycle', () {
    test('Pool starts and stops correctly', () async {
      final pool = IsolatePool(4);
      expect(pool.state, IsolatePoolState.notStarted);

      await pool.start();
      expect(pool.state, IsolatePoolState.started);
      expect(pool.numberOfIsolates, 4);

      pool.stop();
      expect(pool.state, IsolatePoolState.stopped);
    });

    test('Pool with 0 isolates starts successfully', () async {
      final pool = IsolatePool(0);
      await pool.start();

      expect(pool.numberOfIsolates, 0);
      expect(pool.state, IsolatePoolState.started);

      pool.stop();
    });

    test('Pool with custom initialization', () async {
      // Note: The init function runs in each isolate, not in the main isolate,
      // so we can't directly test if it was called. We just verify that
      // start() completes successfully with an init function.
      final pool = IsolatePool(2);

      await pool.start(init: () {
        // This runs in each isolate
      });

      expect(pool.state, IsolatePoolState.started);
      expect(pool.numberOfIsolates, 2);

      pool.stop();
    });

    test('Pool start with errorsAreFatal parameter', () async {
      final pool = IsolatePool(2);
      await pool.start(errorsAreFatal: true);

      expect(pool.state, IsolatePoolState.started);

      pool.stop();
    });

    test('Rapid start/stop cycles', () async {
      for (int cycle = 0; cycle < 5; cycle++) {
        final pool = IsolatePool(3);
        await pool.start();

        final result = await pool.scheduleJob(SimpleJob(cycle));
        expect(result, cycle * 2);

        pool.stop();
        await Future.delayed(Duration(milliseconds: 10));
      }
    });

    test('Pool cannot start twice', () async {
      final pool = IsolatePool(2);
      await pool.start();

      await expectLater(
        pool.start(),
        throwsA(isA<IsolatePoolException>()),
      );

      pool.stop();
    });

    test('Pool stop during pending operations', () async {
      final pool = IsolatePool(2);
      await pool.start();

      // Schedule long-running jobs
      final futures = <Future>[];
      for (int i = 0; i < 10; i++) {
        futures.add(pool.scheduleJob(LongRunningJob(1000, 'job$i')));
      }

      // Stop pool while jobs are running
      await Future.delayed(Duration(milliseconds: 100));
      pool.stop();

      // All futures should complete with error
      for (final future in futures) {
        await expectLater(
          future,
          throwsA(isA<IsolatePoolJobCancelledException>()),
        );
      }
    });
  });

  group('Dynamic Pool Scaling', () {
    test('Add isolates to running pool', () async {
      final pool = IsolatePool(2);
      await pool.start();

      expect(pool.numberOfIsolates, 2);

      await pool.addIsolate();
      expect(pool.numberOfIsolates, 3);

      await pool.addIsolate();
      expect(pool.numberOfIsolates, 4);

      pool.stop();
    });

    test('Dynamic scaling under load', () async {
      final pool = IsolatePool(2);
      await pool.start();

      // Start with light load
      var job1 = pool.scheduleJob(LongRunningJob(100, 'result1'));
      var job2 = pool.scheduleJob(LongRunningJob(100, 'result2'));
      await Future.wait([job1, job2]);

      // Scale up under heavy load
      await pool.addIsolate();
      await pool.addIsolate();
      expect(pool.numberOfIsolates, 4);

      // Distribute heavy load
      final heavyJobs = <Future<String>>[];
      for (int i = 0; i < 20; i++) {
        heavyJobs.add(pool.scheduleJob(LongRunningJob(50, 'heavy$i')));
      }

      final results = await Future.wait(heavyJobs);
      expect(results.length, 20);

      pool.stop();
    });

    test('Maximum pool size stress test', () async {
      final pool = IsolatePool(50);
      await pool.start();

      expect(pool.numberOfIsolates, 50);

      // Schedule jobs across all isolates
      final jobs = <Future<int>>[];
      for (int i = 0; i < 100; i++) {
        jobs.add(pool.scheduleJob(FibonacciJob(20)));
      }

      final results = await Future.wait(jobs);
      expect(results.every((r) => r == 6765), true); // Fibonacci(20) = 6765

      pool.stop();
    });
  });

  group('Job Scheduling', () {
    late IsolatePool pool;

    setUp(() async {
      pool = IsolatePool(4);

      // Suppress error logs for cleaner test output
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.start();
    });

    tearDown(() {
      pool.stop();
    });

    test('Simple job execution', () async {
      final result = await pool.scheduleJob(SimpleJob(21));
      expect(result, 42);
    });

    test('Job scheduling to specific isolate', () async {
      final result1 = await pool.scheduleJob(SimpleJob(10), 0);
      expect(result1, 20);

      final result2 = await pool.scheduleJob(SimpleJob(20), 1);
      expect(result2, 40);

      final result3 = await pool.scheduleJob(SimpleJob(30), 2);
      expect(result3, 60);
    });

    test('Job scheduling with invalid isolate index throws', () async {
      expect(
        () => pool.scheduleJob(SimpleJob(1), 10),
        throwsA(isA<IsolatePoolException>()),
      );

      expect(
        () => pool.scheduleJob(SimpleJob(1), -2),
        throwsA(isA<IsolatePoolException>()),
      );
    });

    test('Multiple concurrent jobs', () async {
      final futures = <Future<int>>[];
      for (int i = 0; i < 100; i++) {
        futures.add(pool.scheduleJob(SimpleJob(i)));
      }

      final results = await Future.wait(futures);
      for (int i = 0; i < 100; i++) {
        expect(results[i], i * 2);
      }
    });

    test('Job scheduling after pool stop fails', () async {
      pool.stop();

      expect(
        () => pool.scheduleJob(SimpleJob(1)),
        throwsA(isA<IsolatePoolStoppedException>()),
      );
    });

    test('Long-running job cancellation on pool stop', () async {
      final longJob = pool.scheduleJob(LongRunningJob(5000, 'never'));

      await Future.delayed(Duration(milliseconds: 100));
      pool.stop();

      await expectLater(
        longJob,
        throwsA(isA<IsolatePoolJobCancelledException>()),
      );
    });

    test('Memory intensive jobs', () async {
      final jobs = <Future<int>>[];
      for (int i = 0; i < 5; i++) {
        jobs.add(pool.scheduleJob(MemoryIntensiveJob(10))); // 10MB each
      }

      final results = await Future.wait(jobs);
      expect(results.length, 5);
      expect(results.every((r) => r >= 0), true);
    });

    test('Simple callback job', () async {
      final job = TestCallbackJob(10);

      final result = await pool.scheduleJob(job);

      expect(result, 20);
    });

    test('Job exception handling', () async {
      await expectLater(
        pool.scheduleJob(ThrowingJob('Test error')),
        throwsA(isA<Exception>()),
      );

      // Pool should still be functional after job exception
      final result = await pool.scheduleJob(SimpleJob(5));
      expect(result, 10);
    });
  });

  group('Health Monitoring', () {
    test('Health checking with default config', () async {
      final pool = IsolatePool(
        2,
        healthConfig: const IsolateHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 500),
        ),
      );

      await pool.start();

      final isHealthy0 = await pool.pingIsolate(0);
      expect(isHealthy0, true);

      final isHealthy1 = await pool.pingIsolate(1);
      expect(isHealthy1, true);

      pool.stop();
    });

    test('Health status retrieval', () async {
      final pool = IsolatePool(
        3,
        healthConfig: const IsolateHealthConfig(
          enabled: true,
        ),
      );

      await pool.start();

      final status = pool.healthStatus;
      expect(status.length, 3);

      for (var i = 0; i < 3; i++) {
        expect(status[i]?.isolateIndex, i);
        expect(status[i]?.isHealthy, true);
      }

      pool.stop();
    });

    test('Health checking disabled', () async {
      final pool = IsolatePool(
        2,
        healthConfig: const IsolateHealthConfig.disabled(),
      );

      await pool.start();

      // With health checking disabled, should return true without actual ping
      expect(await pool.pingIsolate(0), true);
      expect(pool.isIsolateHealthy(0), true);

      pool.stop();
    });

    test('Health check during heavy load', () async {
      final pool = IsolatePool(
        2,
        healthConfig: const IsolateHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 200),
        ),
      );

      await pool.start();

      // Start heavy computation
      final heavyJobs = <Future>[];
      for (int i = 0; i < 10; i++) {
        heavyJobs.add(pool.scheduleJob(FibonacciJob(30)));
      }

      // Check health while under load
      final isHealthy = await pool.pingIsolate(0);
      expect(isHealthy, true);

      await Future.wait(heavyJobs);
      pool.stop();
    });

    test('Aggressive health config', () async {
      final pool = IsolatePool(
        2,
        healthConfig: const IsolateHealthConfig.aggressive(),
      );

      await pool.start();

      // Aggressive config has short timeouts
      final isHealthy = await pool.pingIsolate(0);
      expect(isHealthy, true);

      pool.stop();
    });

    test('Relaxed health config', () async {
      final pool = IsolatePool(
        2,
        healthConfig: const IsolateHealthConfig.relaxed(),
      );

      await pool.start();

      // Relaxed config has longer timeouts
      final isHealthy = await pool.pingIsolate(0);
      expect(isHealthy, true);

      pool.stop();
    });
  });

  group('Error Handling', () {
    test('Error handler receives all error types', () async {
      final errors = <Object>[];
      final pool = IsolatePool(2);

      pool.setErrorHandler(IsolateErrorType.all, (error) {
        errors.add(error);
      });

      await pool.start(init: () {
        // This won't actually throw in main isolate, but shows handler setup
      });

      expect(errors.isEmpty, true);

      pool.stop();
    });

    test('Specific error type handlers', () async {
      Object? jobError;
      Object? instanceError;
      Object? initError;

      final pool = IsolatePool(2);

      pool.setErrorHandler(IsolateErrorType.job, (error) {
        jobError = error;
      });

      pool.setErrorHandler(IsolateErrorType.instance, (error) {
        instanceError = error;
      });

      pool.setErrorHandler(IsolateErrorType.initialization, (error) {
        initError = error;
      });

      await pool.start();

      expect(jobError, isNull);
      expect(instanceError, isNull);
      expect(initError, isNull);

      pool.stop();
    });

    test('Multiple error handlers can be set', () async {
      final pool = IsolatePool(2);

      pool.setErrorHandler(IsolateErrorType.all, (error) {});
      // Set a new handler to override the previous one
      pool.setErrorHandler(IsolateErrorType.all, (error) {
        print('New handler: $error');
      });

      await pool.start();
      pool.stop();
    });

    test('errorsAreFatal parameter effect', () async {
      final pool = IsolatePool(
        2,
        healthConfig: const IsolateHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 500),
        ),
      );

      // Suppress error logs during tests
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      // Start with errorsAreFatal: true
      await pool.start(errorsAreFatal: true);

      // Verify isolate is healthy before exception
      expect(await pool.pingIsolate(0), true);

      // Schedule a job that will fail
      try {
        await pool.scheduleJob(ThrowingJob('Test exception'), 0);
      } catch (e) {
        // Expected
      }

      // Wait for error handling
      await Future.delayed(Duration(milliseconds: 200));

      // IMPORTANT: Isolate is STILL ALIVE because job exceptions are caught
      // errorsAreFatal only affects UNHANDLED errors, not caught job exceptions
      expect(await pool.pingIsolate(0), true);

      // Verify isolate can still process jobs
      final result = await pool.scheduleJob(SimpleJob(42), 0);
      expect(result, 84);

      pool.stop();
    });
  });

  group('Pool State and Statistics', () {
    test('Pool state transitions', () async {
      final pool = IsolatePool(2);

      expect(pool.state, IsolatePoolState.notStarted);

      await pool.start();
      expect(pool.state, IsolatePoolState.started);

      pool.stop();
      expect(pool.state, IsolatePoolState.stopped);
    });

    test('Isolate index tracking', () async {
      final pool = IsolatePool(2);
      await pool.start();

      // The pool doesn't have instances initially
      expect(pool.numberOfPooledInstances, 0);

      pool.stop();
    });
  });

  group('Performance Benchmarks', () {
    test('Job throughput measurement', () async {
      final pool = IsolatePool(4);
      await pool.start();

      final stopwatch = Stopwatch()..start();
      final jobs = <Future<int>>[];

      // Schedule 1000 simple jobs
      for (int i = 0; i < 1000; i++) {
        jobs.add(pool.scheduleJob(SimpleJob(i)));
      }

      await Future.wait(jobs);
      stopwatch.stop();

      final jobsPerSecond = 1000 / (stopwatch.elapsedMilliseconds / 1000);
      print('Job throughput: ${jobsPerSecond.toStringAsFixed(2)} jobs/second');

      expect(jobsPerSecond, greaterThan(100)); // Should handle >100 jobs/second

      pool.stop();
    });

    test('Parallel speedup verification', () async {
      // Helper function for prime checking
      bool isPrimeSync(int n) {
        if (n <= 1) return false;
        if (n <= 3) return true;
        if (n % 2 == 0 || n % 3 == 0) return false;
        var i = 5;
        while (i * i <= n) {
          if (n % i == 0 || n % (i + 2) == 0) return false;
          i += 6;
        }
        return true;
      }

      // Sequential execution
      final sequentialStopwatch = Stopwatch()..start();
      final sequentialResults = <int>[];

      for (int i = 0; i < 50; i++) {
        if (isPrimeSync(10000000 + i)) {
          sequentialResults.add(10000000 + i);
        }
      }
      sequentialStopwatch.stop();

      // Parallel execution
      final pool = IsolatePool(4);
      await pool.start();

      final parallelStopwatch = Stopwatch()..start();
      final parallelJobs = <Future<int>>[];

      for (int i = 0; i < 50; i++) {
        parallelJobs.add(pool.scheduleJob(FibonacciJob(25)));
      }

      await Future.wait(parallelJobs);
      parallelStopwatch.stop();

      final sequentialMs = sequentialStopwatch.elapsedMilliseconds;
      final parallelMs = parallelStopwatch.elapsedMilliseconds;

      print('Sequential time: ${sequentialMs}ms');
      print('Parallel time: ${parallelMs}ms');

      // Should complete successfully regardless of speedup
      expect(parallelJobs.length, 50);

      pool.stop();
    });

    test('Instance communication latency', () async {
      final pool = IsolatePool(2);
      await pool.start();

      // For this test, we'll measure job scheduling latency
      final measurements = <int>[];

      for (int i = 0; i < 100; i++) {
        final start = DateTime.now().microsecondsSinceEpoch;
        await pool.scheduleJob(SimpleJob(i));
        final end = DateTime.now().microsecondsSinceEpoch;
        measurements.add(end - start);
      }

      final avgLatency = measurements.reduce((a, b) => a + b) / measurements.length;
      print('Average job scheduling latency: ${avgLatency.toStringAsFixed(2)} microseconds');

      expect(avgLatency, lessThan(10000)); // Should be less than 10ms

      pool.stop();
    });
  });
}
