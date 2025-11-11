/// Tests for killing and removing specific isolates from the pool
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:isolate_pool_2/isolate_pool_2.dart';
import 'package:test/test.dart';

// Simple test job for testing
class SimpleJob extends PooledJob<int> {
  final int value;
  SimpleJob(this.value);

  @override
  Future<int> job() async => value * 2;
}

// Long running job that can be used to test interruption
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

// Job that identifies which isolate it's running on
class IsolateIdentifyingJob extends PooledJob<int> {
  @override
  Future<int> job() async {
    // Return the hashCode of the current isolate to identify it
    return Isolate.current.hashCode;
  }
}

// Simple action class for testing
class GetStateAction extends Action {}
class SetStateAction extends Action {
  final String newState;
  SetStateAction(this.newState);
}

// Simple instance for testing
class TestInstance extends PooledInstance {
  String state = 'initial';

  @override
  Future<void> init() async {
    state = 'initialized';
  }

  @override
  Future<void> dispose() async {
    state = 'disposed';
  }

  @override
  Future<dynamic> receiveRemoteCall(Action action) async {
    if (action is GetStateAction) {
      return state;
    } else if (action is SetStateAction) {
      state = action.newState;
      return null;
    }
    throw UnimplementedError('Unknown action: $action');
  }

  Future<String> getState() async => state;

  Future<void> setState(String newState) async {
    state = newState;
  }
}

