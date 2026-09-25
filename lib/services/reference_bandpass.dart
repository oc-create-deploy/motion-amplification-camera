import 'dart:math' as math;

/// Timestamp-aware reference matching the native temporal filter.
/// alpha(fc, dt) = 1 - exp(-2*pi*fc*dt)
/// band = LP(upper cutoff) - LP(lower cutoff).
class ReferenceBandpass {
  ReferenceBandpass(this.lowerHz, this.upperHz);
  final double lowerHz, upperHz;
  double? _fast, _slow;
  static double coefficient(double cutoffHz, double dt) =>
      1 - math.exp(-2 * math.pi * cutoffHz * dt);
  double update(double sample, double dt) {
    if (_fast == null || dt <= 0 || !dt.isFinite) {
      _fast = sample;
      _slow = sample;
      return 0;
    }
    _fast = _fast! + coefficient(upperHz, dt) * (sample - _fast!);
    _slow = _slow! + coefficient(lowerHz, dt) * (sample - _slow!);
    return _fast! - _slow!;
  }

  void reset() {
    _fast = null;
    _slow = null;
  }
}
