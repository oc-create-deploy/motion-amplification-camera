import 'package:flutter_test/flutter_test.dart';
import 'package:motion_amplification_camera/models/analysis_models.dart';

void main() {
  test('uncalibrated CSV leaves millimeter columns empty', () {
    final result = SessionResult(
      startedAt: DateTime.utc(2026),
      durationSeconds: 10,
      parameters: const AnalysisParameters(),
      measuredFps: 59.9,
      measurement: const Measurement(rmsPixels: 2, peakPixels: 4),
    );
    expect(result.hasCalibratedDisplacement, isFalse);
    expect(result.toCsv().split('\n')[1], contains('2.0000,4.0000,,,,'));
  });
  test('calibrated CSV includes millimeter values', () {
    final result = SessionResult(
      startedAt: DateTime.utc(2026),
      durationSeconds: 10,
      parameters: const AnalysisParameters(),
      measuredFps: 60,
      measurement: const Measurement(rmsPixels: 10, peakPixels: 20),
      calibration: const Calibration(pixelsPerMillimeter: 10),
    );
    expect(result.toCsv(), contains('1.000000,2.000000'));
  });
}
