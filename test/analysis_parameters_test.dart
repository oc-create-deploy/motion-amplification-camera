import 'package:flutter_test/flutter_test.dart';
import 'package:motion_amplification_camera/models/analysis_models.dart';

void main() {
  group('AnalysisParameters validation', () {
    test(
      'accepts a valid band',
      () => expect(
        const AnalysisParameters(lowerHz: 1, upperHz: 10).validate(60),
        isNull,
      ),
    );
    test('requires ordered positive cutoffs', () {
      expect(
        const AnalysisParameters(lowerHz: 0, upperHz: 5).validate(60),
        isNotNull,
      );
      expect(
        const AnalysisParameters(lowerHz: 5, upperHz: 5).validate(60),
        isNotNull,
      );
    });
    test('enforces 0.45 times measured FPS', () {
      expect(
        const AnalysisParameters(lowerHz: 1, upperHz: 27).validate(60),
        isNotNull,
      );
      expect(
        const AnalysisParameters(lowerHz: 1, upperHz: 26.9).validate(60),
        isNull,
      );
    });
  });

  group('recording duration guidance', () {
    test('uses at least three cycles of the slowest selected motion', () {
      final guidance = const AnalysisParameters(
        lowerHz: .02,
        upperHz: 1,
      ).durationGuidance;

      expect(guidance.minimumSeconds, 100);
      expect(guidance.recommendedSeconds, 150);
    });

    test('also provides enough time to separate a narrow band', () {
      final guidance = RecordingDurationGuidance.forBand(
        lowerHz: 4,
        upperHz: 4.2,
      );

      expect(guidance.minimumSeconds, 10);
      expect(guidance.recommendedSeconds, 20);
    });

    test('precision FFT is the default saved-video mode', () {
      expect(
        const AnalysisParameters().processingMode,
        ProcessingMode.precisionFft,
      );
      expect(
        const AnalysisParameters().toMap()['processingMode'],
        'precisionFft',
      );
    });
  });
}
