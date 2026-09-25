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
      focusLocked = false,
      exposureLocked = false,
      whiteBalanceLocked = false,
      torch = false;
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
    camera.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && analyzing) {
      _stop(showSummary: false);
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
    await camera.stop();
    if (!mounted) {
      return;
    }
    final began = startedAt;
    setState(() => analyzing = false);
    if (showSummary && began != null) {
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
        MaterialPageRoute(builder: (_) => SessionSummaryScreen(result: result)),
      );
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
          pixelLength:
              roi.width *
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
                          (d.localPosition.dx / cameraBounds.maxWidth).clamp(
                            0,
                            1,
                          ),
                          (d.localPosition.dy / cameraBounds.maxHeight).clamp(
                            0,
                            1,
                          ),
                        );
                        setState(() => roi = Rect.fromPoints(dragStart!, end));
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
                      child: CustomPaint(painter: _RoiPainter(roi, analyzing)),
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
                                  displacement(status.measurement.rmsPixels),
                                  displacementUnit,
                                ),
                              ),
                              Expanded(
                                child: _Readout(
                                  'Peak',
                                  displacement(status.measurement.peakPixels),
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
                          MeasurementChart(values: List.unmodifiable(history)),
                        ],
                      ),
                    ),
                  ),
                  if (calibration == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.straighten, color: Colors.amber, size: 18),
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
                    max: 100,
                    suffix: '×',
                    onChanged: analyzing
                        ? null
                        : (v) => setState(
                            () => parameters = parameters.copyWith(gain: v),
                          ),
                  ),
                  _SliderRow(
                    label: 'Low cutoff',
                    value: parameters.lowerHz,
                    min: .1,
                    max: 20,
                    suffix: ' Hz',
                    onChanged: analyzing
                        ? null
                        : (v) => setState(
                            () => parameters = parameters.copyWith(lowerHz: v),
                          ),
                  ),
                  _SliderRow(
                    label: 'High cutoff',
                    value: parameters.upperHz,
                    min: .5,
                    max:
                        (status.measuredFps > 4
                                ? status.measuredFps * .45 - .01
                                : 26)
                            .clamp(.5, 54),
                    suffix: ' Hz',
                    onChanged: analyzing
                        ? null
                        : (v) => setState(
                            () => parameters = parameters.copyWith(upperHz: v),
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
                              () => roi = const Rect.fromLTWH(.2, .25, .6, .4),
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
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: analyzing
                            ? Colors.orange.shade800
                            : null,
                      ),
                      onPressed: analyzing ? _stop : _start,
                      icon: Icon(analyzing ? Icons.stop : Icons.play_arrow),
                      label: Text(
                        analyzing ? 'Stop & view summary' : 'Start analysis',
                      ),
                    ),
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
          style: Theme.of(context).textTheme.labelMedium
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
  });
  final String label, suffix;
  final double value, min, max;
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
            label: '${safe.toStringAsFixed(1)}$suffix',
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 66,
          child: Text(
            '${safe.toStringAsFixed(1)}$suffix',
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
  const SessionSummaryScreen({super.key, required this.result});
  final SessionResult result;
  Future<void> _export(BuildContext context) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/motion-session-${result.startedAt.millisecondsSinceEpoch}.csv',
    );
    await file.writeAsString(result.toCsv(), flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: 'Motion Amplification session summary',
      ),
    );
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
        _SummaryRow('Measured FPS', result.measuredFps.toStringAsFixed(2)),
        _SummaryRow(
          'Band',
          '${result.parameters.lowerHz.toStringAsFixed(1)}–${result.parameters.upperHz.toStringAsFixed(1)} Hz',
        ),
        _SummaryRow('Gain', '${result.parameters.gain.toStringAsFixed(1)}×'),
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
          onPressed: () => _export(context),
          icon: const Icon(Icons.ios_share),
          label: const Text('Export CSV'),
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
