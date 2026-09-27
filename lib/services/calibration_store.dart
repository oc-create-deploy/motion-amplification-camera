import 'package:shared_preferences/shared_preferences.dart';

import '../models/analysis_models.dart';

class CalibrationStore {
  static const _key = 'pixels_per_millimeter';
  static const _knownLengthKey = 'known_length_millimeters';
  static const _referencePixelsKey = 'reference_pixel_length';
  Future<Calibration?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getDouble(_key);
    return value != null && value > 0
        ? Calibration(
            pixelsPerMillimeter: value,
            knownLengthMillimeters: preferences.getDouble(_knownLengthKey) ?? 0,
            referencePixelLength:
                preferences.getDouble(_referencePixelsKey) ?? 0,
          )
        : null;
  }

  Future<void> save(Calibration calibration) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(_key, calibration.pixelsPerMillimeter);
    await preferences.setDouble(
      _knownLengthKey,
      calibration.knownLengthMillimeters,
    );
    await preferences.setDouble(
      _referencePixelsKey,
      calibration.referencePixelLength,
    );
  }

  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key);
    await preferences.remove(_knownLengthKey);
    await preferences.remove(_referencePixelsKey);
  }
}
