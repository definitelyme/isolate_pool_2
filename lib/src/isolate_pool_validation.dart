import 'dart:async';
import 'dart:developer' show UserTag;
import 'dart:ffi' show DynamicLibrary;
import 'dart:isolate';

import 'isolate_pool.dart';
import 'pooled_instance.dart';

/// Validates that an object can be sent across isolates.
///
/// This is a helper function to check if an object contains any
/// non-sendable types before attempting to send it to an isolate.
bool canBeSentToIsolate(dynamic object) {
  // Check for directly sendable types according to Dart's documentation
  if (object == null ||
      object is num ||
      object is int ||
      object is double ||
      object is String ||
      object is bool ||
      object is SendPort ||
      object is TransferableTypedData ||
      object is Capability ||
      object is Type) {
    return true;
  }

  // Check for types that are definitely not sendable according to Dart's documentation
  if (object is ReceivePort ||
      object is DynamicLibrary ||
      object is UserTag ||
      object is RawReceivePort ||
      object is Stream ||
      object is StreamController ||
      object is StreamSubscription ||
      object is Completer ||
      object.runtimeType.toString().contains('Completer') ||
      object.runtimeType.toString().contains('Finalizable') ||
      object.runtimeType.toString().contains('Finalizer') ||
      object.runtimeType.toString().contains('NativeFinalizer') ||
      object is IsolatePool ||
      object is PooledInstanceProxy) {
    return false;
  }

  // For collections, recursively check elements
  if (object is List) {
    return object.every(canBeSentToIsolate);
  }

  if (object is Map) {
    return object.entries.every((e) => canBeSentToIsolate(e.key) && canBeSentToIsolate(e.value));
  }

  if (object is Set) {
    return object.every(canBeSentToIsolate);
  }

  if (object is PooledInstance) {
    final objectString = object.toString() + object.runtimeType.toString();
    if (objectString.contains('PooledInstanceProxy') ||
        objectString.contains('IsolatePool') ||
        objectString.contains('Completer') ||
        objectString.contains('Stream') ||
        objectString.contains('Socket') ||
        objectString.contains('NativeFieldWrapperClass1')) {
      return false;
    }
  }

  // For shared isolates (created via Isolate.spawn), most other objects are sendable
  // except those with native resources or explicitly marked as unsendable
  return true;
}

extension PooledInstanceValidation on PooledInstance {
  /// Validates that this instance can be sent to an isolate.
  ///
  /// Returns a list of validation errors, or an empty list if valid.
  List<String> validateForIsolate() {
    final errors = <String>[];

    // Check if the instance contains non-sendable objects
    if (!canBeSentToIsolate(this)) {
      errors.add('Instance contains non-sendable objects.\n'
          'Only the following types can be sent:\n'
          '- null\n'
          '- bool\n'
          '- int\n'
          '- double\n'
          '- String\n'
          '- List, Map, or Set (whose elements are sendable types)\n'
          '- TransferableTypedData\n'
          '- SendPort\n'
          '- Capability\n'
          '- Type representing one of these types, Object, dynamic, void, or Never\n\n'
          'The following types are NEVER sendable:\n'
          '- Objects with native resources (e.g., Socket)\n'
          '- ReceivePort\n'
          '- DynamicLibrary\n'
          '- Finalizable, Finalizer, NativeFinalizer\n'
          '- UserTag\n'
          '- Stream, StreamController, StreamSubscription\n'
          '- Completer\n'
          '- PooledInstanceProxy\n'
          '- IsolatePool\n'
          '- Function references from main isolate\n\n'
          'For more details, see: https://api.flutter.dev/flutter/dart-isolate/SendPort/send.html');
    }

    return errors;
  }
}
