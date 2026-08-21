import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/supabase_service.dart';

class NotificationService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static bool _isReconciling = false;
  static bool _pluginInitialized = false;

  static const AndroidNotificationChannel attendanceChannel =
      AndroidNotificationChannel(
        'attendance_alerts',
        'Attendance Alerts',
        description: 'Notifications for attendance window opening',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );

  /// Ensures the attendance notification channel is created on Android.
  static Future<void> createNotificationChannel(
    FlutterLocalNotificationsPlugin plugin,
  ) async {
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(attendanceChannel);
  }

  /// Ensures the local notification plugin is initialized and the channel exists.
  static Future<void> ensureInitialized([
    FlutterLocalNotificationsPlugin? plugin,
  ]) async {
    final targetPlugin = plugin ?? localNotificationsPlugin;
    if (!_pluginInitialized || plugin != null) {
      const AndroidInitializationSettings androidInit =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const InitializationSettings initSettings = InitializationSettings(
        android: androidInit,
      );
      await targetPlugin.initialize(settings: initSettings);
      await createNotificationChannel(targetPlugin);
      if (plugin == null || plugin == localNotificationsPlugin) {
        _pluginInitialized = true;
      }
    }
  }

  /// Formats the collapsed and expanded notification text.
  /// Handles missing or empty subject/period safely without producing
  /// 'Period null', 'null', or duplicate prefixes.
  static ({String title, String body, String bigText}) buildAttendanceContent({
    String? subjectName,
    String? periodNumber,
  }) {
    final trimmedSubject = subjectName?.trim();
    final cleanSubject =
        (trimmedSubject != null &&
            trimmedSubject.isNotEmpty &&
            trimmedSubject.toLowerCase() != 'null' &&
            trimmedSubject.toLowerCase() != 'undefined')
        ? trimmedSubject
        : null;

    final trimmedPeriod = periodNumber?.trim();
    final cleanPeriod =
        (trimmedPeriod != null &&
            trimmedPeriod.isNotEmpty &&
            trimmedPeriod.toLowerCase() != 'null' &&
            trimmedPeriod.toLowerCase() != 'undefined')
        ? trimmedPeriod
        : null;

    final lines = <String>[];
    final headerLines = <String>[];

    if (cleanSubject != null) {
      lines.add(cleanSubject);
      headerLines.add(cleanSubject);
    }

    if (cleanPeriod != null) {
      lines.add('Period $cleanPeriod');
      headerLines.add('Period $cleanPeriod');
    }

    lines.add('Scan QR to mark attendance');

    const title = '📋 Attendance Open';
    final body = lines.join('\n');

    final headerText =
        headerLines.isNotEmpty ? headerLines.join('\n') : 'Attendance';

    final bigText =
        '$headerText\n\n'
        'Your attendance window is now open.\n\n'
        'Scan the QR code displayed by your teacher to mark your attendance.\n\n'
        'Complete face verification after scanning the QR code.';

    return (title: title, body: body, bigText: bigText);
  }

  /// Displays an Attendance Open notification using Android BigTextStyleInformation.
  /// Used uniformly across foreground, background, and normally terminated app states.
  static Future<void> showAttendanceNotification({
    required FlutterLocalNotificationsPlugin plugin,
    required Map<String, dynamic> data,
  }) async {
    String? subjectName = data['subject_name']?.toString();
    String? periodNumber = data['period_number']?.toString();
    final sessionId = data['session_id']?.toString();

    debugPrint(
      '[FCM] Received data: subject_name="$subjectName", period_number="$periodNumber", session_id="$sessionId"',
    );

    // Fallback: If subject_name or period_number are not present in payload,
    // query Supabase attendance_sessions to resolve them.
    if ((subjectName == null || subjectName.trim().isEmpty) &&
        sessionId != null &&
        sessionId.isNotEmpty) {
      try {
        final sessionRow = await supabase
            .from('attendance_sessions')
            .select('subject_id, period_id')
            .eq('id', sessionId)
            .maybeSingle();

        if (sessionRow != null) {
          final subjectId = sessionRow['subject_id'];
          final periodId = sessionRow['period_id'];

          if (subjectId != null) {
            final subRow = await supabase
                .from('subjects')
                .select('name')
                .eq('id', subjectId)
                .maybeSingle();
            subjectName = subRow?['name']?.toString();
          }

          if (periodId != null) {
            final perRow = await supabase
                .from('periods')
                .select('period_number')
                .eq('id', periodId)
                .maybeSingle();
            periodNumber = perRow?['period_number']?.toString();
          }
        }
        debugPrint(
          '[FCM] Resolved from DB fallback: subject_name="$subjectName", period_number="$periodNumber"',
        );
      } catch (e) {
        debugPrint('[FCM] Fallback session lookup error: $e');
      }
    }

    final content = buildAttendanceContent(
      subjectName: subjectName,
      periodNumber: periodNumber,
    );

    debugPrint(
      '[FCM] Showing notification: title="${content.title}", body="${content.body}"',
    );

    // Derive a stable notification ID based on session_id to ensure idempotency
    final int notificationId =
        (sessionId != null && sessionId.isNotEmpty) ? sessionId.hashCode : 1001;

    final androidDetails = AndroidNotificationDetails(
      attendanceChannel.id,
      attendanceChannel.name,
      channelDescription: attendanceChannel.description,
      importance: Importance.max,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      playSound: true,
      enableVibration: true,
      styleInformation: BigTextStyleInformation(
        content.bigText,
        contentTitle: content.title,
        summaryText: null,
        htmlFormatBigText: false,
        htmlFormatContentTitle: false,
        htmlFormatSummaryText: false,
      ),
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    await plugin.show(
      id: notificationId,
      title: content.title,
      body: content.body,
      notificationDetails: notificationDetails,
      payload: jsonEncode(data),
    );

    // Save the reconciled session ID only AFTER successful display
    if (sessionId != null && sessionId.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'attendance_notification_reconciled_session_id',
          sessionId,
        );
      } catch (e) {
        debugPrint('[FCM] Failed to save reconciled session marker: $e');
      }
    }
  }

  /// Reconciles missed active attendance session notification when notifications are re-enabled.
  static Future<void> reconcileActiveAttendanceNotification() async {
    if (_isReconciling) {
      debugPrint('[FCM] Reconciliation already in progress — skipping concurrent call');
      return;
    }
    _isReconciling = true;

    try {
      debugPrint('[FCM] Reconciliation started');

      // A. Authenticated user check
      final user = supabase.auth.currentUser;
      if (user == null) {
        debugPrint('[FCM] Reconciliation: no logged-in user');
        return;
      }

      // B. Fetch student's class_id
      final studentRow = await supabase
          .from('students')
          .select('class_id')
          .eq('id', user.id)
          .maybeSingle();

      final classId = studentRow?['class_id']?.toString();
      if (classId == null || classId.isEmpty) {
        debugPrint('[FCM] Reconciliation: class_id is missing for student ${user.id}');
        return;
      }
      debugPrint('[FCM] Reconciliation: class_id=$classId');

      // C. Query the latest ACTIVE attendance session for this class
      final activeSession = await supabase
          .from('attendance_sessions')
          .select('id, subject_id, period_id, opened_at, status')
          .eq('class_id', classId)
          .eq('status', 'active')
          .order('opened_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (activeSession == null) {
        debugPrint('[FCM] Reconciliation: no active session');
        return;
      }

      final sessionId = activeSession['id']?.toString();
      if (sessionId == null || sessionId.isEmpty) {
        debugPrint('[FCM] Reconciliation: active session has no valid id');
        return;
      }
      debugPrint('[FCM] Reconciliation: active session=$sessionId');

      // D. Authoritative 180-second attendance window validation
      final openedAtStr = activeSession['opened_at']?.toString();
      if (openedAtStr == null || openedAtStr.isEmpty) {
        debugPrint('[FCM] Reconciliation: active session exists but opened_at is missing');
        return;
      }

      DateTime openedAt;
      try {
        openedAt = DateTime.parse(openedAtStr).toUtc();
      } catch (e) {
        debugPrint('[FCM] Reconciliation: failed to parse opened_at: $e');
        return;
      }

      final deadline = openedAt.add(const Duration(seconds: 180));
      final nowUtc = DateTime.now().toUtc();

      if (nowUtc.isAfter(deadline)) {
        debugPrint('[FCM] Reconciliation: session expired');
        return;
      }

      // E. Check student's period_attendance record for this session
      final attendanceRecord = await supabase
          .from('period_attendance')
          .select('status, face_verified')
          .eq('session_id', sessionId)
          .eq('student_id', user.id)
          .maybeSingle();

      if (attendanceRecord != null) {
        final status = attendanceRecord['status']?.toString().toLowerCase();
        final faceVerified = attendanceRecord['face_verified'] == true;
        if (status == 'present' || status == 'pending' || faceVerified) {
          debugPrint(
            '[FCM] Reconciliation: student already has attendance record (status=$status, face_verified=$faceVerified)',
          );
          return;
        }
      }

      // Local duplicate protection check
      final prefs = await SharedPreferences.getInstance();
      final lastReconciledSessionId =
          prefs.getString('attendance_notification_reconciled_session_id');

      if (lastReconciledSessionId == sessionId) {
        debugPrint(
          '[FCM] Reconciliation: notification already shown for session',
        );
        return;
      }

      // F & G. Fetch subject name and period number
      String? subjectName;
      final subjectId = activeSession['subject_id'];
      if (subjectId != null) {
        final subRow = await supabase
            .from('subjects')
            .select('name')
            .eq('id', subjectId)
            .maybeSingle();
        subjectName = subRow?['name']?.toString();
      }

      String? periodNumber;
      final periodId = activeSession['period_id'];
      if (periodId != null) {
        final perRow = await supabase
            .from('periods')
            .select('period_number')
            .eq('id', periodId)
            .maybeSingle();
        periodNumber = perRow?['period_number']?.toString();
      }

      debugPrint('[FCM] Reconciliation: showing missed attendance notification');

      await ensureInitialized();

      await showAttendanceNotification(
        plugin: localNotificationsPlugin,
        data: {
          'type': 'attendance_opened',
          'session_id': sessionId,
          'class_id': classId,
          'subject_name': subjectName,
          'period_number': periodNumber,
        },
      );

      debugPrint('[FCM] Reconciliation: notification shown successfully');
    } catch (e) {
      debugPrint('[FCM] Reconciliation error: $e');
    } finally {
      _isReconciling = false;
    }
  }

  /// Call this after student logs in or when enabling notifications.
  /// Checks the notifications_enabled preference before saving token.
  /// Returns true if token setup succeeded and notifications are available, false otherwise.
  static Future<bool> initAndSaveToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final notificationsEnabled =
          prefs.getBool('notifications_enabled') ?? true;

      if (!notificationsEnabled) {
        debugPrint(
          '[FCM] Notifications disabled by user — skipping token save',
        );
        return false;
      }

      // Request permission
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[FCM] Permission denied by user');
        return false;
      }

      final token = await _messaging.getToken();
      if (token == null) {
        debugPrint('[FCM] Token is null');
        return false;
      }

      debugPrint('[FCM] Token obtained: ${token.substring(0, 20)}...');
      final saved = await _saveTokenToSupabase(token);
      if (!saved) {
        return false;
      }

      // Keep token fresh — update Supabase if FCM rotates the token
      _messaging.onTokenRefresh.listen((newToken) async {
        final currentPrefs = await SharedPreferences.getInstance();
        final enabled = currentPrefs.getBool('notifications_enabled') ?? true;
        if (enabled) {
          await _saveTokenToSupabase(newToken);
          debugPrint('[FCM] Token refreshed and updated');
        }
      });

      return true;
    } catch (e) {
      debugPrint('[FCM] initAndSaveToken error: $e');
      return false;
    }
  }

  /// Saves or updates the FCM token in Supabase push_tokens table
  static Future<bool> _saveTokenToSupabase(String token) async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) {
        debugPrint('[FCM] No logged-in user — cannot save token');
        return false;
      }

      await supabase.from('push_tokens').upsert({
        'student_id': user.id,
        'fcm_token': token,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'student_id');

      debugPrint('[FCM] Token saved to Supabase for user: ${user.id}');
      return true;
    } catch (e) {
      debugPrint('[FCM] _saveTokenToSupabase error: $e');
      return false;
    }
  }

  /// Call this when notifications are ENABLED from settings
  static Future<void> enableNotifications() async {
    debugPrint('[FCM] Notifications enabled — saving token');
    final initialized = await initAndSaveToken();
    if (!initialized) {
      debugPrint(
        '[FCM] Notifications initialization failed or permission denied — skipping reconciliation',
      );
      return;
    }

    // Reconcile an attendance session that may have opened
    // while notifications were disabled.
    await reconcileActiveAttendanceNotification();
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
