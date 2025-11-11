/// Configuration for IsolatePool health checking.
///
/// Health checking uses [Isolate.ping()] to verify that isolates are
/// responsive and can still receive messages. This helps detect dead or
/// hung isolates before attempting to send work to them.
class IsolateHealthConfig {
  /// Whether health checking is enabled.
  ///
  /// When enabled, the pool will check isolate health before dispatching
  /// jobs and requests, and will detect dead isolates automatically.
  ///
  /// Defaults to `true`.
  final bool enabled;

  /// Timeout for ping requests to isolates.
  ///
  /// If an isolate doesn't respond to a ping within this duration,
  /// it's considered unresponsive. This should be short enough to
  /// detect problems quickly, but long enough to avoid false positives
  /// when isolates are busy.
  ///
  /// Defaults to 2 seconds.
  final Duration pingTimeout;

  /// How long to consider an isolate "fresh" before requiring a health check.
  ///
  /// If an isolate successfully completed work within this duration,
  /// it's considered healthy without requiring an explicit ping.
  /// This reduces overhead by using natural work completion as health validation.
  ///
  /// Defaults to 30 seconds.
  final Duration stalenessThreshold;

  /// Maximum consecutive health check failures before marking isolate as dead.
  ///
  /// Allows for transient failures (e.g., isolate momentarily busy)
  /// before definitively marking an isolate as dead.
  ///
  /// Defaults to 2.
  final int maxConsecutiveFailures;

  /// Whether to perform health checks before dispatching work to isolates.
  ///
  /// When `true`, all operations (jobs and instance requests) will wait for
  /// health check completion before being sent, which adds latency but
  /// prevents sending to dead isolates.
  ///
  /// When `false`, work is dispatched immediately without health checking,
  /// providing lower latency but risking timeouts if the isolate is dead.
  ///
  /// Applies to:
  /// - Job scheduling via [scheduleJob()]
  /// - Instance creation via [addInstance()]
  /// - Instance requests via [sendRequest()]
  ///
  /// Defaults to `false`
  final bool checkBeforeDispatching;

  /// Creates a health configuration with the given settings.
  const IsolateHealthConfig({
    this.enabled = true,
    this.pingTimeout = const Duration(seconds: 2),
    this.stalenessThreshold = const Duration(seconds: 30),
    this.maxConsecutiveFailures = 2,
    this.checkBeforeDispatching = false,
  });

  /// Creates a configuration with health checking disabled.
  const IsolateHealthConfig.disabled()
      : enabled = false,
        pingTimeout = Duration.zero,
        stalenessThreshold = Duration.zero,
        maxConsecutiveFailures = 0,
        checkBeforeDispatching = false;

  /// Creates a configuration with aggressive health checking.
  ///
  /// Uses shorter timeouts and lower failure thresholds for faster
  /// detection of dead isolates. Useful when rapid failure detection
  /// is more important than avoiding false positives.
  ///
  /// Includes pre-dispatch health checking for maximum protection.
  const IsolateHealthConfig.aggressive()
      : enabled = true,
        pingTimeout = const Duration(milliseconds: 500),
        stalenessThreshold = const Duration(seconds: 10),
        maxConsecutiveFailures = 1,
        checkBeforeDispatching = true;

  /// Creates a configuration with relaxed health checking.
  ///
  /// Uses longer timeouts and higher failure thresholds to avoid
  /// false positives when isolates may be under heavy load.
  ///
  /// Skips pre-dispatch health checking to prioritize low latency.
  const IsolateHealthConfig.relaxed()
      : enabled = true,
        pingTimeout = const Duration(seconds: 5),
        stalenessThreshold = const Duration(minutes: 2),
        maxConsecutiveFailures = 3,
        checkBeforeDispatching = false;

  @override
  String toString() {
    final msg = StringBuffer('IsolateHealthConfig(')
      ..writeln('enabled: $enabled, ')
      ..writeln('pingTimeout: $pingTimeout, ')
      ..writeln('stalenessThreshold: $stalenessThreshold, ')
      ..writeln('maxConsecutiveFailures: $maxConsecutiveFailures, ')
      ..writeln('checkBeforeDispatching: $checkBeforeDispatching')
      ..writeln(')');

    return msg.toString();
  }
}
