import 'package:isolate_pool_2/isolate_pool_2.dart';
import 'package:test/test.dart';

// Test worker
class TestWorker extends PooledInstance {
  final String name;

  TestWorker(this.name);

  @override
  Future<void> init() async {
    // Simple init
  }

  @override
  Future<dynamic> receiveRemoteCall(Action action) async {
    switch (action) {
      case GetNameAction():
        return name;
      default:
        throw Exception('Unknown action');
    }
  }
}

class GetNameAction extends Action {}

// Test job
class TestJob extends PooledJob<String> {
  final String message;

  TestJob(this.message);

  @override
  Future<String> job() async {
    return 'Job result: $message';
  }
}

void main() {
  group('Isolate Index Tests', () {
    late IsolatePool pool;

    setUp(() async {
      pool = IsolatePool(2);
      await pool.start();
    });

    tearDown(() {
      pool.stop();
    });

    test('scheduleJob targets correct isolate', () async {
      // Schedule job to isolate 0
      final result1 = await pool.scheduleJob(TestJob('on isolate 0'), 0);
      expect(result1, contains('Job result'));

      // Schedule job to isolate 1
      final result2 = await pool.scheduleJob(TestJob('on isolate 1'), 1);
      expect(result2, contains('Job result'));
    });

    test('scheduleJob throws on invalid isolate index', () async {
      expect(
        () => pool.scheduleJob(TestJob('invalid'), 5),
        throwsA(isA<IsolatePoolException>()),
      );
    });

    test('addInstance targets correct isolate', () async {
      // Create instance on isolate 0
      final worker1 = TestWorker('Worker1');
      final proxy1 = await pool.addInstance(worker1, isolateIndex: 0);

      expect(proxy1.isolateId, equals(0));

      // Create instance on isolate 1
      final worker2 = TestWorker('Worker2');
      final proxy2 = await pool.addInstance(worker2, isolateIndex: 1);

      expect(proxy2.isolateId, equals(1));
    });

    test('addInstance load balances when isolateIndex is -1', () async {
      // Create multiple instances without specifying isolate
      final workers = <PooledInstanceProxy>[];

      for (var i = 0; i < 4; i++) {
        final worker = TestWorker('Worker$i');
        final proxy = await pool.addInstance(worker);
        workers.add(proxy);
      }

      // Check that instances are distributed across isolates
      final isolatesUsed = workers.map((w) => w.isolateId).toSet();
      expect(isolatesUsed.length, greaterThan(1), reason: 'Instances should be load balanced');
    });

    test('destroyInstance handles double-destroy gracefully', () async {
      final worker = TestWorker('TestWorker');
      final proxy = await pool.addInstance(worker);

      // First destroy should work
      pool.destroyInstance(proxy);

      // Second destroy should not throw (prints warning instead)
      expect(() => pool.destroyInstance(proxy), returnsNormally);
    });

    test('destroyInstance with isolateIndex parameter', () async {
      final worker = TestWorker('TestWorker');
      final proxy = await pool.addInstance(worker, isolateIndex: 1);

      // Destroy from specific isolate
      expect(() => pool.destroyInstance(proxy, isolate: 1), returnsNormally);
    });

    test('destroyInstance throws on invalid isolateIndex', () async {
      final worker = TestWorker('TestWorker');
      final proxy = await pool.addInstance(worker);

      expect(
        () => pool.destroyInstance(proxy, isolate: 10),
        throwsA(isA<IsolatePoolException>()),
      );
    });

    test('callRemoteMethod uses instance home isolate by default', () async {
      final worker = TestWorker('TestWorker');
      final proxy = await pool.addInstance(worker, isolateIndex: 0);

      // Should work on home isolate
      final result = await proxy.callRemoteMethod<String>(GetNameAction());
      expect(result, equals('TestWorker'));
    });

    test('callRemoteMethod with explicit isolateIndex', () async {
      final worker = TestWorker('TestWorker');
      final proxy = await pool.addInstance(worker, isolateIndex: 0);

      // Call on home isolate explicitly
      final result = await proxy.callRemoteMethod<String>(
        GetNameAction(),
        isolate: 0,
      );
      expect(result, equals('TestWorker'));
    });
  });
}
