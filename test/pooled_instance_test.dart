/// Pooled instance functionality tests
@TestOn('vm')
library;

import 'dart:async';

import 'package:isolate_pool_2/isolate_pool_2.dart';
import 'package:test/test.dart';

// Test instance A with simple operations
class InstanceA extends PooledInstance {
  int sum(int x, int y) {
    return x + y;
  }

  Future wait(int durationMs) async {
    await Future.delayed(Duration(milliseconds: durationMs));
  }

  Future<String> concat(String arg1, String arg2) {
    return Future(() => arg1 + arg2);
  }

  void deffered(int value, Function callback) {
    Future.delayed(Duration(milliseconds: 10), () {
      callback(value + 1);
    });
  }

  void fail() {
    throw 'Action failed';
  }

  @override
  Future init() async {
    // Simple initialization
  }

  @override
  Future receiveRemoteCall(Action action) async {
    switch (action) {
      case SumIntAction _:
        var ac = action;
        return sum(ac.x, ac.y);
      case ConcatAction _:
        var ac = action;
        return concat(ac.x, ac.y);
      case CallbackIssuingAction _:
        var ac = action;
        return deffered(ac.x, (y) async {
          var x = await callRemoteMethod<int>(CallbackAction(y));
          await callRemoteMethod(CallbackAction(x + 1));
        });
      case FailAction _:
        return fail();
      default:
        throw 'Unknown action';
    }
  }
}

// Test instance B with different operations
class InstanceB extends PooledInstance {
  double sum(double x, double y) {
    return x + y;
  }

  @override
  Future init() async {
    // Simple initialization
  }

  @override
  Future receiveRemoteCall(Action action) async {
    switch (action) {
      case SumIntAction _:
        var ac = action;
        return ac.x + ac.y;
      case SumDynamicAction _:
        var ac = action;
        if (ac.x is int && ac.y is int) return (ac.x + ac.y) as int;
        if (ac.x is double && ac.y is double) return sum(ac.x, ac.y);
        throw 'SumDynamic supports only int and double';
      default:
        throw 'Unknown action recevied';
    }
  }
}

// Test worker that can fail on start
class WorkerWithInit extends PooledInstance {
  final bool failOnStart;

  WorkerWithInit({this.failOnStart = false});

  @override
  Future init() async {
    if (failOnStart) throw 'Failed on start';
    await Future.delayed(Duration(milliseconds: 10));
  }

  @override
  Future receiveRemoteCall(Action action) async {
    if (action is GetNameAction) {
      return 'Worker';
    }
    return null;
  }
}

// Value holder for state testing
class ValueHolder extends PooledInstance {
  String initialValue;
  ValueHolder(this.initialValue);

  late List<String> _values;

  @override
  Future init() async {
    _values = [initialValue];
  }

  @override
  Future<dynamic> receiveRemoteCall(Action action) async {
    switch (action) {
      case GetValues _:
        return _values;
      case SetValue _:
        var v = action.value;
        _values.add(v);
        return;
      default:
        throw 'Unknown action ${action.runtimeType}';
    }
  }
}

// Actions for testing
class SumIntAction extends Action {
  final int x;
  final int y;
  SumIntAction(this.x, this.y);
}

class SumDynamicAction extends Action {
  final dynamic x;
  final dynamic y;
  SumDynamicAction(this.x, this.y);
}

class ConcatAction extends Action {
  final String x;
  final String y;
  ConcatAction(this.x, this.y);
}

class CallbackIssuingAction extends Action {
  final int x;
  CallbackIssuingAction(this.x);
}

class CallbackAction extends Action {
  final int x;
  CallbackAction(this.x);
}

class FailAction extends Action {}

class GetNameAction extends Action {}

class GetValues extends Action {}

class SetValue extends Action {
  final String value;
  SetValue(this.value);
}

class UnknownAction extends Action {}

