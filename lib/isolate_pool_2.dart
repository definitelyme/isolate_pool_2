/// A library for managing isolates in a pool for parallel processing in Dart applications.
///
/// This library provides a simple API for creating and managing a pool of isolates,
/// scheduling one-off jobs, and creating persistent instances in isolates.
///
/// # Architecture Overview
///
/// ```
///                                                            │
///                         Main isolate                       │  Isolate in the pool
///                                                            │
///                         ┌─────────────────────────────┐    │
/// Step 1 - Instantiate    │                             │    │     Pooled instance with params
/// a descendant of         │  PooledInstance             │    │     is passed to isolate within
/// PooledInstance          │                             │    │     the pool. init() method is
///                         │    - Params                 │    │     called initializing whatever
///                         │                             │    │     fields necessary and creating
///                         └──────────────┬──────────────┘    │     whatever objects required
///                                        │                   │     (aka State)
///                                    Passed to               │
///                                        │                   │   ┌─────────────────────────────┐
///                                        │                   │   │                             │
///                         ┌──────────────┼──────────────┐    │   │  PooledInstance             │
/// Step 2 - Pass the       │              │              │    │   │                             │
/// PooledInstance to       │  IsolatePool │              │    │   │    - Params                 │
/// isolate pool, it        │              ▼         ┌────┼────┼───►        ▼                    │
/// will transfer the       │    - addInstance()──┘    │    │   │    - init()───┐             │
/// object (together with   │                             │    │   │               │             │
/// fields) to isolate and  └──────────────┬──────────────┘    │   │    - State ◄──┘             │
/// call init(). Returned                  │                   │   │                             │
///                                     Returns                │   │    - receiveRemoteCall()    │
///                                        │                   │   │              ▲              │
///                                        │                   │   └──────────────┬──────────────┘
///                         ┌──────────────▼──────────────┐    │                  │
/// Step 3 - use returned   │                             │    │                  │
/// PooledInstanceProxy     │  PooledInstanceProxy        │    │                  │
/// which can be used to    │                             │    │
/// pass actions to the     │    - callRemoteMethod() ◄───┼────┼──────────────────┘
/// instance in the pool    │                             │    │
///                         └──────────────▲──────────────┘    │
///                                        │                   │      Action descendants are
///                                        │                   │      passed to isolates via proxy
///                                        │                   │      instance in the main isolate.
///                                        │                   │      Pooled instance uses switch
///                         ┌──────────────┴──────────────┐    │      statement in receiveRemoteCall()
/// Create a set of         │                             │    │      processing requests and returning
/// Action descendants      │  Action                     │    │      results back to the requester
/// defining pooled         │                             │    │
/// instance capabilities,  │    - Params                 │    │
/// use them with           │                             │    │
/// callRemoteMethod()      └─────────────────────────────┘    │
///                                                            │
/// ```
library;

export 'src/callback_isolate.dart';
export 'src/enums.dart';
export 'src/exceptions.dart';
export 'src/isolate_pool.dart';
export 'src/isolate_pool_validation.dart';
export 'src/pooled_instance.dart';
export 'src/pooled_job.dart';
