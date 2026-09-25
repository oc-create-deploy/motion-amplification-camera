import 'package:flutter_test/flutter_test.dart';
import 'package:motion_amplification_camera/services/native_camera.dart';

void main() {
  test('camera status exposes preview and recording progress', () {
    final status = CameraStatus.fromMap(const {
      'targetFps': 60,
      'measuredFps': 59.8,
      'frameWidth': 1080,
      'cameraReady': true,
      'previewActive': true,
      'recording': true,
      'recordedDuration': 3.25,
      'exposureBias': 0.7,
      'minExposureBias': -2,
      'maxExposureBias': 2,
      'iso': 80,
      'exposureDuration': 0.005,
    });

    expect(status.cameraReady, isTrue);
    expect(status.previewActive, isTrue);
    expect(status.recording, isTrue);
    expect(status.recordedDuration, 3.25);
    expect(status.exposureBias, 0.7);
    expect(status.minExposureBias, -2);
    expect(status.maxExposureBias, 2);
    expect(status.iso, 80);
    expect(status.exposureDuration, 0.005);
  });

  test('recorded video parses the native completion payload', () {
    final video = RecordedVideo.fromMap(const {
      'path': '/tmp/amplified.mov',
      'durationSeconds': 12.5,
      'frameCount': 748,
    });

    expect(video.path, '/tmp/amplified.mov');
    expect(video.durationSeconds, 12.5);
    expect(video.frameCount, 748);
  });
}