void main() {
  group('IsolatePool.killIsolate()', () {
    late IsolatePool pool;

    tearDown(() async {
      // Clean up after each test
      if (pool.state != IsolatePoolState.stopped) {
        pool.stop();
      }
    });

    test('should kill a specific isolate and remove it from the pool', () async {
      pool = IsolatePool(4);
      await pool.start();

      // Verify initial state
      expect(pool.numberOfIsolates, equals(4));
      expect(pool.state, equals(IsolatePoolState.started));

      // Kill isolate at index 2
      pool.killIsolate(2);

      // Verify isolate was removed
      expect(pool.numberOfIsolates, equals(4)); // Count remains the same for stable indices

      // Try to schedule a job specifically on the killed isolate - should fail
      expect(
        () => pool.scheduleJob(SimpleJob(10), 2),
        throwsA(isA<IsolatePoolException>()),
      );
    });

    test('should fail pending jobs on the killed isolate', () async {
      pool = IsolatePool(3);
      await pool.start();

      // Schedule a long-running job on isolate 1
      final jobFuture = pool.scheduleJob(LongRunningJob(5000, 'result'), 1);

      // Give it a moment to start
      await Future.delayed(Duration(milliseconds: 100));

      // Kill isolate 1
      pool.killIsolate(1);

      // The job should fail with an exception
      expect(
        jobFuture,
        throwsA(isA<IsolatePoolException>().having(
          (e) => e.message,
          'message',
          contains('Isolate #1 was killed'),
        )),
      );
    });

    test('should destroy all instances on the killed isolate', () async {
      pool = IsolatePool(3);
      await pool.start();

      // Create instances on different isolates
      final instance1 = await pool.addInstance(TestInstance(), isolateIndex: 0);
      final instance2 = await pool.addInstance(TestInstance(), isolateIndex: 1);
      final instance3 = await pool.addInstance(TestInstance(), isolateIndex: 1);
      final instance4 = await pool.addInstance(TestInstance(), isolateIndex: 2);

      // Verify all instances are created
      expect(pool.numberOfPooledInstances, equals(4));

      // Kill isolate 1 (which has instance2 and instance3)
      pool.killIsolate(1);

      // Verify only instances on isolate 1 were removed
      expect(pool.numberOfPooledInstances, equals(2));

      // Verify instance1 and instance4 are still in the pool
      expect(pool.pooledInstances.containsKey(instance1.instanceId), isTrue);
      expect(pool.pooledInstances.containsKey(instance4.instanceId), isTrue);

      // Verify instance2 and instance3 are removed
      expect(pool.pooledInstances.containsKey(instance2.instanceId), isFalse);
      expect(pool.pooledInstances.containsKey(instance3.instanceId), isFalse);
    });

    test('should allow other isolates to continue working normally', () async {
      pool = IsolatePool(4);
      await pool.start();

      // Schedule jobs on different isolates
      final job0 = pool.scheduleJob(SimpleJob(5), 0);
      final job2 = pool.scheduleJob(SimpleJob(10), 2);
      final job3 = pool.scheduleJob(SimpleJob(15), 3);

      // Kill isolate 1
      pool.killIsolate(1);

      // Jobs on other isolates should complete successfully
      expect(await job0, equals(10));
      expect(await job2, equals(20));
      expect(await job3, equals(30));

      // We should still be able to schedule new jobs on the remaining isolates
      final newJob0 = await pool.scheduleJob(SimpleJob(20), 0);
      final newJob2 = await pool.scheduleJob(SimpleJob(25), 2);
      final newJob3 = await pool.scheduleJob(SimpleJob(30), 3);

      expect(newJob0, equals(40));
      expect(newJob2, equals(50));
      expect(newJob3, equals(60));
    });

    test('should throw when trying to kill an invalid isolate index', () async {
      pool = IsolatePool(3);
      await pool.start();

      // Try to kill isolate with negative index
      expect(
        () => pool.killIsolate(-1),
        throwsA(isA<IsolatePoolException>().having(
          (e) => e.message,
          'message',
          contains('Invalid isolate index'),
        )),
      );

      // Try to kill isolate with index >= numberOfIsolates
      expect(
        () => pool.killIsolate(3),
        throwsA(isA<IsolatePoolException>().having(
          (e) => e.message,
          'message',
          contains('Invalid isolate index'),
        )),
      );

      // Try to kill isolate with index way out of bounds
      expect(
        () => pool.killIsolate(100),
        throwsA(isA<IsolatePoolException>().having(
          (e) => e.message,
          'message',
          contains('Invalid isolate index'),
        )),
      );
    });

    test('should throw when trying to kill an already killed isolate', () async {
      pool = IsolatePool(3);
      await pool.start();

      // Kill isolate 1
      pool.killIsolate(1);

      // Try to kill it again
      expect(
        () => pool.killIsolate(1),
        throwsA(isA<IsolatePoolException>().having(
          (e) => e.message,
          'message',
          contains('does not exist or has already been removed'),
        )),
      );
    });

    test('should throw when pool is not started', () async {
      pool = IsolatePool(3);

      // Try to kill isolate before starting the pool
      expect(
        () => pool.killIsolate(0),
        throwsA(isA<IsolatePoolException>().having(
          (e) => e.message,
          'message',
          contains('pool is not started'),
        )),
      );
    });

    test('should throw when pool is stopped', () async {
      pool = IsolatePool(3);
      await pool.start();
      pool.stop();

      // Try to kill isolate after stopping the pool
      expect(
        () => pool.killIsolate(0),
        throwsA(isA<IsolatePoolStoppedException>()),
      );
    });

    test('should handle multiple isolate kills correctly', () async {
      pool = IsolatePool(5);
      await pool.start();

      // Create instances on different isolates
      final instance0 = await pool.addInstance(TestInstance(), isolateIndex: 0);
      final instance1 = await pool.addInstance(TestInstance(), isolateIndex: 1);
      final instance2 = await pool.addInstance(TestInstance(), isolateIndex: 2);
      final instance3 = await pool.addInstance(TestInstance(), isolateIndex: 3);
      final instance4 = await pool.addInstance(TestInstance(), isolateIndex: 4);

      expect(pool.numberOfPooledInstances, equals(5));

      // Kill isolates 1 and 3
      pool.killIsolate(1);
      pool.killIsolate(3);

      expect(pool.numberOfPooledInstances, equals(3));

      // Verify correct instances remain
      expect(pool.pooledInstances.containsKey(instance0.instanceId), isTrue);
      expect(pool.pooledInstances.containsKey(instance1.instanceId), isFalse);
      expect(pool.pooledInstances.containsKey(instance2.instanceId), isTrue);
      expect(pool.pooledInstances.containsKey(instance3.instanceId), isFalse);
      expect(pool.pooledInstances.containsKey(instance4.instanceId), isTrue);

      // Remaining isolates should still work
      final job0 = await pool.scheduleJob(SimpleJob(10), 0);
      final job2 = await pool.scheduleJob(SimpleJob(20), 2);
      final job4 = await pool.scheduleJob(SimpleJob(30), 4);

      expect(job0, equals(20));
      expect(job2, equals(40));
      expect(job4, equals(60));
    });

    test('should clean up all resources properly when killing an isolate', () async {
      pool = IsolatePool(3);
      await pool.start();

      // Create an instance on isolate 1
      final instance = await pool.addInstance(TestInstance(), isolateIndex: 1);

      // Schedule a job on isolate 1
      final jobFuture = pool.scheduleJob(LongRunningJob(5000, 'test'), 1);

      // Give it a moment to start
      await Future.delayed(Duration(milliseconds: 100));

      // Kill isolate 1
      pool.killIsolate(1);

      // Verify job fails
      expect(
        jobFuture,
        throwsA(isA<IsolatePoolException>()),
      );

      // Verify instance is removed
      expect(pool.pooledInstances.containsKey(instance.instanceId), isFalse);

      // Note: Port cleanup verification would need access to internal state
      // which is not directly exposed. The implementation does clean them up.
    });

    test('should maintain correct isolate indices after killing', () async {
      pool = IsolatePool(4);
      await pool.start();

      // Get isolate identities before killing
      final id0 = await pool.scheduleJob(IsolateIdentifyingJob(), 0);
      final id2 = await pool.scheduleJob(IsolateIdentifyingJob(), 2);
      final id3 = await pool.scheduleJob(IsolateIdentifyingJob(), 3);

      // Kill isolate 1
      pool.killIsolate(1);

      // Verify the same isolates are still at their indices
      final newId0 = await pool.scheduleJob(IsolateIdentifyingJob(), 0);
      final newId2 = await pool.scheduleJob(IsolateIdentifyingJob(), 2);
      final newId3 = await pool.scheduleJob(IsolateIdentifyingJob(), 3);

      expect(newId0, equals(id0));
      expect(newId2, equals(id2));
      expect(newId3, equals(id3));
    });

    test('should handle rapid sequential kills', () async {
      pool = IsolatePool(5);
      await pool.start();

      // Kill multiple isolates in rapid succession
      pool.killIsolate(0);
      pool.killIsolate(2);
      pool.killIsolate(4);

      // Remaining isolates 1 and 3 should still work
      final job1 = await pool.scheduleJob(SimpleJob(100), 1);
      final job3 = await pool.scheduleJob(SimpleJob(200), 3);

      expect(job1, equals(200));
      expect(job3, equals(400));

      // Verify killed isolates can't be used
      expect(() => pool.scheduleJob(SimpleJob(10), 0), throwsA(isA<IsolatePoolException>()));
      expect(() => pool.scheduleJob(SimpleJob(10), 2), throwsA(isA<IsolatePoolException>()));
      expect(() => pool.scheduleJob(SimpleJob(10), 4), throwsA(isA<IsolatePoolException>()));
    });

    test('should properly handle instance creation failure on killed isolate', () async {
      pool = IsolatePool(3);
      await pool.start();

      // Kill isolate 1
      pool.killIsolate(1);

      // Try to create an instance on the killed isolate
      expect(
        () => pool.addInstance(TestInstance(), isolateIndex: 1),
        throwsA(isA<IsolatePoolException>()),
      );

      // Creating instances on other isolates should still work
      final instance0 = await pool.addInstance(TestInstance(), isolateIndex: 0);
      final instance2 = await pool.addInstance(TestInstance(), isolateIndex: 2);

      expect(pool.pooledInstances.containsKey(instance0.instanceId), isTrue);
      expect(pool.pooledInstances.containsKey(instance2.instanceId), isTrue);
    });

    test('should handle pending instance creations when killing isolate', () async {
      pool = IsolatePool(3);
      await pool.start();

      // Start creating multiple instances on isolate 1 with delays
      final creationFutures = <Future<PooledInstanceProxy>>[];
      for (int i = 0; i < 3; i++) {
        creationFutures.add(
          Future.delayed(Duration(milliseconds: 50 * i))
              .then((_) => pool.addInstance(TestInstance(), isolateIndex: 1))
        );
      }

      // Kill isolate 1 before all creations complete
      await Future.delayed(Duration(milliseconds: 75));
      pool.killIsolate(1);

      // Some creations might succeed, others should fail
      // Count how many succeed vs fail
      int succeeded = 0;
      int failed = 0;

      for (final future in creationFutures) {
        try {
          await future;
          succeeded++;
        } catch (e) {
          if (e is IsolatePoolException) {
            failed++;
          } else {
            rethrow;
          }
        }
      }

      // At least one should have failed (those that were pending when kill happened)
      expect(failed, greaterThan(0));

      // Verify total attempts equals succeeded + failed
      expect(succeeded + failed, equals(3));

      // Verify no instances remain on the killed isolate
      for (final entry in pool.pooledInstances.values) {
        expect(entry.isolateIndex, isNot(equals(1)));
      }
    });

    test('should track alive isolate count correctly', () async {
      pool = IsolatePool(5);
      await pool.start();

      // Initial state - all isolates alive
      expect(pool.numberOfIsolates, equals(5));
      expect(pool.aliveIsolateCount, equals(5));

      // Kill one isolate
      pool.killIsolate(2);
      expect(pool.numberOfIsolates, equals(5)); // numberOfIsolates stays same
      expect(pool.aliveIsolateCount, equals(4)); // aliveIsolateCount decreases

      // Kill two more isolates
      pool.killIsolate(0);
      pool.killIsolate(4);
      expect(pool.numberOfIsolates, equals(5)); // numberOfIsolates still same
      expect(pool.aliveIsolateCount, equals(2)); // Only 1 and 3 remain

      // Add a new isolate
      await pool.addIsolate();
      expect(pool.numberOfIsolates, equals(6)); // numberOfIsolates increases
      expect(pool.aliveIsolateCount, equals(3)); // aliveIsolateCount increases

      // Kill another and add another
      pool.killIsolate(1);
      expect(pool.aliveIsolateCount, equals(2)); // 3 and 5 remain

      await pool.addIsolate();
      expect(pool.numberOfIsolates, equals(7));
      expect(pool.aliveIsolateCount, equals(3)); // 3, 5, and 6 remain

      // Verify remaining isolates work correctly
      final job3 = await pool.scheduleJob(SimpleJob(10), 3);
      final job5 = await pool.scheduleJob(SimpleJob(20), 5);
      final job6 = await pool.scheduleJob(SimpleJob(30), 6);

      expect(job3, equals(20));
      expect(job5, equals(40));
      expect(job6, equals(60));
    });
  });
}