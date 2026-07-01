import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CalibrationService {
  /// Saves the threshold to Supabase and SharedPreferences.
  /// Returns true on success, false on failure.
  static Future<bool> saveThreshold({
    required String userId,
    required double threshold,
  }) async {
    try {
      // 1. Update Supabase students.verification_threshold
      await Supabase.instance.client
          .from('students')
          .update({'verification_threshold': threshold})
          .eq('id', userId);

      // 2. Update SharedPreferences key: 'emb_threshold_$userId'
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('emb_threshold_$userId', threshold.toString());

      return true;
    } catch (e) {
      return false;
    }
  }
}
