import 'package:shared_preferences/shared_preferences.dart';

import '../models/analysis_models.dart';

class CalibrationStore {
  static const _key = 'pixels_per_millimeter';
  Future<Calibration?> load() async {
    final value = (await SharedPreferences.getInstance()).getDouble(_key);
    return value != null && value > 0
        ? Calibration(pixelsPerMillimeter: value)
        : null;
  }

  Future<void> save(Calibration calibration) async =>
      (await SharedPreferences.getInstance()).setDouble(
        _key,
        calibration.pixelsPerMillimeter,
      );
  Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(_key);
}
