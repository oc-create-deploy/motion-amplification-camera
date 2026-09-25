import 'package:flutter/material.dart';

import '../models/analysis_models.dart';

class MeasurementChart extends StatelessWidget {
  const MeasurementChart({super.key, required this.values});
  final List<Measurement> values;
  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Recent displacement chart',
        child: SizedBox(
          height: 64,
          width: double.infinity,
          child: CustomPaint(
            painter:
                _ChartPainter(values, Theme.of(context).colorScheme.primary),
          ),
        ),
      );
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.values, this.color);
  final List<Measurement> values;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      grid,
    );
    if (values.length < 2) {
      return;
    }
    final peak = values
        .map((e) => e.xPixels.abs())
        .fold<double>(0.1, (a, b) => a > b ? a : b);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height / 2 - values[i].xPixels / peak * size.height * .42;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => old.values != values;
}
