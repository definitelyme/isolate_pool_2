# Isolate Pool

A library for managing isolates in a pool for parallel processing in Dart applications.

This library provides a simple API for creating and managing a pool of isolates,
scheduling one-off jobs, and creating persistent instances in isolates.

## Features

- Create and manage a pool of isolates
- Schedule one-off jobs to be executed in the pool
- Create persistent instances in isolates for stateful processing
- Communication between main isolate and worker isolates
- Support for progress reporting from worker isolates

## Usage

### Basic Usage

The pool can accept one-time requests (pooled jobs) mimicking Flutter's `compute()` method. But instead of spawning a new isolate each time it will use one of the available active isolates from the pool. In order to do so you need to inherit `PooledJob` class, define whatever params are needed as class fields, override the `job()` method that will be executed on pooled isolate. Use `IsolatePool.scheduleJob()` and pass an instance of pooled job in order to get it transferred to another isolate, executed and result returned.

```dart
import 'package:isolate_pool/isolate_pool.dart';

void main() async {
  // Create a pool with 4 isolates
  final pool = IsolatePool(4);
  
  // Start the pool
  await pool.start();
  
  // Schedule a job
  final result = await pool.scheduleJob(MyJob());
  
  // Stop the pool when done
  pool.stop();
}

// Define a job
class MyJob extends PooledJob<String> {
  @override
  Future<String> job() async {
    // Perform work in isolate
    return 'Result from isolate';
  }
}
```

### Persistent Instances

The second way of using the APIs is to have an instance created in one of the pooled isolates and communicate with it via a proxy instance, It is kind of messaging from the main isolate to one of the isolates in a pool with multiple instances created in multiple isolates, messages and responses properly correlated and arranged via descendants of `Action`. You can wrap `PooledInstanceProxy` in a class and mimic RPC kind of communication with `PooledInstance` in external isolate.

```dart
import 'package:isolate_pool/isolate_pool.dart';

void main() async {
  final pool = IsolatePool(4);
  await pool.start();
  
  // Create a persistent instance
  final proxy = await pool.addInstance(MyInstance());
  
  // Call methods on the instance
  final result = await proxy.callRemoteMethod(MyAction('parameter'));
  
  pool.stop();
}

// Define an instance
class MyInstance extends PooledInstance {
  @override
  Future<void> init() async {
    // Initialize resources, load data, etc.
  }
  
  @override
  Future<dynamic> receiveRemoteCall(Action action) async {
    if (action is MyAction) {
      return 'Processed: ${action.parameter}';
    }
    return null;
  }
}

// Define actions
class MyAction extends Action {
  final String parameter;
  
  MyAction(this.parameter);
}
```

#### PooledInstance Architecture Overview

```dart
                                                           │
                        Main isolate                       │  Isolate in the pool
                                                           │
                        ┌─────────────────────────────┐    │
Step 1 - Instantiate    │                             │    │     Pooled instance with params
a descendant of         │  PooledInstance             │    │     is passed to isolate within
PooledInstance          │                             │    │     the pool. init() method is
                        │    - Params                 │    │     called initializing whatever
                        │                             │    │     fields necessary and creating
                        └──────────────┬──────────────┘    │     whatever objects required
                                       │                   │     (aka State)
                                   Passed to               │
                                       │                   │   ┌─────────────────────────────┐
                                       │                   │   │                             │
                        ┌──────────────┼──────────────┐    │   │  PooledInstance             │
Step 2 - Pass the       │              │              │    │   │                             │
PooledInstance to       │  IsolatePool │              │    │   │    - Params                 │
isolate pool, it        │              ▼         ┌────┼────┼───►        ▼                    │
will transfer the       │    - addInstance()──┘    │    │   │    - init()───┐             │
object (together with   │                             │    │   │               │             │
fields) to isolate and  └──────────────┬──────────────┘    │   │    - State ◄──┘             │
call init(). Returned                  │                   │   │                             │
                                    Returns                │   │    - receiveRemoteCall()    │
                                       │                   │   │              ▲              │
                                       │                   │   └──────────────┬──────────────┘
                        ┌──────────────▼──────────────┐    │                  │
Step 3 - use returned   │                             │    │                  │
PooledInstanceProxy     │  PooledInstanceProxy        │    │                  │
which can be used to    │                             │    │
pass actions to the     │    - callRemoteMethod() ◄───┼────┼──────────────────┘
instance in the pool    │                             │    │
                        └──────────────▲──────────────┘    │
                                       │                   │      Action descendants are
                                       │                   │      passed to isolates via proxy
                                       │                   │      instance in the main isolate.
                                       │                   │      Pooled instance uses switch
                        ┌──────────────┴──────────────┐    │      statement in receiveRemoteCall()
Create a set of         │                             │    │      processing requests and returning
Action descendants      │  Action                     │    │      results back to the requester
defining pooled         │                             │    │
instance capabilities,  │    - Params                 │    │
use them with           │                             │    │
callRemoteMethod()      └─────────────────────────────┘    │
                                                           │
```

## License

MIT
