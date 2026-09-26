import 'dart:async';
import 'dart:io';
import 'dart:ui' show FontFeature, PointMode;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/analysis_models.dart';
import '../services/calibration_store.dart';
import '../services/native_camera.dart';
import '../widgets/measurement_chart.dart';
import 'about_screen.dart';
import 'calibration_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final camera = NativeCameraController();
  final store = CalibrationStore();
  StreamSubscription<CameraStatus>? subscription;
  AnalysisParameters parameters = const AnalysisParameters();
  CameraStatus status = const CameraStatus();
  Calibration? calibration;
  bool analyzing = false,
      finalizing = false,
      focusLocked = false,
      exposureLocked = false,
      whiteBalanceLocked = false,
      torch = false;
  double exposureBias = 0;
  Rect roi = const Rect.fromLTWH(.2, .25, .6, .4);
  Offset? dragStart;
  DateTime? startedAt;
  final history = <Measurement>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.load().then((v) {
      if (mounted) {
        setState(() => calibration = v);
      }
    });
    subscription = camera.statuses.listen(
      _status,
      onError: (_) {
        if (mounted) {
          setState(
            () => status = const CameraStatus(
              warning: 'Camera engine unavailable. Check camera permission.',
            ),
          );
        }
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    subscription?.cancel();
    camera.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && analyzing) {
      camera.cancel();
      setState(() {
        analyzing = false;
        finalizing = false;
      });
    }
  }

  void _status(CameraStatus next) {
    if (!mounted) {
      return;
    }
    if (next.warning?.startsWith('Orientation changed') == true ||
        next.warning?.startsWith('Capture format changed') == true) {
      store.clear();
      calibration = null;
    }
    setState(() {
      status = next;
      exposureBias = next.exposureBias;
      if (analyzing) {
        history.add(next.measurement);
        if (history.length > 120) {
          history.removeAt(0);
        }
      }
    });
  }

  Future<void> _start() async {
    final error = parameters.validate(
      status.measuredFps > 0 ? status.measuredFps : 60,
    );
    if (error != null) {
      _message(error);
      return;
    }
    try {
      await camera.configure(parameters);
      await camera.start();
      setState(() {
        analyzing = true;
        startedAt = DateTime.now();
        history.clear();
      });
    } on PlatformException catch (e) {
      _message(e.message ?? 'Could not start analysis.');
    }
  }

  Future<void> _stop({bool showSummary = true}) async {
    final began = startedAt;
    setState(() => finalizing = true);
    try {
      final video = await camera.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        analyzing = false;
        finalizing = false;
      });
      if (!showSummary || began == null) {
        return;
      }
      final result = SessionResult(
        startedAt: began,
        durationSeconds: DateTime.now().difference(began).inMilliseconds / 1000,
        parameters: parameters,
        measuredFps: status.measuredFps,
        measurement: status.measurement,
        calibration: calibration,
      );
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SessionSummaryScreen(
            result: result,
            video: video,
            camera: camera,
          ),
        ),
      );
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        analyzing = false;
        finalizing = false;
      });
      _message(error.message ?? 'Could not finalize the amplified video.');
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> _lock(String kind, bool value) async {
    await camera.setLock(kind, value);
    setState(() {
      if (kind == 'focus') {
        focusLocked = value;
      }
      if (kind == 'exposure') {
        exposureLocked = value;
      }
      if (kind == 'whiteBalance') {
        whiteBalanceLocked = value;
      }
    });
  }

  Future<void> _setExposureBias(double value) async {
    setState(() => exposureBias = value);
    try {
      await camera.setExposureBias(value);
    } on PlatformException catch (error) {
      _message(error.message ?? 'Could not adjust exposure.');
    }
  }

  Widget _analysisButton() => SizedBox(
        width: double.infinity,
        height: 54,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: analyzing ? Colors.orange.shade800 : null,
          ),
          onPressed: finalizing
              ? null
              : analyzing
                  ? _stop
                  : _start,
          icon: finalizing
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(analyzing ? Icons.stop : Icons.play_arrow),
          label: Text(
            finalizing && status.postProcessing
                ? 'Precision FFT ${((status.processingProgress) * 100).clamp(0, 100).toStringAsFixed(0)}%'
                : finalizing
                    ? 'Finalizing amplified video…'
                : analyzing
                    ? 'Stop & save results'
                    : 'Start analysis',
          ),
        ),
      );

  Color get qualityColor => status.measurement.state == QualityState.good
      ? Colors.greenAccent
      : status.measurement.state == QualityState.idle
          ? Colors.white54
          : Colors.amber;
  String get displacementUnit => calibration?.isValid == true ? 'mm' : 'px';
  double displacement(double px) =>
      calibration?.isValid == true ? calibration!.pixelsToMillimeters(px) : px;
  Future<void> _calibrate(Size viewSize) async {
    final result = await Navigator.push<Calibration>(
      context,
      MaterialPageRoute(
        builder: (_) => CalibrationScreen(
          pixelLength: roi.width *
              (status.frameWidth > 0 ? status.frameWidth : viewSize.width),
        ),
      ),
    );
    if (result != null) {
      await store.save(result);
      if (mounted) {
        setState(() => calibration = result);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Motion Amplification'),
          actions: [
            IconButton(
              tooltip: 'About and limitations',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutScreen()),
              ),
              icon: const Icon(Icons.info_outline),
            ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, bounds) => ListView(
              children: [
                AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(
                        color: Colors.black,
                        child: UiKitView(
                          viewType: 'motion_amplification/camera_view',
                          creationParamsCodec: StandardMessageCodec(),
                        ),
                      ),
                      if (!status.previewActive)
                        const ColoredBox(
                          color: Colors.black,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(height: 12),
                                Text('Starting live camera preview…'),
                              ],
                            ),
                          ),
                        ),
                      LayoutBuilder(
                        builder: (context, cameraBounds) => GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onPanStart: (d) => dragStart = Offset(
                            d.localPosition.dx / cameraBounds.maxWidth,
                            d.localPosition.dy / cameraBounds.maxHeight,
                          ),
                          onPanUpdate: (d) {
                            if (dragStart == null) {
                              return;
                            }
                            final end = Offset(
                              (d.localPosition.dx / cameraBounds.maxWidth)
                                  .clamp(
                                0,
                                1,
                              ),
                              (d.localPosition.dy / cameraBounds.maxHeight)
                                  .clamp(
                                0,
                                1,
                              ),
                            );
                            setState(
                                () => roi = Rect.fromPoints(dragStart!, end));
                          },
                          onPanEnd: (_) {
                            dragStart = null;
                            if (roi.width > .03 && roi.height > .03) {
                              camera.setRoi(
                                roi.left,
                                roi.top,
                                roi.width,
                                roi.height,
                              );
                            }
                          },
                          child:
                              CustomPaint(painter: _RoiPainter(roi, analyzing)),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        left: 8,
                        child: _StatusChip(
                          label: '${status.measuredFps.toStringAsFixed(1)} FPS',
                          color: status.measuredFps > 0
                              ? Colors.cyan
                              : Colors.amber,
                        ),
                      ),
                      if (analyzing)
                        Positioned(
                          top: 44,
                          left: 8,
                          child: _StatusChip(
                            label:
                                '● REC ${status.recordedDuration.toStringAsFixed(1)} s',
                            color: status.recording
                                ? Colors.redAccent
                                : Colors.amber,
                          ),
                        ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _StatusChip(
                          label: status.measurement.state.name,
                          color: qualityColor,
                        ),
                      ),
                      if (status.warning != null)
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: Material(
                            color: Colors.amber.shade900.withValues(alpha: .92),
                            borderRadius: BorderRadius.circular(6),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                status.warning!,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: _analysisButton(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  child: Column(
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: _Readout(
                                      'X',
                                      displacement(status.measurement.xPixels),
                                      displacementUnit,
                                    ),
                                  ),
                                  Expanded(
                                    child: _Readout(
                                      'Y',
                                      displacement(status.measurement.yPixels),
                                      displacementUnit,
                                    ),
                                  ),
                                  Expanded(
                                    child: _Readout(
                                      'Dominant',
                                      status.measurement.dominantHz,
                                      'Hz',
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(),
                              Row(
                                children: [
                                  Expanded(
                                    child: _Readout(
                                      'RMS',
                                      displacement(
                                          status.measurement.rmsPixels),
                                      displacementUnit,
                                    ),
                                  ),
                                  Expanded(
                                    child: _Readout(
                                      'Peak',
                                      displacement(
                                          status.measurement.peakPixels),
                                      displacementUnit,
                                    ),
                                  ),
                                  Expanded(
                                    child: _Readout(
                                      'Confidence',
                                      status.measurement.confidence * 100,
                                      '%',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              MeasurementChart(
                                  values: List.unmodifiable(history)),
                            ],
                          ),
                        ),
                      ),
                      if (calibration == null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              Icon(Icons.straighten,
                                  color: Colors.amber, size: 18),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Uncalibrated — displacement is shown only in pixels.',
                                ),
                              ),
                            ],
                          ),
                        ),
                      _SliderRow(
                        label: 'Gain',
                        value: parameters.gain,
                        min: 0,
                        max: 250,
                        suffix: '×',
                        onChanged: analyzing
                            ? null
                            : (v) => setState(
                                  () =>
                                      parameters = parameters.copyWith(gain: v),
                                ),
                      ),
                      _SliderRow(
                        label: 'Low cutoff',
                        value: parameters.lowerHz,
                        min: .02,
                        max: 20,
                        suffix: ' Hz',
                        decimals: 2,
                        onChanged: analyzing
                            ? null
                            : (v) => setState(
                                  () => parameters =
                                      parameters.copyWith(lowerHz: v),
                                ),
                      ),
                      _SliderRow(
                        label: 'High cutoff',
                        value: parameters.upperHz,
                        min: .5,
                        max: (status.measuredFps > 4
                                ? status.measuredFps * .45 - .01
                                : 26)
                            .clamp(.5, 54)
                            .toDouble(),
                        suffix: ' Hz',
                        onChanged: analyzing
                            ? null
                            : (v) => setState(
                                  () => parameters =
                                      parameters.copyWith(upperHz: v),
                                ),
                      ),
                      Card(
                        margin: const EdgeInsets.only(top: 6, bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.timer_outlined, size: 19),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      parameters.processingMode ==
                                              ProcessingMode.precisionFft
                                          ? 'Precision FFT recording length'
                                          : 'Recording length guidance',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Record at least ${parameters.durationGuidance.minimumSeconds} s; '
                                'for reliable separation near ${parameters.lowerHz.toStringAsFixed(2)} Hz, '
                                'aim for ${parameters.durationGuidance.recommendedSeconds} s or longer.',
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'This captures at least 2–3 cycles of the slowest selected motion. '
                                'A 0.02 Hz cycle lasts 50 seconds.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: Colors.white60),
                              ),
                              if (analyzing) ...[
                                const SizedBox(height: 10),
                                LinearProgressIndicator(
                                  value: (status.recordedDuration /
                                          parameters.durationGuidance
                                              .recommendedSeconds)
                                      .clamp(0, 1),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  status.recordedDuration >=
                                          parameters.durationGuidance
                                              .recommendedSeconds
                                      ? 'Recommended duration reached.'
                                      : '${(parameters.durationGuidance.recommendedSeconds - status.recordedDuration).ceil()} s until recommended duration.',
                                  style: Theme.of(context).textTheme.labelMedium,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      DropdownButtonFormField<ProcessingMode>(
                        initialValue: parameters.processingMode,
                        decoration: const InputDecoration(
                          labelText: 'Saved-video processing',
                          helperText:
                              'Precision FFT filters the completed recording before export.',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: ProcessingMode.precisionFft,
                            child: Text('Precision FFT (post-process)'),
                          ),
                          DropdownMenuItem(
                            value: ProcessingMode.live,
                            child: Text('Live temporal filter'),
                          ),
                        ],
                        onChanged: analyzing
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(
                                    () => parameters = parameters.copyWith(
                                      processingMode: value,
                                    ),
                                  );
                                }
                              },
                      ),
                      const SizedBox(height: 12),
                      Card(
                        margin: const EdgeInsets.only(top: 4, bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.exposure, size: 19),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'Exposure compensation',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${exposureBias >= 0 ? '+' : ''}${exposureBias.toStringAsFixed(1)} EV',
                                  ),
                                ],
                              ),
                              Slider(
                                value: exposureBias
                                    .clamp(
                                      status.minExposureBias,
                                      status.maxExposureBias <=
                                              status.minExposureBias
                                          ? status.minExposureBias + .1
                                          : status.maxExposureBias,
                                    )
                                    .toDouble(),
                                min: status.minExposureBias,
                                max: status.maxExposureBias <=
                                        status.minExposureBias
                                    ? status.minExposureBias + .1
                                    : status.maxExposureBias,
                                divisions: 24,
                                label:
                                    '${exposureBias >= 0 ? '+' : ''}${exposureBias.toStringAsFixed(1)} EV',
                                onChanged: _setExposureBias,
                              ),
                              Text(
                                'ISO ${status.iso.toStringAsFixed(0)} · ${status.exposureDuration > 0 ? '1/${(1 / status.exposureDuration).round()} s' : 'Auto shutter'}',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelMedium
                                    ?.copyWith(color: Colors.white60),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<ProcessingQuality>(
                              initialValue: parameters.quality,
                              decoration: const InputDecoration(
                                labelText: 'Processing quality',
                              ),
                              items: ProcessingQuality.values
                                  .map(
                                    (v) => DropdownMenuItem(
                                      value: v,
                                      child: Text(v.name),
                                    ),
                                  )
                                  .toList(),
                              onChanged: analyzing
                                  ? null
                                  : (v) => setState(
                                        () => parameters = parameters.copyWith(
                                          quality: v,
                                        ),
                                      ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SegmentedButton<ColorMode>(
                              segments: const [
                                ButtonSegment(
                                  value: ColorMode.luminance,
                                  label: Text('Luma'),
                                ),
                                ButtonSegment(
                                  value: ColorMode.color,
                                  label: Text('Color'),
                                ),
                              ],
                              selected: {parameters.colorMode},
                              onSelectionChanged: analyzing
                                  ? null
                                  : (v) => setState(
                                        () => parameters = parameters.copyWith(
                                          colorMode: v.first,
                                        ),
                                      ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        alignment: WrapAlignment.center,
                        children: [
                          FilterChip(
                            label: const Text('Focus lock'),
                            selected: focusLocked,
                            onSelected: (v) => _lock('focus', v),
                          ),
                          FilterChip(
                            label: const Text('Exposure lock'),
                            selected: exposureLocked,
                            onSelected: (v) => _lock('exposure', v),
                          ),
                          FilterChip(
                            label: const Text('WB lock'),
                            selected: whiteBalanceLocked,
                            onSelected: (v) => _lock('whiteBalance', v),
                          ),
                          FilterChip(
                            label: const Text('Torch'),
                            selected: torch,
                            onSelected: status.torchAvailable
                                ? (v) async {
                                    await camera.setTorch(v);
                                    setState(() => torch = v);
                                  }
                                : null,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                setState(
                                  () => roi =
                                      const Rect.fromLTWH(.2, .25, .6, .4),
                                );
                                camera.resetRoi();
                              },
                              icon: const Icon(Icons.center_focus_weak),
                              label: const Text('Reset ROI'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _calibrate(
                                Size(bounds.maxWidth, bounds.maxWidth * .75),
                              ),
                              icon: const Icon(Icons.straighten),
                              label: const Text('Calibrate'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            tooltip: 'Save processed snapshot',
                            onPressed: () async {
                              final result = await camera.snapshot();
                              if (mounted) {
                                _message(
                                  result == null
                                      ? 'Snapshot unavailable.'
                                      : 'Snapshot saved to Photos.',
                                );
                              }
                            },
                            icon: const Icon(Icons.camera_alt_outlined),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black87,
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
}

class _Readout extends StatelessWidget {
  const _Readout(this.label, this.value, this.unit);
  final String label, unit;
  final double value;
  @override
  Widget build(BuildContext context) => Semantics(
        label: '$label ${value.toStringAsFixed(2)} $unit',
        child: Column(
          children: [
            Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: Colors.white60),
            ),
            FittedBox(
              child: Text(
                value.toStringAsFixed(2),
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Text(unit, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
    this.decimals = 1,
  });
  final String label, suffix;
  final double value, min, max;
  final int decimals;
  final ValueChanged<double>? onChanged;
  @override
  Widget build(BuildContext context) {
    final safe = value.clamp(min, max);
    return Row(
      children: [
        SizedBox(width: 86, child: Text(label)),
        Expanded(
          child: Slider(
            value: safe,
            min: min,
            max: max <= min ? min + .1 : max,
            label: '${safe.toStringAsFixed(decimals)}$suffix',
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 66,
          child: Text(
            '${safe.toStringAsFixed(decimals)}$suffix',
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

class _RoiPainter extends CustomPainter {
  _RoiPainter(this.roi, this.active);
  final Rect roi;
  final bool active;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      roi.left * size.width,
      roi.top * size.height,
      roi.width * size.width,
      roi.height * size.height,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = active ? Colors.cyanAccent : Colors.amber
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final corner = Paint()
      ..color = active ? Colors.cyanAccent : Colors.amber
      ..strokeWidth = 5;
    for (final p in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawPoints(PointMode.points, [p], corner);
    }
  }

  @override
  bool shouldRepaint(covariant _RoiPainter old) =>
      old.roi != roi || old.active != active;
}

class SessionSummaryScreen extends StatelessWidget {
  const SessionSummaryScreen({
    super.key,
    required this.result,
    required this.video,
    required this.camera,
  });
  final SessionResult result;
  final RecordedVideo video;
  final NativeCameraController camera;

  Future<File> _csvFile() async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/motion-session-${result.startedAt.millisecondsSinceEpoch}.csv',
    );
    await file.writeAsString(result.toCsv(), flush: true);
    return file;
  }

  Future<void> _exportCsv(BuildContext context) async {
    final file = await _csvFile();
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: 'Motion Amplification session summary',
      ),
    );
  }

  Future<void> _shareResults(BuildContext context) async {
    final csv = await _csvFile();
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(video.path), XFile(csv.path)],
        subject: 'Motion Amplification amplified video and session data',
        text:
            'Amplified inspection video with CSV measurements. Inspection aid only; not safety-certified or metrology-grade.',
      ),
    );
  }

  Future<void> _saveVideo(BuildContext context) async {
    try {
      await camera.saveVideoToPhotos(video.path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Amplified video saved to Photos.')),
        );
      }
    } on PlatformException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? 'Could not save video.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Session summary')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _SummaryRow(
              'Duration',
              '${result.durationSeconds.toStringAsFixed(1)} s',
            ),
            _SummaryRow(
              'Amplified video',
              '${video.durationSeconds.toStringAsFixed(1)} s · ${video.frameCount} frames · ProRes 4444 MOV',
            ),
            _SummaryRow('Measured FPS', result.measuredFps.toStringAsFixed(2)),
            _SummaryRow(
              'Band',
              '${result.parameters.lowerHz.toStringAsFixed(2)}–${result.parameters.upperHz.toStringAsFixed(2)} Hz',
            ),
            _SummaryRow(
              'Processing',
              result.parameters.processingMode == ProcessingMode.precisionFft
                  ? 'Precision FFT post-processing'
                  : 'Live temporal filter',
            ),
            _SummaryRow(
                'Gain', '${result.parameters.gain.toStringAsFixed(1)}×'),
            _SummaryRow(
              'Dominant frequency',
              '${result.measurement.dominantHz.toStringAsFixed(2)} Hz',
            ),
            _SummaryRow(
              'RMS displacement',
              result.hasCalibratedDisplacement
                  ? '${result.calibration!.pixelsToMillimeters(result.measurement.rmsPixels).toStringAsFixed(3)} mm'
                  : '${result.measurement.rmsPixels.toStringAsFixed(3)} px (uncalibrated)',
            ),
            _SummaryRow(
              'Peak displacement',
              result.hasCalibratedDisplacement
                  ? '${result.calibration!.pixelsToMillimeters(result.measurement.peakPixels).toStringAsFixed(3)} mm'
                  : '${result.measurement.peakPixels.toStringAsFixed(3)} px (uncalibrated)',
            ),
            _SummaryRow(
              'Quality',
              '${result.measurement.state.name}, ${(result.measurement.confidence * 100).toStringAsFixed(0)}% confidence',
            ),
            const SizedBox(height: 16),
            const Text(
              'Results are an inspection aid and are not safety-certified or metrology-grade.',
              style: TextStyle(color: Colors.amber),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => _saveVideo(context),
              icon: const Icon(Icons.video_library_outlined),
              label: const Text('Save amplified video to Photos'),
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () => _shareResults(context),
              icon: const Icon(Icons.ios_share),
              label: const Text('Share video + CSV'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _exportCsv(context),
              icon: const Icon(Icons.table_view_outlined),
              label: const Text('Export CSV only'),
            ),
          ],
        ),
      );
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(color: Colors.white60)),
            ),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
}
