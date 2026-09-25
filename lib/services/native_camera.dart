import 'dart:async';

import 'package:flutter/services.dart';

import '../models/analysis_models.dart';

class CameraStatus {
  const CameraStatus({
    this.fps = 0,
    this.measuredFps = 0,
    this.frameWidth = 0,
    this.torchAvailable = false,
    this.running = false,
    this.measurement = const Measurement(),
    this.warning,
  });
  final double fps, measuredFps;
  final double frameWidth;
  final bool torchAvailable, running;
  final Measurement measurement;
  final String? warning;
  factory CameraStatus.fromMap(Map<Object?, Object?> map) => CameraStatus(
    fps: (map['targetFps'] as num?)?.toDouble() ?? 0,
    measuredFps: (map['measuredFps'] as num?)?.toDouble() ?? 0,
    frameWidth: (map['frameWidth'] as num?)?.toDouble() ?? 0,
    torchAvailable: map['torchAvailable'] == true,
    running: map['running'] == true,
    warning: map['warning'] as String?,
    measurement: Measurement.fromMap(map),
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
  Future<void> stop() => _methods.invokeMethod('stop');
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
}
