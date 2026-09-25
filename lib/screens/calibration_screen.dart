import 'package:flutter/material.dart';

import '../models/analysis_models.dart';

class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key, required this.pixelLength});
  final double pixelLength;
  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  final _controller = TextEditingController();
  String? error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final mm = double.tryParse(_controller.text);
    if (mm == null || mm <= 0 || widget.pixelLength <= 0) {
      setState(
        () => error = 'Enter a positive known length. Select an ROI first.',
      );
      return;
    }
    Navigator.pop(
      context,
      Calibration.fromReference(
        pixelLength: widget.pixelLength,
        millimeters: mm,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Calibrate scale')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Place a known-length reference in the same plane as the vibrating target. Resize the ROI so its width spans the reference, edge to edge. Calibration is invalid after camera distance, zoom, orientation, format, or target-plane changes.',
            ),
            const SizedBox(height: 20),
            Text(
              'Selected reference width: ${widget.pixelLength.toStringAsFixed(1)} px',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Known length (mm)',
                errorText: error,
                suffixText: 'mm',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
                onPressed: _save, child: const Text('Save calibration')),
          ],
        ),
      );
}
