# Best Practices for Using isolate_pool_2

## Table of Contents
- [Avoiding Closure Capture Issues](#avoiding-closure-capture-issues)
- [Creating Safe PooledJob Classes](#creating-safe-pooledjob-classes)
- [Using Validation Effectively](#using-validation-effectively)
- [Common Pitfalls](#common-pitfalls)

---

## Avoiding Closure Capture Issues

### The Problem: Closures Capture More Than You Think

When you use a closure (anonymous function) in Dart, it can implicitly capture the entire context where it's defined, including `this` and all object fields. This becomes a problem when sending jobs to isolates because non-sendable objects like `StreamController`, `Completer`, or `ReceivePort` will cause runtime errors.

### ❌ BAD: Closure Captures Non-Sendable State

```dart
class NumbersRepository {
  final StreamController<int> _controller;
  final IsolatePool pool;

  NumbersRepository(this.pool) : _controller = StreamController<int>();

  // ❌ DANGEROUS: Closure captures 'this' which includes _controller
  Future<int> calculateSum(int a, int b) {
    return pool.scheduleJob(
      TwoParamsJob(a, b, (x, y) {
        // This closure captures the entire NumbersRepository object!
        // Including the _controller field which is NOT sendable
        return x + y;
      }),
    );
  }
}
```

**What happens:**
- The closure `(x, y) => x + y` captures `this` (the `NumbersRepository` instance)
- When sent to the isolate, it tries to send `_controller` (StreamController)
- Validation catches this and throws `IsolatePoolException`

### ✅ GOOD: Use Static or Top-Level Functions

```dart
class NumbersRepository {
  final StreamController<int> _controller;
  final IsolatePool pool;

  NumbersRepository(this.pool) : _controller = StreamController<int>();

  // ✅ SAFE: Static function doesn't capture 'this'
  Future<int> calculateSum(int a, int b) {
    return pool.scheduleJob(
      TwoParamsJob(a, b, _sumHandler),
    );
  }

  // Static method - no access to instance fields
  static int _sumHandler(int x, int y) {
    return x + y;
  }
}
```

**Why this works:**
- Static functions can't access instance fields
- No `this` context is captured
- Only the parameters are sent to the isolate

### Alternative: Top-Level Functions

```dart
// Define function at the top level (outside any class)
int sumNumbers(int x, int y) => x + y;

class NumbersRepository {
  final IsolatePool pool;

  NumbersRepository(this.pool);

  Future<int> calculateSum(int a, int b) {
    return pool.scheduleJob(
      TwoParamsJob(a, b, sumNumbers),
    );
  }
}
```

---

## Creating Safe PooledJob Classes

### Pattern 1: Extract Data Before Creating Job

```dart
// ❌ BAD: Passing object with non-sendable fields
class UserRepository {
  final Database _db; // Contains native resources
  final IsolatePool pool;

  Future<User> fetchUser(int userId) {
    return pool.scheduleJob(
      FetchUserJob(userId, _db), // ❌ Can't send _db to isolate!
    );
  }
}

// ✅ GOOD: Extract only the sendable data you need
class UserRepository {
  final Database _db;
  final IsolatePool pool;

  Future<User> fetchUser(int userId) async {
    // Extract the data locally
    final connectionString = _db.connectionString; // String is sendable
    final config = _db.config; // Assuming config is a Map

    return pool.scheduleJob(
      FetchUserJob(userId, connectionString, config),
    );
  }
}
```

### Pattern 2: Use Simple Data Containers

```dart
// ✅ GOOD: Job with only sendable fields
class CalculationJob extends PooledJob<double> {
  final List<double> numbers;
  final String operation;

  CalculationJob(this.numbers, this.operation);

  @override
  Future<double> job() async {
    switch (operation) {
      case 'sum':
        return numbers.reduce((a, b) => a + b);
      case 'average':
        return numbers.reduce((a, b) => a + b) / numbers.length;
      default:
        throw ArgumentError('Unknown operation: $operation');
    }
  }
}
```

**Sendable types:**
- Primitives: `null`, `bool`, `int`, `double`, `String`
- Collections: `List`, `Map`, `Set` (with sendable elements)
- Special: `SendPort`, `Capability`, `TransferableTypedData`

---

## Using Validation Effectively

### Understanding Validation Errors

When you see a validation error, it means your job contains non-sendable objects:

```dart
IsolatePoolException: Job of type TwoParamsJob contains non-sendable objects
and cannot be sent to an isolate.

Common causes:
1. Using a closure that captures non-sendable objects (StreamController, Completer, etc.)
2. Including non-sendable fields in your PooledJob subclass
3. Capturing "this" context that contains non-sendable state

Solutions:
- Use static or top-level functions instead of closures
- Ensure your PooledJob only contains sendable fields
- Extract the necessary data before creating the job
```

### Debug Process

1. **Check for closures** in your PooledJob
   - Are you using `(params) => ...`?
   - Is the closure defined inside an instance method?
   - Does it reference any instance variables?

2. **Check job fields**
   - What fields does your PooledJob subclass have?
   - Are they all primitives, Strings, Lists, or Maps?
   - Do any contain Completers, StreamControllers, etc.?

3. **Trace the capture chain**
   - If using a closure, what does it reference?
   - Does it reference `this`?
   - What fields exist on the parent object?

---

## Common Pitfalls

### Pitfall 1: Accidental Closure Capture

```dart
class ApiClient {
  final http.Client _httpClient; // Non-sendable!
  final IsolatePool pool;

  Future<String> fetchData(String url) {
    // ❌ Even if you don't use _httpClient in the closure,
    // it gets captured because the closure is defined in an instance method
    return pool.scheduleJob(
      SimpleJob(() async {
        // This captures 'this' and _httpClient
        return 'some data';
      }),
    );
  }
}

// ✅ Solution: Use static method
class ApiClient {
  final http.Client _httpClient;
  final IsolatePool pool;

  Future<String> fetchData(String url) {
    return pool.scheduleJob(
      UrlFetchJob(url),
    );
  }
}

class UrlFetchJob extends PooledJob<String> {
  final String url;
  UrlFetchJob(this.url);

  @override
  Future<String> job() async {
    // Create a new client in the isolate
    // Or use a sendable HTTP library
    return 'fetched data';
  }
}
```

### Pitfall 2: Function References That Aren't Static

```dart
class Calculator {
  int _offset = 10; // Instance variable

  Future<int> calculate(int x, int y) {
    // ❌ _add is an instance method, not static
    return pool.scheduleJob(
      TwoParamsJob(x, y, _add),
    );
  }

  int _add(int a, int b) {
    return a + b + _offset; // Uses instance variable
  }
}

// ✅ Solution: Make it static (can't use _offset)
class Calculator {
  int _offset = 10;

  Future<int> calculate(int x, int y) {
    // Pass _offset as a parameter instead
    return pool.scheduleJob(
      ThreeParamsJob(x, y, _offset, _addWithOffset),
    );
  }

  static int _addWithOffset(int a, int b, int offset) {
    return a + b + offset;
  }
}
```

### Pitfall 3: Nested Objects

```dart
// ❌ BAD: Nested object contains non-sendable fields
class Config {
  final StreamController<String> _events;
  final String apiKey;

  Config(this.apiKey) : _events = StreamController();
}

class ApiJob extends PooledJob<String> {
  final Config config; // ❌ Config contains _events!

  ApiJob(this.config);

  @override
  Future<String> job() async {
    return 'API call with ${config.apiKey}';
  }
}

// ✅ GOOD: Only pass the sendable data
class ApiJob extends PooledJob<String> {
  final String apiKey; // ✅ Only the String

  ApiJob(this.apiKey);

  @override
  Future<String> job() async {
    return 'API call with $apiKey';
  }
}
```

---

## Quick Reference

### ✅ Safe Patterns

```dart
// Static methods
static int add(int a, int b) => a + b;

// Top-level functions
int multiply(int a, int b) => a * b;

// Jobs with only sendable fields
class DataJob extends PooledJob<Result> {
  final String id;
  final Map<String, dynamic> data;
  final List<int> indices;

  // All fields are sendable!
}
```

### ❌ Unsafe Patterns

```dart
// Instance method closures
pool.scheduleJob(Job(() => _instanceMethod()));

// Closures capturing 'this'
pool.scheduleJob(Job((x) => x + _instanceField));

// Jobs with non-sendable fields
class BadJob extends PooledJob<int> {
  final StreamController controller; // ❌
  final Completer completer;         // ❌
  final Socket socket;               // ❌
}
```

---

## Testing Your Jobs

Use the validation tests to verify your jobs are safe:

```dart
import 'package:isolate_pool_2/isolate_pool_2.dart';

void main() {
  final job = MyCustomJob(/* params */);

  // Validate before using
  if (canBeSentToIsolate(job)) {
    print('✅ Job is safe to send to isolate');
  } else {
    print('❌ Job contains non-sendable objects');
  }
}
```

---

## Summary

1. **Prefer static or top-level functions** over closures
2. **Extract sendable data** before creating jobs
3. **Only use sendable types** in PooledJob fields
4. **Trust the validation errors** - they're there to help you
5. **Test your jobs** before deploying to production

When in doubt, ask yourself: "Can this data be copied and sent over a network?" If yes, it's probably sendable. If no, extract or transform it first.
