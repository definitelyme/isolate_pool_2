/// Tests for isolate validation utilities
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:isolate_pool_2/isolate_pool_2.dart';
import 'package:test/test.dart';

// Valid test instances
class SimpleData extends PooledInstance {
  final String name;
  final int value;

  SimpleData(this.name, this.value);

  @override
  Future<void> init() async {}

  @override
  Future<dynamic> receiveRemoteCall(Action action) async {
    return null;
  }
}

class DataWithCollections extends PooledInstance {
  final List<int> numbers;
  final Map<String, double> scores;
  final Set<String> tags;

  DataWithCollections(this.numbers, this.scores, this.tags);

  @override
  Future<void> init() async {}

  @override
  Future<dynamic> receiveRemoteCall(Action action) async {
    return null;
  }
}

// Invalid test instances
class InvalidInstanceWithCompleter extends PooledInstance {
  final Completer<int> completer = Completer<int>();

  @override
  Future<void> init() async {}

  @override
  Future<dynamic> receiveRemoteCall(Action action) async {
    return null;
  }
}

class InvalidInstanceWithStream extends PooledInstance {
  final StreamController<String> controller = StreamController<String>();

  @override
  Future<void> init() async {}

  @override
  Future<dynamic> receiveRemoteCall(Action action) async {
    return null;
  }
}

// Simulates the user's real-world scenario
class NumbersTrivalRepository {
  final StreamController<int> _controller;
  final IsolatePool pool;

  NumbersTrivalRepository(this.pool) : _controller = StreamController<int>();

  // DANGEROUS: This method uses a closure that captures 'this'
  // The entire object (including _controller) gets sent to the isolate
  Future<int> methodThatReturnsNumberDangerous(int param1, int param2) {
    return pool.scheduleJob(
      TwoParamsJob(
        param1,
        param2,
        (p0, p1) {
          // This closure captures 'this' which includes _controller
          // We need to actually USE the _controller to trigger the error
          final hasListener = _controller.hasListener;
          return p0 + p1 + (hasListener ? 0 : 0);
        },
      ),
    );
  }

  // SAFE: This method uses a static function
  Future<int> methodThatReturnsNumberSafe(int param1, int param2) {
    return pool.scheduleJob(
      TwoParamsJob(param1, param2, _jobHandler),
    );
  }

  static int _jobHandler(int param1, int param2) {
    // Static function - doesn't capture 'this'
    return param1 + param2;
  }

  void dispose() {
    _controller.close();
  }
}

// Generic two-parameter job similar to user's example
class TwoParamsJob<P1, P2, R> extends PooledJob<R> {
  TwoParamsJob(this.param1, this.param2, this.jobFunction);

  final P1 param1;
  final P2 param2;
  final R Function(P1, P2) jobFunction;

  @override
  Future<R> job() async => jobFunction(param1, param2);
}

// Another real-world example: Repository with Completer
class DataRepository {
  final Completer<String> _dataCompleter;
  final IsolatePool pool;

  DataRepository(this.pool) : _dataCompleter = Completer<String>();

  Future<String> fetchDataWithClosure(String endpoint) {
    // DANGEROUS: Closure captures _dataCompleter (even if not used in this simple example)
    // In real code, the closure might check _dataCompleter.isCompleted or similar
    return pool.scheduleJob(
      SingleParamJob(endpoint, (url) {
        // The closure captures 'this' and all its fields, including _dataCompleter
        final completed = _dataCompleter.isCompleted; // This line causes the capture
        return 'Data from $url (completed: $completed)';
      }),
    );
  }

  Future<String> fetchDataSafe(String endpoint) {
    // SAFE: Static function
    return pool.scheduleJob(
      SingleParamJob(endpoint, _fetchHandler),
    );
  }

  static String _fetchHandler(String url) {
    return 'Data from $url';
  }
}

class SingleParamJob<P, R> extends PooledJob<R> {
  SingleParamJob(this.param, this.jobFunction);

  final P param;
  final R Function(P) jobFunction;

  @override
  Future<R> job() async => jobFunction(param);
}

// Valid job that doesn't capture anything
class SafeCalculationJob extends PooledJob<int> {
  final int x;
  final int y;

  SafeCalculationJob(this.x, this.y);

  @override
  Future<int> job() async => x + y;
}

// Safe job with only primitives for testing isolate remains functional
class SafeJob extends PooledJob<int> {
  final int value;

  SafeJob(this.value);

  @override
  Future<int> job() async => value * 2;
}

