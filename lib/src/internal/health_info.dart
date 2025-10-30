part of '../isolate_pool.dart';

class IsolateHealthInfo {
  IsolateHealthInfo._({
    required this.isolateIndex,
    DateTime? lastKnownGood,
    bool? confirmedDead,
    int? consecutiveFailures,
  })  : _lastKnownGood = lastKnownGood ?? DateTime.now(),
        _confirmedDead = confirmedDead ?? false,
        _consecutiveFailures = consecutiveFailures ?? 0;

  /// The isolate index.
  final int isolateIndex;

  bool _confirmedDead;
  int _consecutiveFailures;
  DateTime _lastKnownGood;

  @override
  String toString() => 'IsolateHealthInfo('
      'index: $isolateIndex, '
      'lastKnownGood: $_lastKnownGood, '
      'confirmedDead: $_confirmedDead, '
      'consecutiveFailures: $_consecutiveFailures'
      ')';

  /// Whether this isolate has been confirmed as dead after failed health checks.
  bool get confirmedDead => _confirmedDead;

  /// Number of consecutive health check failures.
  int get consecutiveFailures => _consecutiveFailures;

  /// Whether this isolate is considered healthy.
  bool get isHealthy => !_confirmedDead;

  /// Last time this isolate successfully responded (job completion or ping).
  DateTime get lastKnownGood => _lastKnownGood;
}
