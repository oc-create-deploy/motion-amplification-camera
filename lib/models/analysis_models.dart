import 'dart:math' as math;

enum ProcessingQuality { performance, balanced, detail }

enum ColorMode { luminance, color }

enum ProcessingMode { live, precisionFft }

class RecordingDurationGuidance {
  const RecordingDurationGuidance({
    required this.minimumSeconds,
    required this.recommendedSeconds,
  });

  final int minimumSeconds;
  final int recommendedSeconds;

  factory RecordingDurationGuidance.forBand({
    required double lowerHz,
    required double upperHz,
  }) {
    if (!lowerHz.isFinite ||
        !upperHz.isFinite ||
        lowerHz <= 0 ||
        upperHz <= lowerHz) {
      return const RecordingDurationGuidance(
        minimumSeconds: 0,
        recommendedSeconds: 0,
      );
    }
    final bandwidth = upperHz - lowerHz;
    int wholeSeconds(double value) => (value - 1e-9).ceil();
    final minimum = wholeSeconds(math.max(2 / lowerHz, 2 / bandwidth));
    final recommended = wholeSeconds(math.max(3 / lowerHz, 4 / bandwidth));
    return RecordingDurationGuidance(
      minimumSeconds: minimum,
      recommendedSeconds: math.max(minimum, recommended),
    );
  }
}

enum QualityState {
  idle,
  good,
  lowLight,
  lowTexture,
  cameraMotion,
  droppedFrames,
  clipping,
  invalidBand,
}

class AnalysisParameters {
  const AnalysisParameters({
    this.lowerHz = 0.1,
    this.upperHz = 8.0,
    this.gain = 40.0,
    this.quality = ProcessingQuality.balanced,
    this.colorMode = ColorMode.luminance,
    this.processingMode = ProcessingMode.precisionFft,
  });

  final double lowerHz;
  final double upperHz;
  final double gain;
  final ProcessingQuality quality;
  final ColorMode colorMode;
  final ProcessingMode processingMode;

  RecordingDurationGuidance get durationGuidance =>
      RecordingDurationGuidance.forBand(
        lowerHz: lowerHz,
        upperHz: upperHz,
      );

  String? validate(double fps) {
    if (!fps.isFinite || fps <= 0) {
      return 'Waiting for a valid camera frame rate.';
    }
    if (!lowerHz.isFinite || lowerHz <= 0) {
      return 'Lower cutoff must be above 0 Hz.';
    }
    if (!upperHz.isFinite || upperHz <= lowerHz) {
      return 'Upper cutoff must exceed lower cutoff.';
    }
    if (upperHz >= 0.45 * fps) {
      return 'Upper cutoff must stay below 45% of measured FPS.';
    }
    if (!gain.isFinite || gain < 0 || gain > 250) {
      return 'Gain must be between 0 and 250.';
    }
    return null;
  }

  AnalysisParameters copyWith({
    double? lowerHz,
    double? upperHz,
    double? gain,
    ProcessingQuality? quality,
    ColorMode? colorMode,
    ProcessingMode? processingMode,
  }) =>
      AnalysisParameters(
        lowerHz: lowerHz ?? this.lowerHz,
        upperHz: upperHz ?? this.upperHz,
        gain: gain ?? this.gain,
        quality: quality ?? this.quality,
        colorMode: colorMode ?? this.colorMode,
        processingMode: processingMode ?? this.processingMode,
      );

  Map<String, Object> toMap() => {
        'lowerHz': lowerHz,
        'upperHz': upperHz,
        'gain': gain,
        'quality': quality.name,
        'colorMode': colorMode.name,
        'processingMode': processingMode.name,
      };
}

class Calibration {
  const Calibration({required this.pixelsPerMillimeter});
  final double pixelsPerMillimeter;
  bool get isValid => pixelsPerMillimeter.isFinite && pixelsPerMillimeter > 0;
  double pixelsToMillimeters(double pixels) {
    if (!isValid) {
      throw StateError('Calibration is not valid');
    }
    return pixels / pixelsPerMillimeter;
  }

  static Calibration fromReference({
    required double pixelLength,
    required double millimeters,
  }) {
    if (!pixelLength.isFinite ||
        !millimeters.isFinite ||
        pixelLength <= 0 ||
        millimeters <= 0) {
      throw ArgumentError('Reference lengths must be finite and positive');
    }
    return Calibration(pixelsPerMillimeter: pixelLength / millimeters);
  }
}

class Measurement {
  const Measurement({
    this.xPixels = 0,
    this.yPixels = 0,
    this.rmsPixels = 0,
    this.peakPixels = 0,
    this.dominantHz = 0,
    this.confidence = 0,
    this.state = QualityState.idle,
    this.timestampSeconds = 0,
  });
  final double xPixels,
      yPixels,
      rmsPixels,
      peakPixels,
      dominantHz,
      confidence,
      timestampSeconds;
  final QualityState state;
  double get magnitudePixels =>
      math.sqrt(xPixels * xPixels + yPixels * yPixels);
  factory Measurement.fromMap(Map<Object?, Object?> map) {
    double number(String key) => (map[key] as num?)?.toDouble() ?? 0;
    return Measurement(
      xPixels: number('x'),
      yPixels: number('y'),
      rmsPixels: number('rms'),
      peakPixels: number('peak'),
      dominantHz: number('frequency'),
      confidence: number('confidence'),
      timestampSeconds: number('timestamp'),
      state: QualityState.values.firstWhere(
        (v) => v.name == map['quality'],
        orElse: () => QualityState.idle,
      ),
    );
  }
}

class SessionResult {
  const SessionResult({
    required this.startedAt,
    required this.durationSeconds,
    required this.parameters,
    required this.measuredFps,
    required this.measurement,
    this.calibration,
  });
  final DateTime startedAt;
  final double durationSeconds, measuredFps;
  final AnalysisParameters parameters;
  final Measurement measurement;
  final Calibration? calibration;
  bool get hasCalibratedDisplacement => calibration?.isValid ?? false;
  String toCsv() {
    final calibrationValue = hasCalibratedDisplacement
        ? calibration!.pixelsPerMillimeter.toStringAsFixed(6)
        : '';
    final rmsMm = hasCalibratedDisplacement
        ? calibration!
            .pixelsToMillimeters(measurement.rmsPixels)
            .toStringAsFixed(6)
        : '';
    final peakMm = hasCalibratedDisplacement
        ? calibration!
            .pixelsToMillimeters(measurement.peakPixels)
            .toStringAsFixed(6)
        : '';
    return 'started_at,duration_s,fps,lower_hz,upper_hz,gain,dominant_hz,rms_px,peak_px,pixels_per_mm,rms_mm,peak_mm,confidence\n'
        '${startedAt.toIso8601String()},${durationSeconds.toStringAsFixed(3)},${measuredFps.toStringAsFixed(3)},${parameters.lowerHz},${parameters.upperHz},${parameters.gain},${measurement.dominantHz.toStringAsFixed(4)},${measurement.rmsPixels.toStringAsFixed(4)},${measurement.peakPixels.toStringAsFixed(4)},$calibrationValue,$rmsMm,$peakMm,${measurement.confidence.toStringAsFixed(3)}\n';
  }
}
