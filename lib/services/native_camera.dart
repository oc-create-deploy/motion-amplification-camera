import 'dart:async';

import 'package:flutter/services.dart';

import '../models/analysis_models.dart';

class CameraStatus {
  const CameraStatus({
    this.fps = 0,
    this.measuredFps = 0,
    this.frameWidth = 0,
    this.torchAvailable = false,
    this.cameraReady = false,
    this.previewActive = false,
    this.running = false,
    this.recording = false,
    this.recordedDuration = 0,
    this.measurement = const Measurement(),
    this.warning,
    this.recordingError,
  });
  final double fps, measuredFps;
  final double frameWidth;
  final bool torchAvailable, cameraReady, previewActive, running, recording;
  final double recordedDuration;
  final Measurement measurement;
  final String? warning, recordingError;
  factory CameraStatus.fromMap(Map<Object?, Object?> map) => CameraStatus(
        fps: (map['targetFps'] as num?)?.toDouble() ?? 0,
        measuredFps: (map['measuredFps'] as num?)?.toDouble() ?? 0,
        frameWidth: (map['frameWidth'] as num?)?.toDouble() ?? 0,
        torchAvailable: map['torchAvailable'] == true,
        cameraReady: map['cameraReady'] == true,
        previewActive: map['previewActive'] == true,
        running: map['running'] == true,
        recording: map['recording'] == true,
        recordedDuration: (map['recordedDuration'] as num?)?.toDouble() ?? 0,
        warning: map['warning'] as String?,
        recordingError: map['recordingError'] as String?,
        measurement: Measurement.fromMap(map),
      );
}

class RecordedVideo {
  const RecordedVideo({
    required this.path,
    required this.durationSeconds,
    required this.frameCount,
  });

  final String path;
  final double durationSeconds;
  final int frameCount;

  factory RecordedVideo.fromMap(Map<Object?, Object?> map) => RecordedVideo(
        path: map['path'] as String? ?? '',
        durationSeconds: (map['durationSeconds'] as num?)?.toDouble() ?? 0,
        frameCount: (map['frameCount'] as num?)?.toInt() ?? 0,
      );
}

class NativeCameraController {
  static const _methods = MethodChannel('motion_amplification/camera');
  static const _events = EventChannel('motion_amplification/measurements');
  Stream<CameraStatus>? _stream;
  Stream<CameraStatus> get statuses => _stream ??= _events
      .receiveBroadcastStream()
      .map((event) => CameraStatus.fromMap(event as Map<Object?, Object?>));
  Future<void> configure(AnalysisParameters p) =>
      _methods.invokeMethod('configure', p.toMap());
  Future<void> start() => _methods.invokeMethod('start');
  Future<RecordedVideo> stop() async {
    final value = await _methods.invokeMapMethod<Object?, Object?>('stop');
    if (value == null) {
      throw PlatformException(
        code: 'recording',
        message: 'The amplified video was not finalized.',
      );
    }
    return RecordedVideo.fromMap(value);
  }

  Future<void> cancel() => _methods.invokeMethod('cancel');
  Future<void> setLock(String kind, bool locked) =>
      _methods.invokeMethod('setLock', {'kind': kind, 'locked': locked});
  Future<void> setTorch(bool enabled) =>
      _methods.invokeMethod('setTorch', {'enabled': enabled});
  Future<void> setRoi(double left, double top, double width, double height) =>
      _methods.invokeMethod('setROI', {
        'left': left,
        'top': top,
        'width': width,
        'height': height,
      });
  Future<void> resetRoi() => _methods.invokeMethod('resetROI');
  Future<String?> snapshot() => _methods.invokeMethod<String>('snapshot');
  Future<String?> saveVideoToPhotos(String path) =>
      _methods.invokeMethod<String>('saveVideoToPhotos', {'path': path});
}
