import 'dart:async';

import '../pooled_instance.dart';

export 'extensions.dart';
export 'external_job.dart';
export 'messages.dart';
export 'worker.dart';

// Global counter for request IDs
int requestIdCounter = 0;

// Global counter for instance IDs
int instanceIdCounter = 0;

// Global map of worker instances in isolates
Map<int, PooledInstance> workerInstances = {};

// Global map of request completers in isolate
Map<int, Completer> isolateRequestCompleters = {};
