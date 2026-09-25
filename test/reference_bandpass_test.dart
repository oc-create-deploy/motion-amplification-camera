import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:motion_amplification_camera/services/reference_bandpass.dart';

void main() {
  test(
    'coefficient is timestamp-derived',
    () =>
        expect(ReferenceBandpass.coefficient(8, 1 / 60), closeTo(0.566, .002)),
  );
  test('passes an in-band sine more strongly than out-of-band sine', () {
    double response(double frequency) {
      final filter = ReferenceBandpass(2, 10);
      final output = <double>[];
      for (var i = 0; i < 600; i++) {
        final dt = i.isEven ? 1 / 59.5 : 1 / 60.5;
        final t = i / 60;
        final y = filter.update(math.sin(2 * math.pi * frequency * t), dt);
        if (i > 120) {
          output.add(y * y);
        }
      }
      return math.sqrt(output.reduce((a, b) => a + b) / output.length);
    }

    expect(response(5), greaterThan(response(.2) * 2));
    expect(response(5), greaterThan(response(25) * 1.2));
  });
  test('reset clears temporal state', () {
    final f = ReferenceBandpass(1, 8);
    f.update(1, 1 / 60);
    f.update(0, 1 / 60);
    f.reset();
    expect(f.update(10, 1 / 60), 0);
  });
}
