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
    });

    expect(status.cameraReady, isTrue);
    expect(status.previewActive, isTrue);
    expect(status.recording, isTrue);
    expect(status.recordedDuration, 3.25);
  });

  test('recorded video parses the native completion payload', () {
    final video = RecordedVideo.fromMap(const {
      'path': '/tmp/amplified.mp4',
      'durationSeconds': 12.5,
      'frameCount': 748,
    });

    expect(video.path, '/tmp/amplified.mp4');
    expect(video.durationSeconds, 12.5);
    expect(video.frameCount, 748);
  });
}
