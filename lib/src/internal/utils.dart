// In your code
import 'dart:async';

bool get isInTest {
  try {
    return Zone.current[#test.invoker] != null;
  } catch (_) {
    return false;
  }
}
