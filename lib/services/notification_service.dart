import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/supabase_service.dart';

class NotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// Call this after student logs in.
  /// Checks the notifications_enabled preference before saving token.
  static Future<void> initAndSaveToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final notificationsEnabled =
          prefs.getBool('notifications_enabled') ?? true;

      if (!notificationsEnabled) {
        debugPrint(
          '[FCM] Notifications disabled by user — skipping token save',
        );
        return;
      }

      // Request permission
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[FCM] Permission denied by user');
        return;
      }

      final token = await _messaging.getToken();
      if (token == null) {
        debugPrint('[FCM] Token is null');
        return;
      }

      debugPrint('[FCM] Token obtained: ${token.substring(0, 20)}...');
      await _saveTokenToSupabase(token);

      // Keep token fresh — update Supabase if FCM rotates the token
      _messaging.onTokenRefresh.listen((newToken) async {
        final currentPrefs = await SharedPreferences.getInstance();
        final enabled = currentPrefs.getBool('notifications_enabled') ?? true;
        if (enabled) {
          await _saveTokenToSupabase(newToken);
          debugPrint('[FCM] Token refreshed and updated');
        }
      });
    } catch (e) {
      debugPrint('[FCM] initAndSaveToken error: $e');
    }
  }

  /// Saves or updates the FCM token in Supabase push_tokens table
  static Future<void> _saveTokenToSupabase(String token) async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) {
        debugPrint('[FCM] No logged-in user — cannot save token');
        return;
      }

      await supabase.from('push_tokens').upsert({
        'student_id': user.id,
        'fcm_token': token,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'student_id');

      debugPrint('[FCM] Token saved to Supabase for user: ${user.id}');
    } catch (e) {
      debugPrint('[FCM] _saveTokenToSupabase error: $e');
    }
  }

  /// Call this when notifications are ENABLED from settings
  static Future<void> enableNotifications() async {
    debugPrint('[FCM] Notifications enabled — saving token');
    await initAndSaveToken();
  }

  /// Call this when notifications are DISABLED from settings
  static Future<void> disableNotifications() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        await supabase.from('push_tokens').delete().eq('student_id', user.id);
        debugPrint(
          '[FCM] Token removed from Supabase — notifications disabled',
        );
      }
      // Do NOT delete the FCM token from Firebase itself
      // (deleteToken would require re-requesting permission next time)
    } catch (e) {
      debugPrint('[FCM] disableNotifications error: $e');
    }
  }

  /// Call this when student logs out
  static Future<void> removeTokenOnLogout() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        await supabase.from('push_tokens').delete().eq('student_id', user.id);
      }
      await _messaging.deleteToken();
      debugPrint('[FCM] Token removed on logout');
    } catch (e) {
      debugPrint('[FCM] removeTokenOnLogout error: $e');
    }
  }
}