void main() {
  group('Instance Creation and Lifecycle', () {
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

    test('Creating single pooled instance', () async {
      await pool.addInstance(InstanceA());
      expect(pool.numberOfPooledInstances, 1);
    });

    test('Creating multiple pooled instances', () async {
      for (var i = 0; i < 20; i++) {
        await pool.addInstance(InstanceA());
      }
      expect(pool.numberOfPooledInstances, 20);
    });

    test('Creating different type pooled instances', () async {
      for (var i = 0; i < 20; i++) {
        await pool.addInstance(i % 2 == 0 ? InstanceA() : InstanceB());
      }
      expect(pool.numberOfPooledInstances, 20);
    });

    test('Instances are created in different isolates', () async {
      var instances = <PooledInstanceProxy>[];
      for (var i = 0; i < 20; i++) {
        var pi = await pool.addInstance(i % 2 == 0 ? InstanceA() : InstanceB());
        instances.add(pi);
      }
      expect(pool.numberOfPooledInstances, 20);

      var pools = List<int>.filled(4, 0);
      for (var pi in instances) {
        pools[pool.indexOfInstance(pi)]++;
      }

      for (var p in pools) {
        expect(p, 5);
      }
    });

    test('Instance with initialization failure', () async {
      var errorMessage = '';
      try {
        await pool.addInstance(WorkerWithInit(failOnStart: true));
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('Failed on start'));
    });

    test('Instance on specific isolate', () async {
      final instance = await pool.addInstance(InstanceA(), isolateIndex: 0);
      expect(instance.isolateId, 0);

      final instance2 = await pool.addInstance(InstanceA(), isolateIndex: 1);
      expect(instance2.isolateId, 1);
    });

    test('Instance with invalid isolate index', () async {
      await expectLater(
        pool.addInstance(InstanceA(), isolateIndex: 10),
        throwsA(isA<IsolatePoolException>()),
      );
    });
  });

  group('Instance Destruction', () {
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

    test('Destroy pooled instance', () async {
      var instances = <PooledInstanceProxy>[];
      for (var i = 0; i < 5; i++) {
        var pi = await pool.addInstance(InstanceA());
        instances.add(pi);
      }
      expect(pool.numberOfPooledInstances, 5);

      pool.destroyInstance(instances[0]);
      expect(pool.numberOfPooledInstances, 4);
    });

    test('Destroy already destroyed instance', () async {
      var instance = await pool.addInstance(InstanceA());

      pool.destroyInstance(instance);
      expect(pool.numberOfPooledInstances, 0);

      // Destroying an already destroyed instance should not throw
      pool.destroyInstance(instance);
      expect(pool.numberOfPooledInstances, 0);
    });

    test('Destroy instance from specific isolate', () async {
      final instance = await pool.addInstance(InstanceA(), isolateIndex: 1);

      pool.destroyInstance(instance, isolate: 1);
      expect(pool.numberOfPooledInstances, 0);
    });

    test('Destroy instance with wrong isolate index throws', () async {
      final instance = await pool.addInstance(InstanceA(), isolateIndex: 0);

      expect(
        () => pool.destroyInstance(instance, isolate: 2),
        throwsA(isA<IsolatePoolException>()),
      );
    });

    test('Pooled instance can be destroyed', () async {
      var pi = ValueHolder('Hello');
      var px = await pool.addInstance(pi);
      var r = await px.callRemoteMethod<List<String>>(GetValues());

      expect(r[0], 'Hello');

      pool.destroyInstance(px);

      expect(() => px.callRemoteMethod(GetValues()), throwsA(isA<NoSuchIsolateInstanceException>()));
    });
  });

  group('Remote Method Calls', () {
    late IsolatePool pool;
    late PooledInstanceProxy instanceA;
    late PooledInstanceProxy instanceB;

    setUp(() async {
      pool = IsolatePool(4);

      // Suppress error logs for cleaner test output
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.start();
      instanceA = await pool.addInstance(InstanceA());
      instanceB = await pool.addInstance(InstanceB());
    });

    tearDown(() {
      pool.stop();
    });

    test('Simple action returns result', () async {
      var res = await instanceA.callRemoteMethod(SumIntAction(2, 2));
      expect(res, 4);
    });

    test('Async action returns result', () async {
      var res = await instanceA.callRemoteMethod(ConcatAction('Hello ', 'world'));
      expect(res, 'Hello world');
    });

    test('Failed action returns error', () async {
      var errorMessage = '';
      try {
        await instanceA.callRemoteMethod(FailAction());
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('Action failed'));
    });

    test('Unknown action throws error', () async {
      var errorMessage = '';
      try {
        await instanceB.callRemoteMethod(ConcatAction('', ''));
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('Unknown action recevied'));
    });

    test('Dynamic type handling', () async {
      var intResult = await instanceB.callRemoteMethod<int>(SumDynamicAction(1, 2));
      expect(intResult, 3);

      var doubleResult = await instanceB.callRemoteMethod<double>(SumDynamicAction(10.5, 10.5));
      expect(doubleResult, 21.0);
    });

    test('Invalid dynamic types throw error', () async {
      var errorMessage = '';
      try {
        await instanceB.callRemoteMethod<int>(SumDynamicAction('', ''));
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('SumDynamic supports only int and double'));
    });

    test('Multiple concurrent requests to same instance', () async {
      var futures = <Future>[];
      for (int i = 0; i < 50; i++) {
        futures.add(instanceA.callRemoteMethod(SumIntAction(i, i)));
      }

      var results = await Future.wait(futures);
      for (int i = 0; i < 50; i++) {
        expect(results[i], i * 2);
      }
    });

    test('Sending second request before first completes', () async {
      var f1 = instanceA.callRemoteMethod(CallbackIssuingAction(1));
      var f2 = instanceA.callRemoteMethod(SumIntAction(1, 1));

      await f1;
      var x2 = await f2;
      expect(x2, 2);
    });
  });

  group('State Management', () {
    late IsolatePool pool;

    setUp(() async {
      pool = IsolatePool(2);

      // Suppress error logs for cleaner test output
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.start();
    });

    tearDown(() {
      pool.stop();
    });

    test('Pooled instance maintains state', () async {
      var pi = ValueHolder('Hello');
      var px = await pool.addInstance(pi);
      var r = await px.callRemoteMethod<List<String>>(GetValues());

      expect(r[0], 'Hello');

      await px.callRemoteMethod(SetValue('world'));
      r = await px.callRemoteMethod<List<String>>(GetValues());

      expect(r[0], 'Hello');
      expect(r[1], 'world');
    });

    test('Multiple instances have independent state', () async {
      var instance1 = await pool.addInstance(ValueHolder('First'));
      var instance2 = await pool.addInstance(ValueHolder('Second'));

      await instance1.callRemoteMethod(SetValue('Value1'));
      await instance2.callRemoteMethod(SetValue('Value2'));

      var result1 = await instance1.callRemoteMethod<List<String>>(GetValues());
      var result2 = await instance2.callRemoteMethod<List<String>>(GetValues());

      expect(result1, ['First', 'Value1']);
      expect(result2, ['Second', 'Value2']);
    });

    test('Pooled instance throws on unknown action', () async {
      var pi = ValueHolder('Hello');
      var px = await pool.addInstance(pi);
      var r = await px.callRemoteMethod<List<String>>(GetValues());

      expect(r[0], 'Hello');

      expect(
        px.callRemoteMethod(UnknownAction()),
        throwsA(
          isA<IsolateError>().having(
            (e) => e.toString(),
            'error message',
            contains('Unknown action UnknownAction'),
          ),
        ),
      );
    });
  });

  group('Instance Callbacks', () {
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

    test('Instance with callback receives calls', () async {
      var completer = Completer<int>();
      var callCount = 0;

      var instance = await pool.addInstance(InstanceA(), callback: (a) {
        if (a is CallbackAction) {
          callCount++;
          if (callCount == 1) {
            completer.complete(a.x);
          }
          return a.x + 1;
        }
        return null;
      });

      await instance.callRemoteMethod(CallbackIssuingAction(1));

      var res = await completer.future;
      expect(res, 2);

      // Wait for second callback
      await Future.delayed(Duration(milliseconds: 50));
      expect(callCount, 2);
    });

    test('Instance without callback handles gracefully', () async {
      var instance = await pool.addInstance(InstanceA());

      // Should not throw when callback is called but not set
      await instance.callRemoteMethod(CallbackIssuingAction(1));

      // Wait a bit to ensure no errors
      await Future.delayed(Duration(milliseconds: 50));

      // Should still be able to make normal calls
      var result = await instance.callRemoteMethod(SumIntAction(5, 5));
      expect(result, 10);
    });
  });

  group('Instance Health and Pool State', () {
    test('Calling method with pool stopped throws', () async {
      var pool = IsolatePool(4);
      await pool.start();

      var instance = await pool.addInstance(InstanceA());
      expect(pool.numberOfPooledInstances, 1);

      pool.stop();

      expect(
        () => instance.callRemoteMethod(SumIntAction(1, 1)),
        throwsA(isA<IsolatePoolStoppedException>()),
      );
    });

    test('Stopping pool with pending instance creation', () async {
      var pool = IsolatePool(5);
      await pool.start();

      late Future f;
      var errorMessage = '';

      try {
        for (var i = 0; i < 25; i++) {
          f = pool.addInstance(InstanceA());
          if (i < 24) await f;
        }

        pool.stop();
        await f;
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('cancelling instance creation requests'));
    });

    test('Stopping pool with pending requests', () async {
      var pool = IsolatePool(5);
      await pool.start();

      late Future f;
      late PooledInstanceProxy pi;
      var errorMessage = '';

      try {
        for (var i = 0; i < 25; i++) {
          pi = await pool.addInstance(InstanceA());
        }

        expect(pool.numberOfPooledInstances, 25);

        for (var i = 0; i < 25; i++) {
          f = pi.callRemoteMethod<int>(SumIntAction(i, 1));
          if (i < 24) await f;
        }

        pool.stop();
        await f;
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('cancelling pending request'));
    });

    test('Instance cleanup on pool stop', () async {
      final pool = IsolatePool(3);
      await pool.start();

      // Create multiple instances
      final instances = <PooledInstanceProxy>[];
      for (int i = 0; i < 6; i++) {
        instances.add(await pool.addInstance(InstanceA()));
      }

      expect(pool.numberOfPooledInstances, 6);

      // Stop pool
      pool.stop();

      // All operations should fail after stop
      for (final instance in instances) {
        expect(
          () => instance.callRemoteMethod(SumIntAction(1, 1)),
          throwsA(isA<IsolatePoolStoppedException>()),
        );
      }
    });
  });

  group('Instance Load Distribution', () {
    test('Instances distributed evenly across isolates', () async {
      final pool = IsolatePool(4);
      await pool.start();

      final instanceCounts = List<int>.filled(4, 0);

      // Create 40 instances
      for (int i = 0; i < 40; i++) {
        final instance = await pool.addInstance(InstanceA());
        instanceCounts[pool.indexOfInstance(instance)]++;
      }

      // Each isolate should have roughly the same number of instances
      for (var count in instanceCounts) {
        expect(count, 10);
      }

      pool.stop();
    });

    test('Load balancing with mixed instance types', () async {
      final pool = IsolatePool(3);
      await pool.start();

      final instances = <PooledInstanceProxy>[];

      // Create different types of instances
      for (int i = 0; i < 30; i++) {
        if (i % 3 == 0) {
          instances.add(await pool.addInstance(InstanceA()));
        } else if (i % 3 == 1) {
          instances.add(await pool.addInstance(InstanceB()));
        } else {
          instances.add(await pool.addInstance(WorkerWithInit()));
        }
      }

      expect(pool.numberOfPooledInstances, 30);

      // Verify all instances are functional
      for (int i = 0; i < instances.length; i++) {
        if (i % 3 == 0) {
          final result = await instances[i].callRemoteMethod(SumIntAction(i, i));
          expect(result, i * 2);
        } else if (i % 3 == 1) {
          final result = await instances[i].callRemoteMethod(SumIntAction(i, 1));
          expect(result, i + 1);
        } else {
          final result = await instances[i].callRemoteMethod(GetNameAction());
          expect(result, 'Worker');
        }
      }

      pool.stop();
    });
  });

  group('Request Tracking', () {
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

    test('Request count grows and declines', () async {
      final instance = await pool.addInstance(InstanceA());

      var r1 = instance.callRemoteMethod(ConcatAction('Hello ', 'world'));
      expect(pool.numberOfPendingRequests, 1);

      var r2 = instance.callRemoteMethod(ConcatAction('Hello ', 'world'));
      expect(pool.numberOfPendingRequests, 2);

      await Future.wait([r1, r2]);
      expect(pool.numberOfPendingRequests, 0);
    });

    test('Request tracking across multiple instances', () async {
      final instances = <PooledInstanceProxy>[];
      for (int i = 0; i < 4; i++) {
        instances.add(await pool.addInstance(InstanceA()));
      }

      // Start multiple requests
      final futures = <Future>[];
      for (var instance in instances) {
        futures.add(instance.callRemoteMethod(ConcatAction('test', 'ing')));
      }

      // Should have pending requests
      expect(pool.numberOfPendingRequests, greaterThan(0));

      await Future.wait(futures);

      // All requests should be complete
      expect(pool.numberOfPendingRequests, 0);
    });
  });
}