void main() {
  group('Basic Validation Tests', () {
    group('canBeSentToIsolate - Primitive Types', () {
      test('Null is sendable', () {
        expect(canBeSentToIsolate(null), true);
      });

      test('Numbers are sendable', () {
        expect(canBeSentToIsolate(42), true);
        expect(canBeSentToIsolate(3.14), true);
        expect(canBeSentToIsolate(-100), true);
        expect(canBeSentToIsolate(double.infinity), true);
      });

      test('Strings are sendable', () {
        expect(canBeSentToIsolate(''), true);
        expect(canBeSentToIsolate('Hello World'), true);
        expect(canBeSentToIsolate('🚀'), true);
      });

      test('Booleans are sendable', () {
        expect(canBeSentToIsolate(true), true);
        expect(canBeSentToIsolate(false), true);
      });

      test('SendPort is sendable', () {
        final receivePort = ReceivePort();
        final sendPort = receivePort.sendPort;
        expect(canBeSentToIsolate(sendPort), true);
        receivePort.close();
      });

      test('Type objects are sendable', () {
        expect(canBeSentToIsolate(int), true);
        expect(canBeSentToIsolate(String), true);
      });
    });

    group('canBeSentToIsolate - Collections', () {
      test('Empty collections are sendable', () {
        expect(canBeSentToIsolate(<int>[]), true);
        expect(canBeSentToIsolate(<String, int>{}), true);
        expect(canBeSentToIsolate(<String>{}), true);
      });

      test('Lists with sendable elements are valid', () {
        expect(canBeSentToIsolate([1, 2, 3]), true);
        expect(canBeSentToIsolate(['a', 'b', 'c']), true);
        expect(canBeSentToIsolate([true, false]), true);
        expect(canBeSentToIsolate([1, 'mixed', true]), true);
      });

      test('Maps with sendable keys and values are valid', () {
        expect(canBeSentToIsolate({'key': 'value'}), true);
        expect(canBeSentToIsolate({1: 100, 2: 200}), true);
        expect(canBeSentToIsolate({'a': 1, 'b': 2.5}), true);
      });

      test('Sets with sendable elements are valid', () {
        expect(canBeSentToIsolate({1, 2, 3}), true);
        expect(canBeSentToIsolate({'apple', 'banana'}), true);
      });

      test('Nested collections with valid elements are sendable', () {
        expect(
          canBeSentToIsolate([
            [1, 2],
            [3, 4]
          ]),
          true,
        );

        expect(
          canBeSentToIsolate({
            'users': [
              {'name': 'Alice', 'age': 30},
              {'name': 'Bob', 'age': 25}
            ]
          }),
          true,
        );
      });
    });

    group('canBeSentToIsolate - Invalid Types', () {
      test('ReceivePort is not sendable', () {
        final receivePort = ReceivePort();
        expect(canBeSentToIsolate(receivePort), false);
        receivePort.close();
      });

      test('Completer is not sendable', () {
        final completer = Completer<int>();
        expect(canBeSentToIsolate(completer), false);
      });

      test('Stream is not sendable', () {
        final stream = Stream.value(42);
        expect(canBeSentToIsolate(stream), false);
      });

      test('StreamController is not sendable', () {
        final controller = StreamController<int>();
        expect(canBeSentToIsolate(controller), false);
        controller.close();
      });

      test('IsolatePool is not sendable', () {
        final pool = IsolatePool(2);
        expect(canBeSentToIsolate(pool), false);
      });

      test('Lists containing non-sendable elements are invalid', () {
        final completer = Completer<int>();
        expect(canBeSentToIsolate([1, 2, completer]), false);
      });

      test('Maps containing non-sendable values are invalid', () {
        final stream = Stream.value(42);
        expect(canBeSentToIsolate({'data': stream}), false);
      });

      test('Nested collections with non-sendable elements are invalid', () {
        final completer = Completer<int>();
        expect(
          canBeSentToIsolate([
            [1, 2],
            [completer, 4]
          ]),
          false,
        );
      });
    });

    group('PooledInstance Validation', () {
      test('Simple valid instance passes validation', () {
        final instance = SimpleData('test', 42);
        final errors = instance.validateForIsolate();
        expect(errors, isEmpty);
      });

      test('Instance with collections passes validation', () {
        final instance = DataWithCollections(
          [1, 2, 3],
          {'math': 95.5, 'science': 88.0},
          {'flutter', 'dart'},
        );
        final errors = instance.validateForIsolate();
        expect(errors, isEmpty);
      });

      test('Instance with Completer fails validation', () {
        final instance = InvalidInstanceWithCompleter();
        final errors = instance.validateForIsolate();
        expect(errors, isNotEmpty);
        expect(errors.first, contains('non-sendable objects'));
      });

      test('Instance with StreamController fails validation', () {
        final instance = InvalidInstanceWithStream();
        final errors = instance.validateForIsolate();
        expect(errors, isNotEmpty);
        expect(errors.first, contains('non-sendable objects'));
      });

      test('Validation error contains helpful message', () {
        final instance = InvalidInstanceWithCompleter();
        final errors = instance.validateForIsolate();
        expect(errors.first, contains('Completer'));
        expect(errors.first, contains('NEVER sendable'));
      });
    });

    group('Real-world Scenarios', () {
      test('JSON-like data structures are sendable', () {
        final jsonData = {
          'id': 123,
          'name': 'John Doe',
          'email': 'john@example.com',
          'active': true,
          'score': 85.5,
          'tags': ['developer', 'flutter'],
          'metadata': {
            'created': '2024-01-01',
            'updated': '2024-01-15',
          },
        };

        expect(canBeSentToIsolate(jsonData), true);
      });

      test('Configuration objects are sendable', () {
        final config = {
          'apiUrl': 'https://api.example.com',
          'timeout': 30,
          'retries': 3,
          'headers': {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          'features': {
            'caching': true,
            'logging': false,
          },
        };

        expect(canBeSentToIsolate(config), true);
      });

      test('List of model objects (as maps) is sendable', () {
        final users = [
          {'id': 1, 'name': 'Alice', 'role': 'admin'},
          {'id': 2, 'name': 'Bob', 'role': 'user'},
          {'id': 3, 'name': 'Charlie', 'role': 'user'},
        ];

        expect(canBeSentToIsolate(users), true);
      });

      test('Mixed numeric data for calculations is sendable', () {
        final data = {
          'values': [1.5, 2.3, 3.7, 4.2],
          'weights': [0.25, 0.25, 0.25, 0.25],
          'count': 4,
          'average': 2.925,
        };

        expect(canBeSentToIsolate(data), true);
      });
    });

    group('Edge Cases', () {
      test('Deeply nested valid structures are sendable', () {
        final deepStructure = {
          'level1': {
            'level2': {
              'level3': {
                'level4': {
                  'value': 42,
                }
              }
            }
          }
        };

        expect(canBeSentToIsolate(deepStructure), true);
      });

      test('Large list of primitives is sendable', () {
        final largeList = List.generate(10000, (i) => i);
        expect(canBeSentToIsolate(largeList), true);
      });

      test('Empty instance is sendable', () {
        final instance = SimpleData('', 0);
        final errors = instance.validateForIsolate();
        expect(errors, isEmpty);
      });
    });

    group('Integration with IsolatePool', () {
      late IsolatePool pool;

      setUp(() async {
        pool = IsolatePool(2);
        await pool.start();
      });

      tearDown(() {
        pool.stop();
      });

      test('Pool accepts valid instances', () async {
        final instance = SimpleData('valid', 123);

        // Should successfully add the instance
        final proxy = await pool.addInstance(instance);
        expect(proxy, isNotNull);
        expect(pool.numberOfPooledInstances, 1);
      });

      test('Pool rejects instance with Completer', () async {
        final instance = InvalidInstanceWithCompleter();

        // Should throw IsolatePoolException with validation error
        await expectLater(
          pool.addInstance(instance),
          throwsA(
            isA<IsolatePoolException>().having(
              (e) => e.toString(),
              'error message',
              allOf(
                contains('validation errors'),
                contains('non-sendable'),
              ),
            ),
          ),
        );

        // Instance should not be added
        expect(pool.numberOfPooledInstances, 0);
      });

      test('Pool rejects instance with StreamController', () async {
        final instance = InvalidInstanceWithStream();

        // Should throw IsolatePoolException
        await expectLater(
          pool.addInstance(instance),
          throwsA(isA<IsolatePoolException>()),
        );

        // Instance should not be added
        expect(pool.numberOfPooledInstances, 0);
      });

      test('Validation error includes helpful documentation', () async {
        final instance = InvalidInstanceWithCompleter();

        try {
          await pool.addInstance(instance);
          fail('Should have thrown an exception');
        } catch (e) {
          final errorMessage = e.toString();

          // Should contain list of sendable types
          expect(errorMessage, contains('bool'));
          expect(errorMessage, contains('int'));
          expect(errorMessage, contains('String'));
          expect(errorMessage, contains('List, Map, or Set'));

          // Should contain list of non-sendable types
          expect(errorMessage, contains('Completer'));
          expect(errorMessage, contains('Stream'));
          expect(errorMessage, contains('ReceivePort'));

          // Should contain link to documentation
          expect(errorMessage, contains('https://api.flutter.dev'));
        }
      });

      test('Pool can add multiple valid instances after rejection', () async {
        final invalidInstance = InvalidInstanceWithCompleter();

        // First attempt should fail
        await expectLater(
          pool.addInstance(invalidInstance),
          throwsA(isA<IsolatePoolException>()),
        );

        expect(pool.numberOfPooledInstances, 0);

        // But we can still add valid instances
        final valid1 = SimpleData('first', 1);
        final valid2 = SimpleData('second', 2);

        await pool.addInstance(valid1);
        await pool.addInstance(valid2);

        expect(pool.numberOfPooledInstances, 2);
      });

      test('Validation prevents runtime errors in isolates', () async {
        // This demonstrates why validation is important:
        // Without validation, attempting to send a Completer to an isolate
        // would cause a runtime error that's harder to debug.
        // With validation, we get a clear error message immediately.

        final instanceWithCompleter = InvalidInstanceWithCompleter();

        String? errorMessage;
        try {
          await pool.addInstance(instanceWithCompleter);
        } catch (e) {
          errorMessage = e.toString();
        }

        // Validation caught the problem before it reached the isolate
        expect(errorMessage, isNotNull);
        expect(errorMessage, contains('validation errors'));

        // Pool remains functional
        final validInstance = SimpleData('works', 42);
        final proxy = await pool.addInstance(validInstance);
        expect(proxy, isNotNull);
      });
    });
  });

  //

  group('Job Closure Validation Tests', () {
    group('Job Closure Validation - Real World Scenarios', () {
      late IsolatePool pool;

      setUp(() async {
        pool = IsolatePool(2);
        await pool.start();
      });

      tearDown(() {
        pool.stop();
      });

      test('Repository with StreamController - closure method should fail validation', () async {
        final repo = NumbersTrivalRepository(pool);

        // The dangerous method should be rejected at send time
        await expectLater(
          repo.methodThatReturnsNumberDangerous(5, 10),
          throwsA(
            isA<IsolatePoolException>().having(
              (e) => e.toString(),
              'error message',
              contains('non-sendable'),
            ),
          ),
        );

        // Verify isolate is still alive after error
        final isHealthy = await pool.pingIsolate(0);
        expect(isHealthy, true, reason: 'Isolate should remain alive after error');

        // Verify we can still schedule jobs
        final result = await repo.methodThatReturnsNumberSafe(5, 10);
        expect(result, 15);

        repo.dispose();
      });

      test('Repository with StreamController - static method should work', () async {
        final repo = NumbersTrivalRepository(pool);

        // The safe method should work fine
        final result = await repo.methodThatReturnsNumberSafe(5, 10);
        expect(result, 15);

        repo.dispose();
      });

      test('Repository with Completer - closure method should fail validation', () async {
        final repo = DataRepository(pool);

        // The dangerous method should be rejected at send time
        await expectLater(
          repo.fetchDataWithClosure('https://api.example.com'),
          throwsA(
            isA<IsolatePoolException>().having(
              (e) => e.toString(),
              'error message',
              contains('non-sendable'),
            ),
          ),
        );

        // Verify isolate is still alive after error
        final isHealthy = await pool.pingIsolate(0);
        expect(isHealthy, true, reason: 'Isolate should remain alive after error');

        // Verify we can still schedule jobs
        final result = await repo.fetchDataSafe('https://api.example.com');
        expect(result, contains('Data from'));
      });

      test('Repository with Completer - static method should work', () async {
        final repo = DataRepository(pool);

        // The safe method should work fine
        final result = await repo.fetchDataSafe('https://api.example.com');
        expect(result, contains('Data from'));
      });

      test('Job with only primitives should pass validation', () async {
        final job = SafeCalculationJob(10, 20);

        final result = await pool.scheduleJob(job);
        expect(result, 30);
      });

      test('Validation error provides helpful guidance', () async {
        final repo = NumbersTrivalRepository(pool);

        try {
          await repo.methodThatReturnsNumberDangerous(1, 2);
          fail('Should have thrown validation error');
        } catch (e) {
          final errorMessage = e.toString();

          // Should explain common causes
          expect(errorMessage, contains('Common causes'));
          expect(errorMessage, contains('closure'));
          expect(errorMessage, contains('captures "this"'));

          // Should provide solutions
          expect(errorMessage, contains('Solutions'));
          expect(errorMessage, contains('static or top-level functions'));

          // Should link to documentation
          expect(errorMessage, contains('BEST_PRACTICES.md'));
        }

        // Verify isolate is still alive after error
        final isHealthy = await pool.pingIsolate(0);
        expect(isHealthy, true, reason: 'Isolate should remain alive after error');

        repo.dispose();
      });
    });

    group('Job Closure Validation - Edge Cases', () {
      late IsolatePool pool;

      setUp(() async {
        pool = IsolatePool(2);
        await pool.start();
      });

      tearDown(() {
        pool.stop();
      });

      test('Nested closures capturing non-sendable objects are caught', () async {
        final controller = StreamController<String>();

        final job = TwoParamsJob<int, int, String>(
          1,
          2,
          (a, b) {
            // This captures controller from outer scope
            controller.add('test');
            return 'result';
          },
        );

        await expectLater(
          pool.scheduleJob(job),
          throwsA(isA<IsolatePoolException>()),
        );

        // Verify isolate is still alive after error
        final isHealthy = await pool.pingIsolate(0);
        expect(isHealthy, true, reason: 'Isolate should remain alive after error');

        controller.close();
      });

      test('Top-level function reference works', () async {
        final job = TwoParamsJob<int, int, int>(5, 3, _topLevelAdd);

        final result = await pool.scheduleJob(job);
        expect(result, 8);
      });

      test('Lambda with only local variables (no captures) might work', () async {
        // This is a pure lambda - no external captures
        // Note: This test demonstrates the limitation - we can't always detect "safe" closures
        final job = TwoParamsJob<int, int, int>(
          10,
          5,
          (a, b) => a * b,
        );

        // This might pass or fail depending on Dart's closure implementation
        // The validation is conservative and may reject some safe closures
        try {
          final result = await pool.scheduleJob(job);
          expect(result, 50);
        } on IsolatePoolException {
          // This is acceptable - conservative validation
          // Better to reject some safe cases than allow unsafe ones
        }
      });
    });

    group('Documentation Examples', () {
      late IsolatePool pool;

      setUp(() async {
        pool = IsolatePool(2);
        await pool.start();
      });

      tearDown(() {
        pool.stop();
      });

      test('Example: Wrong way - closure captures context', () async {
        final repository = ExampleRepository(pool);

        // ❌ WRONG: This will fail at send time
        await expectLater(
          repository.badExample(),
          throwsA(isA<IsolatePoolException>()),
        );

        // Verify isolate is still alive after error
        final isHealthy = await pool.pingIsolate(0);
        expect(isHealthy, true, reason: 'Isolate should remain alive after error');

        repository.dispose();
      });

      test('Example: Right way - use static function', () async {
        final repository = ExampleRepository(pool);

        // ✅ CORRECT: This works
        final result = await repository.goodExample();
        expect(result, 42);

        repository.dispose();
      });
    });

    group('Isolate Remains Functional After Errors', () {
      late IsolatePool pool;

      setUp(() async {
        pool = IsolatePool(2);
        await pool.start();
      });

      tearDown(() {
        pool.stop();
      });

      test('Isolate can process jobs after catching unsendable error', () async {
        final controller = StreamController<String>();

        // First, try to send a job with a closure that captures non-sendable object
        await expectLater(
          pool.scheduleJob(
            TwoParamsJob<int, int, int>(5, 10, (a, b) {
              // This closure captures 'controller' from outer scope
              controller.add('test');
              return a + b;
            }),
          ),
          throwsA(isA<IsolatePoolException>()),
        );

        // Verify isolate is still alive
        final isHealthy = await pool.pingIsolate(0);
        expect(isHealthy, true, reason: 'Isolate should remain alive after error');

        // Now verify the isolate is still functional by sending safe jobs
        final result = await pool.scheduleJob(SafeJob(21));
        expect(result, 42);

        // Verify we can send multiple more jobs
        final result2 = await pool.scheduleJob(SafeJob(10));
        expect(result2, 20);

        final result3 = await pool.scheduleJob(SafeJob(15));
        expect(result3, 30);

        controller.close();
      });

      test('Multiple unsendable errors do not break the pool', () async {
        final controller1 = StreamController<String>();
        final controller2 = StreamController<int>();

        // Send first unsendable job
        await expectLater(
          pool.scheduleJob(
            TwoParamsJob<int, int, int>(1, 2, (a, b) {
              controller1.add('test');
              return a + b;
            }),
          ),
          throwsA(isA<IsolatePoolException>().having(
            (e) => e.toString(),
            'This is likely because your PooledJob uses a closure that captures non-sendable objects.',
            contains('non-sendable'),
          )),
        );

        // Verify isolate 0 is still alive
        var isHealthy = await pool.pingIsolate(0);
        expect(isHealthy, true, reason: 'Isolate 0 should remain alive after first error');

        // Send second unsendable job
        await expectLater(
          pool.scheduleJob(
            TwoParamsJob<int, int, int>(3, 4, (a, b) {
              controller2.add(1);
              return a + b;
            }),
          ),
          throwsA(isA<IsolatePoolException>()),
        );

        // Verify both isolates are still alive
        isHealthy = await pool.pingIsolate(0);
        expect(isHealthy, true, reason: 'Isolate 0 should remain alive after second error');
        isHealthy = await pool.pingIsolate(1);
        expect(isHealthy, true, reason: 'Isolate 1 should remain alive after errors');

        // Pool should still work
        final result1 = await pool.scheduleJob(SafeJob(5));
        expect(result1, 10);

        final result2 = await pool.scheduleJob(SafeJob(7));
        expect(result2, 14);

        controller1.close();
        controller2.close();
      });

      test('Pool continues working after unsendable errors', () async {
        final controller = StreamController<int>();

        // Initial state
        expect(pool.numberOfIsolates, 2);

        // Send unsendable job
        await expectLater(
          pool.scheduleJob(
            TwoParamsJob<int, int, int>(1, 2, (a, b) {
              controller.add(1);
              return a + b;
            }),
          ),
          throwsA(isA<IsolatePoolException>()),
        );

        // Verify isolate is still alive after error
        final isHealthy = await pool.pingIsolate(0);
        expect(isHealthy, true, reason: 'Isolate should remain alive');

        // Send valid jobs to verify pool continues working
        final result1 = await pool.scheduleJob(SafeJob(10));
        expect(result1, 20);

        final result2 = await pool.scheduleJob(SafeJob(15));
        expect(result2, 30);

        // Verify both isolates are still healthy
        final isHealthy0 = await pool.pingIsolate(0);
        expect(isHealthy0, true, reason: 'Isolate 0 should remain alive');
        final isHealthy1 = await pool.pingIsolate(1);
        expect(isHealthy1, true, reason: 'Isolate 1 should remain alive');

        controller.close();
      });

      test('Can process safe jobs immediately after unsendable error', () async {
        final controller = StreamController<String>();

        // Schedule a safe job, then unsendable job, then another safe job
        final safeFuture1 = pool.scheduleJob(SafeJob(1));

        await expectLater(
          pool.scheduleJob(
            TwoParamsJob<int, int, int>(5, 10, (a, b) {
              controller.add('bad');
              return a + b;
            }),
          ),
          throwsA(isA<IsolatePoolException>()),
        );

        final safeFuture2 = pool.scheduleJob(SafeJob(2));

        // All safe jobs should complete successfully
        expect(await safeFuture1, 2);
        expect(await safeFuture2, 4);

        // Verify both isolates are still alive
        var isHealthy = await pool.pingIsolate(0);
        expect(isHealthy, true, reason: 'Isolate 0 should remain alive');
        isHealthy = await pool.pingIsolate(1);
        expect(isHealthy, true, reason: 'Isolate 1 should remain alive');

        controller.close();
      });
    });
  });
}

// Top-level function for testing
int _topLevelAdd(int a, int b) => a + b;

// Example class for documentation
class ExampleRepository {
  final StreamController<int> _streamController;
  final IsolatePool pool;

  ExampleRepository(this.pool) : _streamController = StreamController<int>();

  // ❌ BAD: Closure captures 'this' which includes _streamController
  Future<int> badExample() {
    return pool.scheduleJob(
      TwoParamsJob(20, 22, (a, b) {
        // Access the captured _streamController to force the error
        final hasListener = _streamController.hasListener;
        return a + b + (hasListener ? 0 : 0);
      }),
    );
  }

  // ✅ GOOD: Static function doesn't capture anything
  Future<int> goodExample() {
    return pool.scheduleJob(
      TwoParamsJob(20, 22, _add),
    );
  }

  static int _add(int a, int b) => a + b;

  void dispose() {
    _streamController.close();
  }
}
