import 'package:flutter_test/flutter_test.dart';
import 'package:motion_amplification_camera/models/analysis_models.dart';

void main() {
  test('reference calibration converts pixels to millimeters', () {
    final calibration = Calibration.fromReference(
      pixelLength: 250,
      millimeters: 20,
    );
    expect(calibration.pixelsPerMillimeter, 12.5);
    expect(calibration.pixelsToMillimeters(25), 2);
  });
  test(
    'invalid references are rejected',
    () => expect(
      () => Calibration.fromReference(pixelLength: 0, millimeters: 10),
      throwsArgumentError,
    ),
  );
}
