import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'dart:math' as math;
import '../../utils/app_styles.dart';
import '../../utils/auth_flow_state.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/custom_bottom_nav.dart';
import '../../widgets/fade_slide_y.dart';
import '../../services/supabase_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _scheduleExpanded = false;

  RealtimeChannel? _rejectionWatchChannel;
  bool _rejectionDialogShown = false;

  String _studentName = 'Student';
  String _upcomingPeriodText = '';

  bool _teacherFinalized = false;
  String _finalizedSubject = '';
  String _finalizedPeriod = '';
  bool _teacherFinalizedAbsent = false;
  String _absentSubject = '';
  String _absentPeriod = '';

  String _geofenceStatus = 'checking';
  int _attendanceStreak = -1;
  List<bool?> _weekDayAttendance = []; // Mon=0 ... Sat=5, null=future/weekend

  // ── Static cache — survives tab switches ──────────────────
  static bool? _cachedIsPresent;
  static String _cachedMarkedTime = '';
  static bool _cachedIsPastCutoff = false;
  static double _cachedPct = -1;
  static int _cachedPresent = 0;
  static int _cachedTotal = 0;
  static String _cachedTimeDisplay = '--:-- --';
  static String _cachedDateDisplay = 'No attendance yet';
  static double _cachedMotivationalPct = -1.0;

  // ── Period confirmation static cache (date-aware) ─────────
  static String? _cachedPeriodDate;
  static bool _cachedPeriodFinalized = false;
  static String _cachedPeriodFinalizedSubject = '';
  static String _cachedPeriodFinalizedPeriod = '';
  static bool _cachedPeriodFinalizedAbsent = false;
  static String _cachedPeriodAbsentSubject = '';
  static String _cachedPeriodAbsentPeriod = '';
  // ─────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final todayStr =
        "${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}";
    if (_cachedPeriodDate == todayStr) {
      _teacherFinalized = _cachedPeriodFinalized;
      _finalizedSubject = _cachedPeriodFinalizedSubject;
      _finalizedPeriod = _cachedPeriodFinalizedPeriod;
      _teacherFinalizedAbsent = _cachedPeriodFinalizedAbsent;
      _absentSubject = _cachedPeriodAbsentSubject;
      _absentPeriod = _cachedPeriodAbsentPeriod;
    } else {
      _cachedPeriodDate = todayStr;
      _cachedPeriodFinalized = false;
      _cachedPeriodFinalizedSubject = '';
      _cachedPeriodFinalizedPeriod = '';
      _cachedPeriodFinalizedAbsent = false;
      _cachedPeriodAbsentSubject = '';
      _cachedPeriodAbsentPeriod = '';
    }

    _fetchProfile();
    _watchForFaceRejection();
    _fetchUpcomingPeriod();
    _fetchAttendanceStreak();
    // Clear any lingering snackbars from previous screens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }
    });
    // Refresh when returning to dashboard
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
    _checkGeofenceStatus();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _rejectionWatchChannel?.unsubscribe();
    _pulseController.dispose();
    super.dispose();
  }

  void _watchForFaceRejection() {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    _rejectionWatchChannel?.unsubscribe();
    _rejectionWatchChannel = supabase
        .channel('dashboard_rejection_watch_${user.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'students',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: user.id,
          ),
          callback: (payload) {
            final newRecord = payload.newRecord;
            final bool isRejected = newRecord['is_rejected'] == true;
            if (isRejected && mounted && !_rejectionDialogShown) {
              _rejectionDialogShown = true;
              _showFaceRejectedDialog();
            }
          },
        )
        .subscribe();
  }

  void _showFaceRejectedDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.face_retouching_off_rounded, color: AppStyles.errorRed),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Face Registration Rejected',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: const Text(
          'Your face registration was rejected by your teacher. You need to register your face again before you can use face-based attendance.',
          style: TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close', style: TextStyle(color: AppStyles.textGray)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              AuthFlowState.instance.passwordSet = true;
              AuthFlowState.instance.faceRegistered = false;
              Navigator.of(context).pushReplacementNamed('/register');
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppStyles.primaryBlue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Register Again'),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchProfile() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        final userData = await supabase
            .from('users')
            .select('full_name')
            .eq('id', user.id)
            .maybeSingle();

        if (userData != null && mounted) {
          setState(() {
            _studentName = userData['full_name'] as String;
          });
        }
      }
    } catch (e, stack) {
      debugPrint('[DASHBOARD] error: $e');
      debugPrint('[DASHBOARD] stack: $stack');
    }
  }

  String _getFormattedDate() {
    final now = DateTime.now();
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final dayName = days[now.weekday - 1];
    final monthName = months[now.month - 1];
    return '$dayName, $monthName ${now.day}';
  }

  Future<void> _checkGeofenceStatus() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) setState(() => _geofenceStatus = 'off');
        return;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) setState(() => _geofenceStatus = 'off');
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      double centerLat = 17.402150;
      double centerLng = 78.652915;
      double radiusMeters = 200.0;

      try {
        final settings = await supabase
            .from('geofence_settings')
            .select('latitude, longitude, radius_meters')
            .order('updated_at', ascending: false)
            .limit(1)
            .maybeSingle();
        if (settings != null) {
          centerLat = (settings['latitude'] as num).toDouble();
          centerLng = (settings['longitude'] as num).toDouble();
          radiusMeters = (settings['radius_meters'] as num).toDouble();
        }
      } catch (_) {}

      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        centerLat,
        centerLng,
      );

      if (mounted) {
        setState(() {
          _geofenceStatus = distance <= radiusMeters ? 'oncampus' : 'offcampus';
        });
      }
    } catch (e) {
      debugPrint('[GEO] $e');
      if (mounted) setState(() => _geofenceStatus = 'off');
    }
  }

  Future<void> _fetchUpcomingPeriod() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;
      final studentData = await supabase
          .from('students')
          .select('class_id')
          .eq('id', user.id)
          .maybeSingle();
      if (studentData == null) return;
      final classId = studentData['class_id'] as String;
      final jsDay = DateTime.now().weekday;
      if (jsDay == 7) {
        if (mounted) setState(() => _upcomingPeriodText = 'no_classes_today');
        return;
      }
      final now = TimeOfDay.now();
      // If it's before 7 AM, treat as start of day so morning periods show correctly
      final nowMinutes = (now.hour < 7) ? 0 : (now.hour * 60 + now.minute);
      final rows = await supabase
          .from('timetables')
          .select(
            'subject:subjects(name), period:periods(period_number, start_time, end_time)',
          )
          .eq('class_id', classId)
          .eq('day_of_week', jsDay);
      if ((rows as List).isEmpty) {
        if (mounted) {
          setState(() => _upcomingPeriodText = 'No more classes today');
        }
        return;
      }
      rows.sort((a, b) {
        final aStart =
            ((a['period'] as Map?)?['start_time'] as String? ?? '00:00')
                .replaceAll(':', '');
        final bStart =
            ((b['period'] as Map?)?['start_time'] as String? ?? '00:00')
                .replaceAll(':', '');
        return aStart.compareTo(bStart);
      });
      Map<String, dynamic>? upcoming;
      for (final row in rows) {
        final startStr =
            (row['period'] as Map?)?['start_time'] as String? ?? '00:00';
        final parts = startStr.split(':');
        final startMinutes = int.parse(parts[0]) * 60 + int.parse(parts[1]);
        if (startMinutes > nowMinutes) {
          upcoming = row;
          break;
        }
      }
      if (upcoming == null) {
        if (mounted) {
          setState(() => _upcomingPeriodText = 'No more classes today 🎉');
        }
        return;
      }
      final subjectName =
          (upcoming['subject'] as Map?)?['name'] as String? ?? 'Class';
      final periodNum =
          (upcoming['period'] as Map?)?['period_number'] as int? ?? 1;
      final startTime =
          ((upcoming['period'] as Map?)?['start_time'] as String? ?? '')
              .substring(0, 5);
      int remaining = 0;
      for (final row in rows) {
        final startStr =
            (row['period'] as Map?)?['start_time'] as String? ?? '00:00';
        final parts = startStr.split(':');
        final startMin = int.parse(parts[0]) * 60 + int.parse(parts[1]);
        if (startMin > nowMinutes) remaining++;
      }
      final remainingLabel = remaining > 1 ? ' · $remaining left' : '';
      if (mounted) {
        setState(
          () => _upcomingPeriodText =
              'P$periodNum · $subjectName · $startTime$remainingLabel',
        );
      }
    } catch (e) {
      debugPrint('[UPCOMING] $e');
    }
  }

  Future<void> _fetchAttendanceStreak() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      // Get student registration date (created_at from users table)
      final userData = await supabase
          .from('users')
          .select('created_at')
          .eq('id', user.id)
          .maybeSingle();

      final registrationDate = userData != null
          ? DateTime.parse(userData['created_at'] as String)
          : DateTime.now().subtract(const Duration(days: 365));

      // Fetch all attendance records from registration date
      final records = await supabase
          .from('college_attendance')
          .select('date, status')
          .eq('student_id', user.id)
          .gte('date', registrationDate.toIso8601String().split('T')[0])
          .order('date', ascending: false);

      // Build a map of date → status
      final Map<String, String> attendanceMap = {};
      for (final r in records) {
        attendanceMap[r['date'] as String] = r['status'] as String;
      }

      // Calculate streak — walk backwards from today, skip weekends
      int streak = 0;
      final today = DateTime.now();

      for (int i = 0; i < 365; i++) {
        final checkDay = today.subtract(Duration(days: i));
        final dayOfWeek = checkDay.weekday; // Mon=1 ... Sun=7

        // Skip Sunday (7)
        if (dayOfWeek == 7) continue;

        // Don't count today if it's in the future or attendance not yet taken
        final dateStr = checkDay.toIso8601String().split('T')[0];
        final status = attendanceMap[dateStr];

        if (status == 'present') {
          streak++;
        } else if (status == 'absent') {
          break; // Streak broken
        } else {
          // No record yet — if it's today and before 4PM, don't break streak
          final now = DateTime.now();
          final cutoff = DateTime(now.year, now.month, now.day, 16, 0);
          if (i == 0 && now.isBefore(cutoff)) {
            continue; // Today not yet marked, don't break
          } else if (i == 0) {
            break; // Today past cutoff and not marked = absent
          } else {
            break; // Past day with no record = absent
          }
        }
      }

      // Build current week day attendance (Mon=0 ... Sat=5)
      // Find Monday of current week
      final monday = today.subtract(Duration(days: today.weekday - 1));
      final List<bool?> weekDays = [];

      for (int d = 0; d < 6; d++) {
        // Mon to Sat
        final day = monday.add(Duration(days: d));
        final dayStr = day.toIso8601String().split('T')[0];
        final todayStr = today.toIso8601String().split('T')[0];

        if (day.isAfter(today)) {
          weekDays.add(null); // Future day
        } else if (dayStr == todayStr) {
          final status = attendanceMap[dayStr];
          weekDays.add(
            status == 'present' ? true : null,
          ); // Today — only mark if present
        } else {
          final status = attendanceMap[dayStr];
          weekDays.add(status == 'present' ? true : false);
        }
      }

      if (mounted) {
        setState(() {
          _attendanceStreak = streak;
          _weekDayAttendance = weekDays;
        });
      }
    } catch (e) {
      debugPrint('[STREAK] $e');
    }
  }

  void _onNavTap(int index) {
    if (index == 0) return;
    if (index == 1) Navigator.of(context).pushReplacementNamed('/history');
    if (index == 2) Navigator.of(context).pushReplacementNamed('/settings');
    if (index == 3) Navigator.of(context).pushReplacementNamed('/profile');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Dismiss',
          transitionDuration: const Duration(milliseconds: 250),
          pageBuilder: (context, animation, secondaryAnimation) {
            return Dialog(
              backgroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Exit App',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppStyles.textDark,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Are you sure you want to exit?',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppStyles.textGray,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: AppStyles.textGray.withValues(alpha: 0.3),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 12,
                            ),
                          ),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(
                              color: AppStyles.textGray,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () => SystemNavigator.pop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade600,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 12,
                            ),
                            elevation: 0,
                          ),
                          child: const Text(
                            'Exit',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
          transitionBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.85, end: 1.0).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                ),
                child: child,
              ),
            );
          },
        );
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          toolbarHeight: 88,
          titleSpacing: 0,
          title: Padding(
            padding: const EdgeInsets.only(top: 12, left: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        'Hello, ${_studentName.split(' ').first}',
                        style: TextStyle(
                          color:
                              theme.textTheme.displayLarge?.color ??
                              AppStyles.textDark,
                          fontWeight: FontWeight.w900,
                          fontSize: 26,
                          letterSpacing: -0.5,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedBuilder(
                      animation: _pulseAnimation,
                      builder: (context, child) => Transform.rotate(
                        angle: (_pulseAnimation.value - 1.0) * 0.3,
                        child: child,
                      ),
                      child: const Text('👋', style: TextStyle(fontSize: 24)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blueGrey.shade50.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.blueGrey.shade200.withValues(
                              alpha: 0.5,
                            ),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.calendar_today_rounded,
                              size: 11,
                              color: Colors.blueGrey.shade400,
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                _getFormattedDate(),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.blueGrey.shade700,
                                  letterSpacing: 0.1,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 5),
                              width: 3,
                              height: 3,
                              decoration: BoxDecoration(
                                color: Colors.blueGrey.shade300,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const _LiveClockText(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () {
                        if (mounted) {
                          setState(() => _geofenceStatus = 'checking');
                        }
                        _checkGeofenceStatus();
                      },
                      child: _CompactGeofenceBadge(status: _geofenceStatus),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout_rounded, color: AppStyles.errorRed),
              onPressed: () =>
                  Navigator.of(context).pushReplacementNamed('/home'),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async {
              await Future.wait([
                _fetchProfile(),
                _fetchUpcomingPeriod(),
                _fetchAttendanceStreak(),
              ]);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                horizontal: 24.0,
                vertical: 16.0,
              ),
              children: [
                if (_upcomingPeriodText.isNotEmpty)
                  FadeSlideY(
                    delay: const Duration(milliseconds: 200),
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppStyles.primaryBlue.withValues(alpha: 0.1)
                            : AppStyles.primaryBlue.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppStyles.primaryBlue.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          if (_upcomingPeriodText == 'no_classes_today')
                            const _SleepingZAnimation()
                          else
                            const Icon(
                              Icons.schedule_rounded,
                              size: 18,
                              color: AppStyles.primaryBlue,
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _upcomingPeriodText == 'no_classes_today'
                                ? Text(
                                    'No classes today — rest up!',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? Colors.white
                                          : AppStyles.primaryBlue,
                                    ),
                                  )
                                : RichText(
                                    text: TextSpan(
                                      children: [
                                        const TextSpan(
                                          text: '🔔 ',
                                          style: TextStyle(fontSize: 13),
                                        ),
                                        TextSpan(
                                          text: _upcomingPeriodText,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: isDark
                                                ? Colors.white
                                                : AppStyles.primaryBlue,
                                            height: 1.3,
                                          ),
                                        ),
                                      ],
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),

                FadeSlideY(
                  delay: const Duration(milliseconds: 50),
                  child: _AttendanceBanner(
                    onSessionFinalized: () {
                      if (mounted) setState(() {});
                    },
                    onTeacherFinalized: (subject, period) {
                      if (mounted) {
                        setState(() {
                          _teacherFinalized = true;
                          _finalizedSubject = subject;
                          _finalizedPeriod = period;
                          _teacherFinalizedAbsent = false;
                          _absentSubject = '';
                          _absentPeriod = '';

                          _cachedPeriodFinalized = true;
                          _cachedPeriodFinalizedSubject = subject;
                          _cachedPeriodFinalizedPeriod = period;
                          _cachedPeriodFinalizedAbsent = false;
                          _cachedPeriodAbsentSubject = '';
                          _cachedPeriodAbsentPeriod = '';
                        });
                      }
                    },
                    onTeacherFinalizedAbsent: (subject, period) {
                      if (mounted) {
                        setState(() {
                          _teacherFinalized = false;
                          _finalizedSubject = '';
                          _finalizedPeriod = '';
                          _teacherFinalizedAbsent = true;
                          _absentSubject = subject;
                          _absentPeriod = period;

                          _cachedPeriodFinalized = false;
                          _cachedPeriodFinalizedSubject = '';
                          _cachedPeriodFinalizedPeriod = '';
                          _cachedPeriodFinalizedAbsent = true;
                          _cachedPeriodAbsentSubject = subject;
                          _cachedPeriodAbsentPeriod = period;
                        });
                      }
                    },
                    onNewSession: () {
                      if (mounted) {
                        setState(() {
                          _teacherFinalized = false;
                          _finalizedSubject = '';
                          _finalizedPeriod = '';
                          _teacherFinalizedAbsent = false;
                          _absentSubject = '';
                          _absentPeriod = '';

                          _cachedPeriodFinalized = false;
                          _cachedPeriodFinalizedSubject = '';
                          _cachedPeriodFinalizedPeriod = '';
                          _cachedPeriodFinalizedAbsent = false;
                          _cachedPeriodAbsentSubject = '';
                          _cachedPeriodAbsentPeriod = '';
                        });
                      }
                    },
                    onClearFinalized: () {
                      if (mounted) {
                        setState(() {
                          _teacherFinalized = false;
                          _finalizedSubject = '';
                          _finalizedPeriod = '';
                          _teacherFinalizedAbsent = false;
                          _absentSubject = '';
                          _absentPeriod = '';

                          _cachedPeriodFinalized = false;
                          _cachedPeriodFinalizedSubject = '';
                          _cachedPeriodFinalizedPeriod = '';
                          _cachedPeriodFinalizedAbsent = false;
                          _cachedPeriodAbsentSubject = '';
                          _cachedPeriodAbsentPeriod = '';
                        });
                      }
                    },
                    teacherFinalized: _teacherFinalized,
                    finalizedSubject: _finalizedSubject,
                    finalizedPeriod: _finalizedPeriod,
                    teacherFinalizedAbsent: _teacherFinalizedAbsent,
                    absentSubject: _absentSubject,
                    absentPeriod: _absentPeriod,
                  ),
                ),
                FadeSlideY(
                  delay: const Duration(milliseconds: 100),
                  child: _TodayStatusCard(isDark: isDark),
                ),
                const SizedBox(height: 10),
                FadeSlideY(
                  delay: const Duration(milliseconds: 180),
                  child: _AttendancePercentageCard(
                    theme: theme,
                    isDark: isDark,
                  ),
                ),
                const SizedBox(height: 8),
                FadeSlideY(
                  delay: const Duration(milliseconds: 220),
                  child: const _MotivationalMessage(),
                ),
                const SizedBox(height: 8),
                if (_attendanceStreak >= 0)
                  FadeSlideY(
                    delay: const Duration(milliseconds: 240),
                    child: _AttendanceStreakCard(
                      streak: _attendanceStreak,
                      weekDays: _weekDayAttendance,
                    ),
                  ),
                const SizedBox(height: 10),
                FadeSlideY(
                  delay: const Duration(milliseconds: 260),
                  child: _HeroAttendanceCard(theme: theme),
                ),
                const SizedBox(height: 20),
                FadeSlideY(
                  delay: const Duration(milliseconds: 340),
                  child: AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      return Transform.scale(
                        scale: _pulseAnimation.value,
                        child: Container(
                          decoration: BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: theme.primaryColor.withValues(
                                  alpha: 0.3,
                                ),
                                blurRadius: 20,
                                spreadRadius: 2,
                              ),
                            ],
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: child,
                        ),
                      );
                    },
                    child: AnimatedButton(
                      onPressed: () =>
                          Navigator.of(context).pushNamed('/face_verification'),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.camera_alt_rounded),
                            SizedBox(width: 12),
                            Text('Verify Face'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                FadeSlideY(
                  delay: const Duration(milliseconds: 580),
                  child: _ExpandableScheduleSection(
                    isDark: isDark,
                    theme: theme,
                    isExpanded: _scheduleExpanded,
                    onToggle: () =>
                        setState(() => _scheduleExpanded = !_scheduleExpanded),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        bottomNavigationBar: CustomBottomNav(currentIndex: 0, onTap: _onNavTap),
      ),
    );
  }
}

// Isolated clock — ticks on its own timer with its own setState,
// so it no longer forces the entire DashboardScreen (and every child
// card doing its own fetch in didUpdateWidget) to rebuild every 30s.
class _LiveClockText extends StatefulWidget {
  const _LiveClockText();

  @override
  State<_LiveClockText> createState() => _LiveClockTextState();
}

class _LiveClockTextState extends State<_LiveClockText> {
  late String _time;
  Timer? _timer;

  String _getAnimatedTime() {
    final now = DateTime.now();
    final hour = now.hour > 12
        ? now.hour - 12
        : (now.hour == 0 ? 12 : now.hour);
    final minute = now.minute.toString().padLeft(2, '0');
    final period = now.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  @override
  void initState() {
    super.initState();
    _time = _getAnimatedTime();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _time = _getAnimatedTime());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      transitionBuilder: (child, anim) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.5),
          end: Offset.zero,
        ).animate(anim),
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: Text(
        _time,
        key: ValueKey(_time),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Colors.blueGrey.shade800,
        ),
      ),
    );
  }
}

class _TodayStatusCard extends StatefulWidget {
  final bool isDark;
  const _TodayStatusCard({required this.isDark});

  @override
  State<_TodayStatusCard> createState() => _TodayStatusCardState();
}

class _TodayStatusCardState extends State<_TodayStatusCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _cardController;
  late Animation<double> _fadeAnim;
  late Animation<double> _scaleAnim;

  bool _isPresentToday = false;
  bool _isLoading = true;
  String _markedAtTime = '';
  bool _isPastCutoff = false;
  bool _usedCache = false;

  @override
  void initState() {
    super.initState();
    _cardController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _fadeAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _cardController, curve: Curves.easeOut));

    _scaleAnim = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(
        parent: _cardController,
        curve: const Interval(0.1, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    // Restore from cache immediately — no loading flash
    if (_DashboardScreenState._cachedIsPresent != null) {
      _isPresentToday = _DashboardScreenState._cachedIsPresent!;
      _markedAtTime = _DashboardScreenState._cachedMarkedTime;
      _isPastCutoff = _DashboardScreenState._cachedIsPastCutoff;
      _isLoading = false;
      _usedCache = true;
      _cardController.forward();
    }

    _checkTodayAttendance();
  }

  @override
  void didUpdateWidget(covariant _TodayStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _cardController.reset();
    _checkTodayAttendance();
  }

  Future<void> _checkTodayAttendance() async {
    // Only show loading spinner on very first load (no cache)
    if (mounted && !_usedCache) setState(() => _isLoading = true);
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        final todayStr = DateTime.now().toIso8601String().split('T')[0];
        final now = DateTime.now();
        final cutoff = DateTime(now.year, now.month, now.day, 16, 0); // 4 PM

        final records = await supabase
            .from('college_attendance')
            .select('id, marked_at, status')
            .eq('student_id', user.id)
            .eq('date', todayStr)
            .order('marked_at', ascending: false)
            .limit(1);

        final record = records.isNotEmpty ? records.first : null;

        if (mounted) {
          String timeStr = '';
          if (record != null && record['marked_at'] != null) {
            final markedAt = DateTime.parse(record['marked_at']).toLocal();
            final hour = markedAt.hour;
            final minute = markedAt.minute.toString().padLeft(2, '0');
            final period = hour >= 12 ? 'PM' : 'AM';
            final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
            timeStr = '$displayHour:$minute $period';
          }

          setState(() {
            _isPresentToday = record != null && record['status'] == 'present';
            _markedAtTime = timeStr;
            _isPastCutoff = now.isAfter(cutoff);
            _isLoading = false;
          });

          // Update cache
          _DashboardScreenState._cachedIsPresent = _isPresentToday;
          _DashboardScreenState._cachedMarkedTime = _markedAtTime;
          _DashboardScreenState._cachedIsPastCutoff = _isPastCutoff;
          _usedCache = false;
          _cardController.forward();
        }
      }
    } catch (e) {
      debugPrint('Error checking today attendance: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _cardController.dispose();
    super.dispose();
  }

  Widget _buildCategoryTag(Color tagColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: tagColor.withValues(alpha: widget.isDark ? 0.20 : 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tagColor.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: tagColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4.5),
          Text(
            'COLLEGE ATTENDANCE',
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: tagColor,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: CircularProgressIndicator(),
        ),
      );
    }

    // Sunday — no college
    if (DateTime.now().weekday == 7) {
      final blueColor = AppStyles.primaryBlue;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: blueColor.withValues(alpha: widget.isDark ? 0.14 : 0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: blueColor.withValues(alpha: 0.28),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: blueColor.withValues(alpha: widget.isDark ? 0.12 : 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            _CampusStatusIconWidget(
              icon: Icons.weekend_rounded,
              color: blueColor,
              shouldPulse: false,
              isDark: widget.isDark,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCategoryTag(blueColor),
                  const SizedBox(height: 5),
                  Text(
                    'No College Today',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: widget.isDark ? Colors.white : AppStyles.textDark,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Today is Sunday — enjoy your day!',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: widget.isDark
                          ? Colors.white.withValues(alpha: 0.7)
                          : AppStyles.textDark.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final Color color = _isPresentToday
        ? AppStyles.successGreen
        : (!_isPresentToday && _isPastCutoff)
        ? const Color(0xFFEF4444)
        : AppStyles.amberWarning;

    final String message = _isPresentToday
        ? 'You are Present Today'
        : (!_isPresentToday && _isPastCutoff)
        ? 'Absent Today'
        : 'Not Yet Marked';

    final IconData iconData = _isPresentToday
        ? Icons.verified_user_rounded
        : (!_isPresentToday && _isPastCutoff)
        ? Icons.event_busy_rounded
        : Icons.access_time_filled_rounded;

    final String subtitle = _isPresentToday
        ? 'Marked at $_markedAtTime'
        : (!_isPresentToday && _isPastCutoff)
        ? 'Attendance closed for today'
        : 'College hours end at 4:00 PM';

    final bool shouldPulse = !_isPresentToday;

    return AnimatedBuilder(
      animation: _cardController,
      builder: (context, child) {
        return Opacity(
          opacity: _fadeAnim.value,
          child: Transform.scale(
            scale: _scaleAnim.value,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - _fadeAnim.value)),
              child: child,
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: widget.isDark ? 0.14 : 0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.28), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: widget.isDark ? 0.14 : 0.07),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            _CampusStatusIconWidget(
              icon: iconData,
              color: color,
              shouldPulse: shouldPulse,
              isDark: widget.isDark,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCategoryTag(color),
                  const SizedBox(height: 5),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: widget.isDark ? Colors.white : AppStyles.textDark,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: widget.isDark
                          ? Colors.white.withValues(alpha: 0.7)
                          : AppStyles.textDark.withValues(alpha: 0.6),
                    ),
                  ),
                  if (_isPresentToday) ...[
                    const SizedBox(height: 8),
                    _AnimatedFaceVerifiedBadge(color: color),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CampusStatusIconWidget extends StatefulWidget {
  final IconData icon;
  final Color color;
  final bool shouldPulse;
  final bool shouldSpin;
  final bool isDark;

  const _CampusStatusIconWidget({
    required this.icon,
    required this.color,
    this.shouldPulse = false,
    this.shouldSpin = false,
    required this.isDark,
  });

  @override
  State<_CampusStatusIconWidget> createState() =>
      _CampusStatusIconWidgetState();
}

class _CampusStatusIconWidgetState extends State<_CampusStatusIconWidget>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _glowAnimation;

  AnimationController? _spinController;
  Animation<double>? _spinAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _glowAnimation = Tween<double>(begin: 2.0, end: 7.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    if (widget.shouldPulse) {
      _pulseController.repeat(reverse: true);
    }

    if (widget.shouldSpin) {
      _initSpinController();
    }
  }

  void _initSpinController() {
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
    _spinAnimation = TweenSequence<double>([
      // Pause upright while sand drops
      TweenSequenceItem(tween: ConstantTween<double>(0.0), weight: 35),
      // Rotate 180 degrees (0.5 turns)
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.0,
          end: 0.5,
        ).chain(CurveTween(curve: Curves.easeInOutBack)),
        weight: 25,
      ),
      // Pause upside down
      TweenSequenceItem(tween: ConstantTween<double>(0.5), weight: 35),
      // Rotate back to 360 degrees (1.0 turn)
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.5,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOutBack)),
        weight: 25,
      ),
    ]).animate(_spinController!);
  }

  @override
  void didUpdateWidget(covariant _CampusStatusIconWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldPulse && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.shouldPulse && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }

    if (widget.shouldSpin && _spinController == null) {
      _initSpinController();
    } else if (!widget.shouldSpin && _spinController != null) {
      _spinController?.dispose();
      _spinController = null;
      _spinAnimation = null;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _spinController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final scale = widget.shouldPulse ? _scaleAnimation.value : 1.0;
        final glow = widget.shouldPulse ? _glowAnimation.value : 3.0;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [widget.color, widget.color.withValues(alpha: 0.82)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(
                    alpha: widget.isDark ? 0.35 : 0.22,
                  ),
                  blurRadius: glow * 1.6,
                  spreadRadius: glow * 0.2,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Center(
              child: _spinAnimation != null
                  ? RotationTransition(
                      turns: _spinAnimation!,
                      child: Icon(widget.icon, color: Colors.white, size: 24),
                    )
                  : Icon(widget.icon, color: Colors.white, size: 24),
            ),
          ),
        );
      },
    );
  }
}

class _PeriodStatusIconWidget extends StatefulWidget {
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final bool isDark;
  final bool isSuccess;

  const _PeriodStatusIconWidget({
    required this.icon,
    required this.primaryColor,
    required this.secondaryColor,
    required this.isDark,
    this.isSuccess = true,
  });

  @override
  State<_PeriodStatusIconWidget> createState() =>
      _PeriodStatusIconWidgetState();
}

class _PeriodStatusIconWidgetState extends State<_PeriodStatusIconWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: 1.07,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.07,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 50,
      ),
    ]).animate(_animController);

    _glowAnimation = Tween<double>(begin: 3.0, end: 9.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );

    _animController.repeat();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animController,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [widget.primaryColor, widget.secondaryColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(15),
              boxShadow: [
                BoxShadow(
                  color: widget.primaryColor.withValues(
                    alpha: widget.isDark ? 0.40 : 0.28,
                  ),
                  blurRadius: _glowAnimation.value * 1.5,
                  spreadRadius: _glowAnimation.value * 0.15,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Center(
              child: Icon(widget.icon, color: Colors.white, size: 24),
            ),
          ),
        );
      },
    );
  }
}

class _AttendancePercentageCard extends StatefulWidget {
  final ThemeData theme;
  final bool isDark;
  const _AttendancePercentageCard({required this.theme, required this.isDark});

  @override
  State<_AttendancePercentageCard> createState() =>
      _AttendancePercentageCardState();
}

class _AttendancePercentageCardState extends State<_AttendancePercentageCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _progressAnim;
  late Animation<int> _counterAnim;

  double _pct = 0.0;
  int _present = 0;
  int _total = 0;
  bool _isLoading = true;
  bool _usedCache = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (_DashboardScreenState._cachedPct >= 0) {
      _pct = _DashboardScreenState._cachedPct;
      _present = _DashboardScreenState._cachedPresent;
      _total = _DashboardScreenState._cachedTotal;
      _isLoading = false;
      _usedCache = true;
      _progressAnim = Tween<double>(
        begin: _pct,
        end: _pct,
      ).animate(_controller);
      _counterAnim = IntTween(
        begin: (_pct * 100).round(),
        end: (_pct * 100).round(),
      ).animate(_controller);
    }
    _fetchAttendanceStats();
  }

  @override
  void didUpdateWidget(covariant _AttendancePercentageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    debugPrint('[DASH_PCT] didUpdateWidget called — re-fetching stats');
    // Only reset animation if data actually changed
    if (!_usedCache) _controller.reset();
    _fetchAttendanceStats();
  }

  Future<void> _fetchAttendanceStats() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        debugPrint(
          '[DASH_PCT] _fetchAttendanceStats called for user: ${user.id}',
        );
        // Get student's class_id first
        final studentData = await supabase
            .from('students')
            .select('class_id')
            .eq('id', user.id)
            .maybeSingle();

        if (studentData == null) {
          debugPrint('[DASH_PCT] No student record found');
          if (mounted) setState(() => _isLoading = false);
          return;
        }

        final classId = studentData['class_id'] as String;
        debugPrint('[DASH_PCT] Student class_id: $classId');

        // Only count attendance from finalized sessions for this student's class
        final sessions = await supabase
            .from('attendance_sessions')
            .select('id')
            .eq('status', 'finalized')
            .eq('class_id', classId);

        final finalizedIds = (sessions as List)
            .map((s) => s['id'] as String)
            .toList();

        debugPrint('[DASH_PCT] Finalized session IDs: $finalizedIds');

        if (finalizedIds.isEmpty) {
          if (mounted) {
            setState(() {
              _total = 0;
              _present = 0;
              _pct = 0.0;
              _isLoading = false;
            });
            _progressAnim = Tween<double>(
              begin: 0,
              end: 0,
            ).animate(_controller);
            _counterAnim = IntTween(begin: 0, end: 0).animate(_controller);

            _DashboardScreenState._cachedPct = _pct;
            _DashboardScreenState._cachedPresent = _present;
            _DashboardScreenState._cachedTotal = _total;
            _usedCache = false;

            _controller.forward();
          }
          return;
        }

        final records = await supabase
            .from('period_attendance')
            .select('status, face_verified')
            .eq('student_id', user.id)
            .inFilter('session_id', finalizedIds)
            .inFilter('status', ['present', 'absent']);

        int total = records.length;
        int present = records
            .where(
              (r) => r['status'] == 'present' && (r['face_verified'] == true),
            )
            .length;
        double pct = total > 0 ? present / total : 0.0;
        debugPrint('[DASH_PCT] total=$total present=$present pct=$pct');

        if (mounted) {
          setState(() {
            _total = total;
            _present = present;
            _pct = pct;
            _isLoading = false;
          });

          _progressAnim = Tween<double>(begin: 0, end: _pct).animate(
            CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
          );

          _counterAnim = IntTween(begin: 0, end: (_pct * 100).round()).animate(
            CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
          );

          _DashboardScreenState._cachedPct = _pct;
          _DashboardScreenState._cachedPresent = _present;
          _DashboardScreenState._cachedTotal = _total;
          _usedCache = false;

          _controller.forward();
        }
      }
    } catch (e) {
      debugPrint('Error fetching attendance stats: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = widget.isDark;
    final Color pctColor = _pct >= 0.75
        ? AppStyles.successGreen
        : _pct >= 0.60
        ? AppStyles.amberWarning
        : AppStyles.errorRed;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 26, 20),
      decoration: BoxDecoration(
        color: (theme.cardTheme.color ?? Colors.white).withValues(alpha: 0.96),
        border: Border.all(
          color:
              (_pct >= 0.75
                      ? Colors.indigo.shade400
                      : _pct >= 0.60
                      ? AppStyles.amberWarning
                      : AppStyles.errorRed)
                  .withValues(alpha: isDark ? 0.55 : 0.45),
          width: 2.5,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color:
                (_pct >= 0.75
                        ? Colors.indigo.shade400
                        : _pct >= 0.60
                        ? AppStyles.amberWarning
                        : AppStyles.errorRed)
                    .withValues(alpha: isDark ? 0.15 : 0.10),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color:
                (_pct >= 0.75
                        ? Colors.indigo.shade400
                        : _pct >= 0.60
                        ? AppStyles.amberWarning
                        : AppStyles.errorRed)
                    .withValues(alpha: isDark ? 0.05 : 0.03),
            blurRadius: 4,
            offset: const Offset(0, 2),
            spreadRadius: 1,
          ),
        ],
      ),
      child: _isLoading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(20.0),
                child: CircularProgressIndicator(),
              ),
            )
          : Row(
              children: [
                AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    return SizedBox(
                      width: 100,
                      height: 100,
                      child: CustomPaint(
                        painter: _ArcPainter(
                          progress: _progressAnim.value,
                          isDark: isDark,
                          color: pctColor,
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              RichText(
                                text: TextSpan(
                                  children: [
                                    TextSpan(
                                      text: '${_counterAnim.value}',
                                      style: TextStyle(
                                        fontSize: 26,
                                        fontWeight: FontWeight.w800,
                                        color: pctColor,
                                        letterSpacing: -1,
                                        height: 1,
                                      ),
                                    ),
                                    TextSpan(
                                      text: '%',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: pctColor.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                'Overall',
                                style: TextStyle(
                                  fontSize: 10,
                                  color:
                                      theme.textTheme.bodyMedium?.color ??
                                      AppStyles.textGray,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Attendance',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color:
                              theme.textTheme.bodyMedium?.color ??
                              AppStyles.textGray,
                        ),
                      ),
                      const SizedBox(height: 6),
                      RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: '$_present',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color:
                                    theme.textTheme.displayLarge?.color ??
                                    AppStyles.textDark,
                                letterSpacing: -0.5,
                              ),
                            ),
                            TextSpan(
                              text: ' / $_total',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color:
                                    theme.textTheme.bodyMedium?.color ??
                                    AppStyles.textGray,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        'Classes Attended',
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              theme.textTheme.bodyMedium?.color ??
                              AppStyles.textGray,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: pctColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.trending_up_rounded,
                              size: 13,
                              color: pctColor,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                _pct >= 0.75
                                    ? 'Good Standing — Above 75%'
                                    : _pct >= 0.60
                                    ? 'Condonation Risk — 60–74%'
                                    : 'Detained Risk — Below 60%',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: pctColor,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  final double progress;
  final bool isDark;
  final Color color;
  const _ArcPainter({
    required this.progress,
    required this.isDark,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 16) / 2;

    final trackPaint = Paint()
      ..color = isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    const startAngle = -math.pi / 2;
    const fullSweep = 2 * math.pi;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      fullSweep,
      false,
      trackPaint,
    );

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      fullSweep * progress,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) => old.progress != progress;
}

class _HeroAttendanceCard extends StatefulWidget {
  final ThemeData theme;
  const _HeroAttendanceCard({required this.theme});

  @override
  State<_HeroAttendanceCard> createState() => _HeroAttendanceCardState();
}

class _HeroAttendanceCardState extends State<_HeroAttendanceCard> {
  String _timeDisplay = '--:-- --';
  String _dateDisplay = 'No attendance yet';
  bool _isLoading = true;
  bool _usedCache = false;

  @override
  void initState() {
    super.initState();
    if (_DashboardScreenState._cachedTimeDisplay != '--:-- --') {
      _timeDisplay = _DashboardScreenState._cachedTimeDisplay;
      _dateDisplay = _DashboardScreenState._cachedDateDisplay;
      _isLoading = false;
      _usedCache = true;
    }
    _fetchLastAttendance();
  }

  @override
  void didUpdateWidget(covariant _HeroAttendanceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only re-fetch if data has never loaded, not on every rebuild
    if (_isLoading) _fetchLastAttendance();
  }

  Future<void> _fetchLastAttendance() async {
    if (mounted && !_usedCache) setState(() => _isLoading = true);
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      final records = await supabase
          .from('college_attendance')
          .select('date, marked_at, status')
          .eq('student_id', user.id)
          .eq('status', 'present')
          .order('marked_at', ascending: false)
          .limit(1);

      final record = records.isNotEmpty ? records.first : null;

      if (record != null && mounted) {
        final markedAt = DateTime.parse(record['marked_at']).toLocal();
        final hour = markedAt.hour;
        final minute = markedAt.minute.toString().padLeft(2, '0');
        final period = hour >= 12 ? 'PM' : 'AM';
        final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
        final timeStr = '$displayHour:$minute $period';

        final date = DateTime.parse(record['date']);
        final months = [
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ];
        final dateStr =
            '${months[date.month - 1]} ${date.day}, ${date.year} \u2022 Present';

        if (mounted) {
          setState(() {
            _timeDisplay = timeStr;
            _dateDisplay = dateStr;
            _isLoading = false;
          });
          _DashboardScreenState._cachedTimeDisplay = _timeDisplay;
          _DashboardScreenState._cachedDateDisplay = _dateDisplay;
          _usedCache = false;
        }
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('Error fetching last attendance: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
      decoration: BoxDecoration(
        color: widget.theme.primaryColor,
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            widget.theme.primaryColor,
            widget.theme.primaryColor.withValues(alpha: 0.75),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: widget.theme.primaryColor.withValues(
              alpha: isDark ? 0.3 : 0.25,
            ),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.access_time_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Last Attendance',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _isLoading ? '--:-- --' : _timeDisplay,
            style: const TextStyle(
              fontSize: 42,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _isLoading ? 'Loading...' : _dateDisplay,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.white70,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExpandableScheduleSection extends StatefulWidget {
  final bool isDark;
  final ThemeData theme;
  final bool isExpanded;
  final VoidCallback onToggle;

  const _ExpandableScheduleSection({
    required this.isDark,
    required this.theme,
    required this.isExpanded,
    required this.onToggle,
  });

  @override
  State<_ExpandableScheduleSection> createState() =>
      _ExpandableScheduleSectionState();
}

class _ExpandableScheduleSectionState extends State<_ExpandableScheduleSection>
    with SingleTickerProviderStateMixin {
  late AnimationController _expandController;
  late Animation<double> _expandAnimation;
  late Animation<double> _rotateAnimation;

  List<Map<String, dynamic>> _scheduleItems = [];
  bool _scheduleLoading = true;
  RealtimeChannel? _scheduleChannel;
  RealtimeChannel? _attendanceChannel;

  Future<void> _fetchSchedule() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      // Get student's class_id
      final studentData = await supabase
          .from('students')
          .select('class_id')
          .eq('id', user.id)
          .maybeSingle();
      if (studentData == null) {
        if (mounted) {
          setState(() {
            _scheduleItems = [];
            _scheduleLoading = false;
          });
        }
        return;
      }
      final classId = studentData['class_id'] as String;

      // Get today's day_of_week (Mon=1 ... Sat=6, Sun=null)
      final jsDay = DateTime.now().weekday; // Mon=1 ... Sun=7
      int todayDow = jsDay == 7 ? 1 : jsDay; // Sunday → show Monday

      // Fetch timetable for this class and today's day, ordered by period
      final timetableRows = await supabase
          .from('timetables')
          .select('''
            subject_id,
            teacher_id,
            period_id,
            subject:subjects ( name ),
            period:periods ( period_number, start_time, end_time ),
            teachers ( id, title )
          ''')
          .eq('class_id', classId)
          .eq('day_of_week', todayDow)
          .order('period_id');

      if ((timetableRows as List).isEmpty) {
        if (mounted) {
          setState(() {
            _scheduleItems = [];
            _scheduleLoading = false;
          });
        }
        return;
      }

      // Fetch teacher full names from users table
      final teacherIds = timetableRows
          .map((r) => r['teacher_id'] as String?)
          .where((id) => id != null)
          .cast<String>()
          .toSet()
          .toList();
      final Map<String, String> teacherFullNames = {};
      final Map<String, String> teacherTitles = {};
      if (teacherIds.isNotEmpty) {
        final teacherData = await supabase.rpc(
          'get_teacher_names',
          params: {'teacher_ids': teacherIds},
        );
        for (final t in (teacherData as List)) {
          final id = t['id'] as String?;
          final name = t['full_name'] as String?;
          final title = t['title'] as String? ?? 'Mr';
          if (id != null) {
            teacherFullNames[id] = name ?? '';
            teacherTitles[id] = title;
          }
        }
      }

      // Fetch today's attendance sessions for this class safely
      final Map<String, Map<String, dynamic>> sessionMap = {};
      try {
        final today = DateTime.now().toIso8601String().split('T')[0];
        final todaySessions = await supabase
            .from('attendance_sessions')
            .select(
              'id, subject_id, period_id, status, opened_at, finalized_at',
            )
            .eq('class_id', classId)
            .eq('session_date', today);

        // Group sessions by composite key: "$subjectId|$periodId"
        // Pick the most recent session for that exact period/date (Req 7 & Req 8)
        for (final s in (todaySessions as List)) {
          final subjectId = s['subject_id'] as String?;
          final periodId = s['period_id'] as String?;
          if (subjectId == null || periodId == null) continue;
          final key = '$subjectId|$periodId';

          final existing = sessionMap[key];
          if (existing == null) {
            sessionMap[key] = Map<String, dynamic>.from(s);
          } else {
            // Compare authoritative timestamps (finalized_at, opened_at)
            final existingTime =
                (existing['finalized_at'] ?? existing['opened_at'] ?? '')
                    as String;
            final newTime =
                (s['finalized_at'] ?? s['opened_at'] ?? '') as String;
            if (newTime.compareTo(existingTime) >= 0) {
              sessionMap[key] = Map<String, dynamic>.from(s);
            }
          }
        }
      } catch (e) {
        debugPrint('[SCHEDULE] Failed to fetch attendance_sessions: $e');
      }

      // Fetch student's period_attendance for today's selected sessions safely
      final Map<String, Map<String, dynamic>> studentAttendance = {};
      final todaySessionIds = sessionMap.values
          .map((s) => s['id'] as String?)
          .where((id) => id != null)
          .cast<String>()
          .toList();
      if (todaySessionIds.isNotEmpty) {
        try {
          final pa = await supabase
              .from('period_attendance')
              .select('session_id, status, face_verified, override_by_teacher')
              .eq('student_id', user.id)
              .inFilter('session_id', todaySessionIds);
          for (final a in (pa as List)) {
            final sId = a['session_id'] as String?;
            if (sId != null) {
              studentAttendance[sId] = Map<String, dynamic>.from(a);
            }
          }
        } catch (e) {
          debugPrint('[SCHEDULE] Failed to fetch period_attendance: $e');
        }
      }

      // Build schedule items in period order
      // Sort by period_number ascending
      final sortedRows = List.from(timetableRows)
        ..sort((a, b) {
          final aN = (a['period'] as Map?)?['period_number'] as int? ?? 0;
          final bN = (b['period'] as Map?)?['period_number'] as int? ?? 0;
          return aN.compareTo(bN);
        });

      int parseTimeToMinutes(String timeStr) {
        try {
          final parts = timeStr.split(':');
          return int.parse(parts[0]) * 60 + int.parse(parts[1]);
        } catch (_) {
          return 0;
        }
      }

      final now = DateTime.now();
      final nowMinutes = (now.hour < 7) ? 0 : (now.hour * 60 + now.minute);
      final isSunday = now.weekday == 7;

      final List<Map<String, dynamic>> items = [];
      for (final row in sortedRows) {
        final subjectId = row['subject_id'] as String;
        final periodId = row['period_id'] as String;
        final teacherId = row['teacher_id'] as String?;
        final subjectName =
            (row['subject'] as Map?)?['name'] as String? ?? 'Unknown';
        final periodNumber =
            (row['period'] as Map?)?['period_number'] as int? ?? 0;
        final rawStartTime =
            (row['period'] as Map?)?['start_time'] as String? ?? '00:00';
        final rawEndTime =
            (row['period'] as Map?)?['end_time'] as String? ?? '00:00';
        final startTime = rawStartTime.length >= 5
            ? rawStartTime.substring(0, 5)
            : rawStartTime;
        final endTime = rawEndTime.length >= 5
            ? rawEndTime.substring(0, 5)
            : rawEndTime;
        final title = teacherId != null
            ? (teacherTitles[teacherId] ?? 'Mr')
            : '';
        final fullName = teacherId != null
            ? (teacherFullNames[teacherId] ?? '')
            : '';
        final facultyName = fullName.isNotEmpty ? '$title. $fullName' : '';

        final key = '$subjectId|$periodId';
        final session = sessionMap[key];
        final sessionStatus = session?['status'] as String?;
        final sessionId = session?['id'] as String?;
        final attRecord = sessionId != null
            ? studentAttendance[sessionId]
            : null;
        final studentStatus = attRecord?['status'] as String?;

        final startMinutes = parseTimeToMinutes(rawStartTime);
        final endMinutes = parseTimeToMinutes(rawEndTime);

        String cardStatus;
        // Priority 1: Actual student record exists and status == 'present' (regardless of face_verified)
        if (studentStatus == 'present') {
          cardStatus = 'done';
        }
        // Priority 2: Actual student record exists and status == 'absent'
        else if (studentStatus == 'absent') {
          cardStatus = 'absent';
        }
        // Priority 3: No student attendance record AND matching session is active or reviewing
        else if (sessionStatus == 'active' || sessionStatus == 'reviewing') {
          cardStatus = 'current';
        }
        // Priority 4: No student attendance record AND period has not started yet
        else if (isSunday || (now.hour < 7) || nowMinutes < startMinutes) {
          cardStatus = 'upcoming';
        }
        // Priority 5: No student attendance record AND scheduled period has already ended
        else if (nowMinutes > endMinutes || sessionStatus == 'finalized') {
          cardStatus = 'not_recorded';
        }
        // Ongoing time window without an active session
        else {
          cardStatus = 'upcoming';
        }

        items.add({
          'subject': subjectName,
          'teacher': facultyName,
          'periodNumber': periodNumber,
          'startTime': startTime,
          'endTime': endTime,
          'status': cardStatus,
        });
      }

      // Resubscribe realtime channel for this class
      _scheduleChannel?.unsubscribe();
      _scheduleChannel = supabase
          .channel('schedule_class_$classId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'attendance_sessions',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'class_id',
              value: classId,
            ),
            callback: (payload) {
              if (mounted) _fetchSchedule();
            },
          )
          .subscribe();

      // Subscribe to period_attendance changes for this student
      _attendanceChannel?.unsubscribe();
      _attendanceChannel = supabase
          .channel('schedule_attendance_${user.id}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'period_attendance',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'student_id',
              value: user.id,
            ),
            callback: (payload) {
              if (mounted) _fetchSchedule();
            },
          )
          .subscribe();

      if (mounted) {
        setState(() {
          _scheduleItems = items;
          _scheduleLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[SCHEDULE] error: $e');
      if (mounted) setState(() => _scheduleLoading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _fetchSchedule();
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _expandAnimation = CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeOutCubic,
    );
    _rotateAnimation = Tween<double>(begin: 0, end: 0.5).animate(
      CurvedAnimation(parent: _expandController, curve: Curves.easeOutCubic),
    );
  }

  @override
  void didUpdateWidget(covariant _ExpandableScheduleSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExpanded != oldWidget.isExpanded) {
      if (widget.isExpanded) {
        _expandController.forward();
      } else {
        _expandController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _scheduleChannel?.unsubscribe();
    _attendanceChannel?.unsubscribe();
    _expandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = widget.isDark;

    return Column(
      children: [
        // Header — always visible, tappable
        GestureDetector(
          onTap: widget.onToggle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: theme.cardTheme.color ?? Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.calendar_today_rounded,
                    color: theme.primaryColor,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Today's Schedule",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color:
                              theme.textTheme.displayLarge?.color ??
                              AppStyles.textDark,
                        ),
                      ),
                      Text(
                        widget.isExpanded
                            ? '${_scheduleItems.length} subject${_scheduleItems.length != 1 ? 's' : ''} — ${DateTime.now().weekday == 7 ? 'Tomorrow (Mon)' : 'Today'}'
                            : DateTime.now().weekday == 7
                            ? 'Showing tomorrow\'s schedule'
                            : 'Tap to view your classes',
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              theme.textTheme.bodyMedium?.color ??
                              AppStyles.textGray,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                RotationTransition(
                  turns: _rotateAnimation,
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color:
                        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
                    size: 24,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Expandable content
        SizeTransition(
          sizeFactor: _expandAnimation,
          child: FadeTransition(
            opacity: _expandAnimation,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: widget.theme.cardTheme.color ?? Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: widget.isDark ? 0.2 : 0.05,
                      ),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: SizedBox(
                  height: 138,
                  child: _scheduleLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _scheduleItems.isEmpty
                      ? Center(
                          child: Text(
                            'No subjects assigned',
                            style: TextStyle(
                              color:
                                  widget.theme.textTheme.bodyMedium?.color ??
                                  AppStyles.textGray,
                            ),
                          ),
                        )
                      : ListView.separated(
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          itemCount: _scheduleItems.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final item = _scheduleItems[index];
                            final status = item['status'] as String;
                            final bool isDone = status == 'done';
                            final bool isCurrent = status == 'current';
                            final bool isAbsent = status == 'absent';
                            final bool isNotRecorded = status == 'not_recorded';
                            final int periodNum =
                                item['periodNumber'] as int? ?? 0;
                            final String startTime =
                                item['startTime'] as String? ?? '';
                            final String endTime =
                                item['endTime'] as String? ?? '';
                            final theme = widget.theme;
                            final isDark = widget.isDark;

                            return _ScheduleCard(
                              item: item,
                              isCurrent: isCurrent,
                              isDone: isDone,
                              isAbsent: isAbsent,
                              isNotRecorded: isNotRecorded,
                              periodNum: periodNum,
                              startTime: startTime,
                              endTime: endTime,
                              theme: theme,
                              isDark: isDark,
                              index: index,
                            );
                          },
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AttendanceBanner extends StatefulWidget {
  final VoidCallback? onSessionFinalized;
  final void Function(String subject, String period)? onTeacherFinalized;
  final void Function(String subject, String period)? onTeacherFinalizedAbsent;
  final VoidCallback? onNewSession;
  final VoidCallback? onClearFinalized;
  final bool teacherFinalized;
  final String finalizedSubject;
  final String finalizedPeriod;
  final bool teacherFinalizedAbsent;
  final String absentSubject;
  final String absentPeriod;

  const _AttendanceBanner({
    this.onSessionFinalized,
    this.onTeacherFinalized,
    this.onTeacherFinalizedAbsent,
    this.onNewSession,
    this.onClearFinalized,
    this.teacherFinalized = false,
    this.finalizedSubject = '',
    this.finalizedPeriod = '',
    this.teacherFinalizedAbsent = false,
    this.absentSubject = '',
    this.absentPeriod = '',
  });

  @override
  State<_AttendanceBanner> createState() => _AttendanceBannerState();
}

class _AttendanceBannerState extends State<_AttendanceBanner>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  VoidCallback? get _onSessionFinalized => widget.onSessionFinalized;

  int _secondsRemaining = 0;
  DateTime? _sessionDeadline;
  bool _isSyncing = false;
  Timer? _countdownTimer;
  String? _activeSessionId;
  bool _isVisible = false;
  bool _isClosed = false;
  bool _ctaPressed = false;
  bool _hasMarkedAttendance = false;

  // Timer pill pulse
  late AnimationController _timerPulseController;
  late Animation<double> _timerPulseAnim;

  String _subjectName = '';
  String _periodInfo = '';
  String _periodTiming = '';
  // ignore: unused_field
  String _teacherName = '';
  // ignore: unused_field
  DateTime? _qrTokenExpiresAt;

  RealtimeChannel? _subscription;
  RealtimeChannel? _attendanceSubscription;
  String? _userClassId;
  Timer? _pollingTimer;
  Timer? _finalizationPollingTimer;

  int _calculateRemainingSeconds() {
    if (_sessionDeadline == null) return 0;
    final remaining = _sessionDeadline!
        .difference(DateTime.now().toUtc())
        .inSeconds;
    return math.max(0, remaining);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timerPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _timerPulseAnim = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _timerPulseController, curve: Curves.easeInOut),
    );

    _initRealtimeSubscription();
    _startPolling();
  }

  Future<void> _initRealtimeSubscription() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      // 1. Fetch user's class_id
      final studentData = await supabase
          .from('students')
          .select('class_id')
          .eq('id', user.id)
          .maybeSingle();

      if (studentData == null) return;
      _userClassId = studentData['class_id'] as String;
      debugPrint('AttendanceBanner: Fetched user class_id = $_userClassId');

      // 2. Initial authoritative state sync
      _syncAttendanceState();

      // 3. Subscribe to period_attendance for this student
      _attendanceSubscription = supabase
          .channel('public:period_attendance:student_${user.id}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'period_attendance',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'student_id',
              value: user.id,
            ),
            callback: (payload) {
              final newRecord = payload.newRecord;
              final recordSessionId = newRecord['session_id'] as String?;
              debugPrint(
                '[BANNER] period_attendance event: sessionId=$recordSessionId',
              );
              if (mounted) {
                _syncAttendanceState(
                  targetSessionId: recordSessionId ?? _activeSessionId,
                );
              }
            },
          )
          .subscribe();

      // 4. Unified channel for attendance_sessions for student's class
      _subscription = supabase
          .channel('attendance_sessions_class_$_userClassId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'attendance_sessions',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'class_id',
              value: _userClassId!,
            ),
            callback: (payload) {
              final newRecord = payload.newRecord;
              final status = newRecord['status'] as String?;
              final sessionId = newRecord['id'] as String?;

              debugPrint(
                '[BANNER] attendance_sessions event: status=$status sessionId=$sessionId',
              );

              if (mounted) {
                _syncAttendanceState(targetSessionId: sessionId);
              }
            },
          )
          .subscribe((status, [error]) {
            debugPrint('[BANNER] Unified channel status: $status error=$error');
          });

      // 5. Polling fallback
      _startFinalizationPolling();
    } catch (e) {
      debugPrint('Error initializing realtime: $e');
    }
  }

  Future<void> _fetchSessionMetadata(Map<String, dynamic> sessionData) async {
    final subjectId = sessionData['subject_id'];
    final periodId = sessionData['period_id'];
    final teacherId = sessionData['teacher_id'];

    try {
      final futures = <Future<dynamic>>[];
      if (subjectId != null) {
        futures.add(
          supabase
              .from('subjects')
              .select('name')
              .eq('id', subjectId)
              .maybeSingle(),
        );
      } else {
        futures.add(Future.value(null));
      }

      if (periodId != null) {
        futures.add(
          supabase
              .from('periods')
              .select('period_number, start_time, end_time')
              .eq('id', periodId)
              .maybeSingle(),
        );
      } else {
        futures.add(Future.value(null));
      }

      if (teacherId != null) {
        futures.add(
          supabase
              .from('teachers')
              .select('id')
              .eq('id', teacherId)
              .maybeSingle()
              .then((t) async {
                if (t != null) {
                  return await supabase
                      .from('users')
                      .select('full_name')
                      .eq('id', teacherId)
                      .maybeSingle();
                }
                return null;
              }),
        );
      } else {
        futures.add(Future.value(null));
      }

      final results = await Future.wait(futures);
      final subjectData = results[0] as Map<String, dynamic>?;
      final periodData = results[1] as Map<String, dynamic>?;
      final teacherData = results[2] as Map<String, dynamic>?;

      if (subjectData != null && subjectData['name'] != null) {
        _subjectName = subjectData['name'] as String? ?? 'Unknown Subject';
      }

      if (periodData != null) {
        final int periodNum = periodData['period_number'] as int? ?? 1;

        String getOrdinal(int n) {
          if (n >= 11 && n <= 13) return 'th';
          switch (n % 10) {
            case 1:
              return 'st';
            case 2:
              return 'nd';
            case 3:
              return 'rd';
            default:
              return 'th';
          }
        }

        _periodInfo = '$periodNum${getOrdinal(periodNum)} Period';

        final rawStart = periodData['start_time'] as String? ?? '';
        final rawEnd = periodData['end_time'] as String? ?? '';
        if (rawStart.isNotEmpty && rawEnd.isNotEmpty) {
          final s = rawStart.length >= 5 ? rawStart.substring(0, 5) : rawStart;
          final e = rawEnd.length >= 5 ? rawEnd.substring(0, 5) : rawEnd;
          _periodTiming = '$s - $e';
        }
      }

      if (teacherData != null && teacherData['full_name'] != null) {
        _teacherName = teacherData['full_name'] as String? ?? 'Unknown Teacher';
      }
    } catch (e) {
      debugPrint('[BANNER] Error fetching session metadata: $e');
    }
  }

  bool _isConfirmationDisplayValid(Map<String, dynamic> sessionData) {
    final now = DateTime.now();
    final todayStr =
        "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

    final sessionDate = sessionData['session_date'] as String?;
    final finalizedAtStr =
        (sessionData['finalized_at'] ?? sessionData['opened_at']) as String?;

    // Period confirmation is strictly for TODAY
    if (sessionDate != null && sessionDate != todayStr) {
      return false;
    }

    if (finalizedAtStr == null || finalizedAtStr.isEmpty) {
      return true;
    }

    try {
      final finalizedTime = DateTime.parse(finalizedAtStr).toLocal();
      if (finalizedTime.year != now.year ||
          finalizedTime.month != now.month ||
          finalizedTime.day != now.day) {
        return false;
      }

      final finalizedHour = finalizedTime.hour;
      final isNormalClassHours = finalizedHour >= 7 && finalizedHour < 18;

      if (isNormalClassHours) {
        // Normal scheduled class-time attendance: remains visible throughout the day's attendance workflow
        final isCurrentTimeWithinDay = now.hour < 19;
        if (isCurrentTimeWithinDay) {
          return true;
        }
      }

      // Out-of-schedule / demo attendance (e.g. 10:30 PM): visible for ~10 minutes from finalization
      final diffMinutes = now.difference(finalizedTime).inMinutes.abs();
      return diffMinutes < 10;
    } catch (_) {
      return true;
    }
  }

  Future<void> _syncAttendanceState({String? targetSessionId}) async {
    if (_userClassId == null || !mounted || _isSyncing) return;
    _isSyncing = true;
    final user = supabase.auth.currentUser;
    if (user == null) {
      _isSyncing = false;
      return;
    }

    try {
      Map<String, dynamic>? currentSession;

      // 1. Always prioritize the latest ACTIVE or REVIEWING session for this class
      currentSession = await supabase
          .from('attendance_sessions')
          .select(
            'id, subject_id, period_id, teacher_id, current_qr_token, qr_token_expires_at, status, opened_at, finalized_at, session_date',
          )
          .eq('class_id', _userClassId!)
          .inFilter('status', ['active', 'reviewing'])
          .order('opened_at', ascending: false)
          .limit(1)
          .maybeSingle();

      // 2. If no active/reviewing session and targetSessionId provided, query it
      if (currentSession == null && targetSessionId != null) {
        currentSession = await supabase
            .from('attendance_sessions')
            .select(
              'id, subject_id, period_id, teacher_id, current_qr_token, qr_token_expires_at, status, opened_at, finalized_at, session_date',
            )
            .eq('id', targetSessionId)
            .eq('class_id', _userClassId!)
            .maybeSingle();
      }

      // 3. If still no active/reviewing session, look for today's finalized sessions for this class
      if (currentSession == null) {
        final today = DateTime.now().toIso8601String().split('T')[0];
        final finalizedSessions = await supabase
            .from('attendance_sessions')
            .select(
              'id, subject_id, period_id, teacher_id, current_qr_token, qr_token_expires_at, status, opened_at, finalized_at, session_date',
            )
            .eq('class_id', _userClassId!)
            .eq('status', 'finalized')
            .eq('session_date', today)
            .order('finalized_at', ascending: false)
            .limit(10);

        if ((finalizedSessions as List).isNotEmpty) {
          final sessionIds = finalizedSessions
              .map((s) => s['id'] as String)
              .toList();
          final userRecords = await supabase
              .from('period_attendance')
              .select('session_id, status, face_verified, override_by_teacher')
              .eq('student_id', user.id)
              .inFilter('session_id', sessionIds);

          final userRecordsBySession = <String, Map<String, dynamic>>{};
          for (final rec in (userRecords as List)) {
            final sId = rec['session_id'] as String?;
            if (sId != null) {
              userRecordsBySession[sId] = Map<String, dynamic>.from(rec);
            }
          }

          // Pick the latest finalized session where student actually has an attendance record
          for (final sess in finalizedSessions) {
            final sId = sess['id'] as String;
            if (userRecordsBySession.containsKey(sId)) {
              currentSession = sess;
              break;
            }
          }

          currentSession ??= finalizedSessions.first;
        }
      }

      if (!mounted) return;

      if (currentSession == null) {
        // No session exists for this class
        _sessionDeadline = null;
        if (!_hasMarkedAttendance &&
            !widget.teacherFinalized &&
            !widget.teacherFinalizedAbsent) {
          _closeBanner();
        }
        return;
      }

      final sessionId = currentSession['id'] as String;
      final sessionStatus = currentSession['status'] as String?;
      final openedAtStr = currentSession['opened_at'] as String?;

      // Query student's period_attendance record for THIS EXACT sessionId
      final attendanceRecord = await supabase
          .from('period_attendance')
          .select('status, face_verified, override_by_teacher')
          .eq('session_id', sessionId)
          .eq('student_id', user.id)
          .maybeSingle();

      final studentStatus = attendanceRecord?['status'] as String?;
      final faceVerified = attendanceRecord?['face_verified'] as bool? ?? false;
      final overrideByTeacher =
          attendanceRecord?['override_by_teacher'] as bool? ?? false;
      final bool isGenuineStudent =
          (studentStatus == 'present' && faceVerified && !overrideByTeacher);

      // Fetch metadata for subject and period
      await _fetchSessionMetadata(currentSession);
      if (!mounted) return;

      // ── EVALUATE AUTHORITATIVE LIFECYCLE ──

      // 1. ACTIVE SESSION
      if (sessionStatus == 'active') {
        final bool isNewSession =
            _activeSessionId != null && _activeSessionId != sessionId;

        if (openedAtStr != null) {
          try {
            final openedAt = DateTime.parse(openedAtStr).toUtc();
            _sessionDeadline = openedAt.add(const Duration(seconds: 180));
          } catch (_) {
            _sessionDeadline = null;
          }
        } else {
          _sessionDeadline = null;
        }

        final remainingSeconds = _calculateRemainingSeconds();

        if (isGenuineStudent) {
          // Submitted and verified -> waiting for teacher to finalize
          _sessionDeadline = null;
          _countdownTimer?.cancel();
          _pollingTimer?.cancel();
          _pollingTimer = null;
          _activeSessionId = sessionId;
          if (isNewSession) {
            widget.onNewSession?.call();
          }
          setState(() {
            _secondsRemaining = 0;
            _hasMarkedAttendance = true;
            _isVisible = true;
            _isClosed = false;
          });
        } else {
          // Not verified -> active QR scanning banner
          if (remainingSeconds > 0) {
            _activeSessionId = sessionId;
            if (isNewSession) {
              widget.onNewSession?.call();
            }
            setState(() {
              _secondsRemaining = remainingSeconds;
              _hasMarkedAttendance = false;
              _isClosed = false;
              _isVisible = true;
            });
            _startTimer();
          } else {
            _closeBanner();
          }
        }
      }
      // 2. REVIEWING SESSION
      else if (sessionStatus == 'reviewing') {
        final bool isNewSession =
            _activeSessionId != null && _activeSessionId != sessionId;
        if (isNewSession) {
          _hasMarkedAttendance = false;
          widget.onNewSession?.call();
        }
        _activeSessionId = sessionId;
        _sessionDeadline = null;
        _countdownTimer?.cancel();
        _pollingTimer?.cancel();
        _pollingTimer = null;

        if (_hasMarkedAttendance || isGenuineStudent) {
          // Case A: Student genuinely completed face verification -> keep showing waiting for teacher approval
          setState(() {
            _secondsRemaining = 0;
            _hasMarkedAttendance = true;
            _isVisible = true;
            _isClosed = false;
          });
        } else {
          // Case B: No successful student verification / unresolved / manual-only override
          // Keep neutral dashboard state (do not show result banner or waiting state)
          setState(() {
            _secondsRemaining = 0;
            _hasMarkedAttendance = false;
            _isClosed = false;
            _isVisible = false;
          });
        }
      }
      // 3. FINALIZED SESSION
      else if (sessionStatus == 'finalized') {
        _activeSessionId = sessionId;
        _sessionDeadline = null;
        _countdownTimer?.cancel();
        _pollingTimer?.cancel();
        _pollingTimer = null;

        final savedSubject = _subjectName.isNotEmpty
            ? _subjectName
            : widget.finalizedSubject;
        final savedPeriod = _periodInfo.isNotEmpty
            ? _periodInfo
            : widget.finalizedPeriod;

        final isDisplayValid = _isConfirmationDisplayValid(currentSession);

        if (studentStatus == 'present') {
          if (isDisplayValid) {
            setState(() {
              _secondsRemaining = 0;
              _hasMarkedAttendance = false;
              _isClosed = false;
              _isVisible = true;
            });
            debugPrint('[BANNER] Authoritative Finalized: Present');
            widget.onTeacherFinalized?.call(savedSubject, savedPeriod);
          } else {
            setState(() {
              _secondsRemaining = 0;
              _hasMarkedAttendance = false;
              _isClosed = false;
              _isVisible = false;
            });
            widget.onClearFinalized?.call();
          }
          _onSessionFinalized?.call();
        } else if (studentStatus == 'absent') {
          final absentSub = _subjectName.isNotEmpty
              ? _subjectName
              : widget.absentSubject;
          final absentPer = _periodInfo.isNotEmpty
              ? _periodInfo
              : widget.absentPeriod;
          if (isDisplayValid) {
            setState(() {
              _secondsRemaining = 0;
              _hasMarkedAttendance = false;
              _isClosed = false;
              _isVisible = true;
            });
            debugPrint(
              '[BANNER] Authoritative Finalized: Absent ($studentStatus)',
            );
            widget.onTeacherFinalizedAbsent?.call(absentSub, absentPer);
          } else {
            setState(() {
              _secondsRemaining = 0;
              _hasMarkedAttendance = false;
              _isClosed = false;
              _isVisible = false;
            });
            widget.onClearFinalized?.call();
          }
          _onSessionFinalized?.call();
        } else {
          // No record for this student in this finalized session -> do not fabricate absent
          setState(() {
            _secondsRemaining = 0;
            _hasMarkedAttendance = false;
            _isClosed = false;
            _isVisible = false;
          });
          widget.onClearFinalized?.call();
          _onSessionFinalized?.call();
        }
      }
    } catch (e) {
      debugPrint('[BANNER] Error syncing attendance state: $e');
    } finally {
      _isSyncing = false;
    }
  }

  void _startFinalizationPolling() {
    _finalizationPollingTimer?.cancel();
    _finalizationPollingTimer = Timer.periodic(const Duration(seconds: 10), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_userClassId == null) return;
      _syncAttendanceState();
    });
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted) return;
      if (!_hasMarkedAttendance &&
          !widget.teacherFinalized &&
          !widget.teacherFinalizedAbsent) {
        _syncAttendanceState();
      }
    });
  }

  void _startTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final remaining = _calculateRemainingSeconds();
      setState(() => _secondsRemaining = remaining);
      _timerPulseController.forward().then((_) {
        if (mounted) _timerPulseController.reverse();
      });
      if (remaining <= 0) {
        timer.cancel();
        _closeBanner();
      }
    });
  }

  void _closeBanner() {
    _activeSessionId = null;
    _sessionDeadline = null;
    _countdownTimer?.cancel();
    if (!mounted) return;
    setState(() => _isClosed = true);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _isVisible = false);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted) {
        final remaining = _calculateRemainingSeconds();
        setState(() => _secondsRemaining = remaining);
        if (_userClassId != null) {
          _syncAttendanceState();
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.unsubscribe();
    _attendanceSubscription?.unsubscribe();
    _pollingTimer?.cancel();
    _finalizationPollingTimer?.cancel();
    _countdownTimer?.cancel();
    _timerPulseController.dispose();
    super.dispose();
  }

  Widget _buildPeriodCategoryTag(Color tagColor, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: tagColor.withValues(alpha: isDark ? 0.20 : 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: tagColor.withValues(alpha: isDark ? 0.45 : 0.35),
          width: 0.9,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: tagColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4.5),
          Text(
            'PERIOD ATTENDANCE',
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: tagColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTwoToneTitle(
    String period,
    String subject,
    bool isDark, [
    Color? slashColor,
  ]) {
    final periodStr = period.trim();
    final subjectStr = subject.trim();
    final effectiveSlashColor =
        slashColor ??
        (isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB));

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          children: [
            if (periodStr.isNotEmpty) ...[
              TextSpan(
                text: periodStr,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF64748B),
                  letterSpacing: 0.1,
                ),
              ),
              if (subjectStr.isNotEmpty)
                TextSpan(
                  text: '  /  ',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: effectiveSlashColor.withValues(
                      alpha: isDark ? 0.85 : 0.70,
                    ),
                  ),
                ),
            ],
            if (subjectStr.isNotEmpty)
              TextSpan(
                text: subjectStr,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  letterSpacing: -0.2,
                ),
              ),
          ],
        ),
        maxLines: 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVisible &&
        !widget.teacherFinalized &&
        !widget.teacherFinalizedAbsent) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Teacher finalized — Electric Royal Blue/Indigo confirmed card (persists until next session)
    if (widget.teacherFinalized) {
      final periodText = widget.finalizedPeriod.isNotEmpty
          ? widget.finalizedPeriod
          : '';
      final subjectText = widget.finalizedSubject.isNotEmpty
          ? widget.finalizedSubject
          : 'Class Attendance';

      final primaryColor = const Color(0xFF2563EB); // Royal Blue
      final secondaryColor = const Color(0xFF4F46E5); // Deep Indigo
      final tagColor = isDark
          ? const Color(0xFF60A5FA)
          : const Color(0xFF2563EB);

      return Padding(
        padding: const EdgeInsets.only(bottom: 12.0, top: 4),
        child: TweenAnimationBuilder<double>(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          tween: Tween<double>(begin: 0.0, end: 1.0),
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: Transform.scale(
                scale: 0.95 + (0.05 * value),
                child: Transform.translate(
                  offset: Offset(0, 8 * (1 - value)),
                  child: child,
                ),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isDark
                    ? [
                        primaryColor.withValues(alpha: 0.16),
                        secondaryColor.withValues(alpha: 0.10),
                      ]
                    : [
                        primaryColor.withValues(alpha: 0.08),
                        secondaryColor.withValues(alpha: 0.05),
                      ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: tagColor.withValues(alpha: isDark ? 0.50 : 0.38),
                width: 1.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: primaryColor.withValues(alpha: isDark ? 0.16 : 0.07),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                _PeriodStatusIconWidget(
                  icon: Icons.task_alt_rounded,
                  primaryColor: primaryColor,
                  secondaryColor: secondaryColor,
                  isDark: isDark,
                  isSuccess: true,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPeriodCategoryTag(tagColor, isDark),
                      const SizedBox(height: 5),
                      _buildTwoToneTitle(
                        periodText,
                        subjectText,
                        isDark,
                        tagColor,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Attendance Confirmed',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: tagColor,
                          letterSpacing: 0.1,
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

    // Teacher finalized — Coral/Rose absent card (persists until next session)
    if (widget.teacherFinalizedAbsent) {
      final periodText = widget.absentPeriod.isNotEmpty
          ? widget.absentPeriod
          : '';
      final subjectText = widget.absentSubject.isNotEmpty
          ? widget.absentSubject
          : 'Class Attendance';

      final primaryColor = const Color(0xFFF43F5E); // Coral Rose
      final secondaryColor = const Color(0xFFE11D48); // Deep Rose
      final tagColor = isDark
          ? const Color(0xFFFB7185)
          : const Color(0xFFF43F5E);

      return Padding(
        padding: const EdgeInsets.only(bottom: 12.0, top: 4),
        child: TweenAnimationBuilder<double>(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          tween: Tween<double>(begin: 0.0, end: 1.0),
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: Transform.scale(
                scale: 0.95 + (0.05 * value),
                child: Transform.translate(
                  offset: Offset(0, 8 * (1 - value)),
                  child: child,
                ),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isDark
                    ? [
                        primaryColor.withValues(alpha: 0.16),
                        secondaryColor.withValues(alpha: 0.10),
                      ]
                    : [
                        primaryColor.withValues(alpha: 0.08),
                        secondaryColor.withValues(alpha: 0.05),
                      ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: tagColor.withValues(alpha: isDark ? 0.50 : 0.38),
                width: 1.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: primaryColor.withValues(alpha: isDark ? 0.16 : 0.07),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                _PeriodStatusIconWidget(
                  icon: Icons.cancel_presentation_rounded,
                  primaryColor: primaryColor,
                  secondaryColor: secondaryColor,
                  isDark: isDark,
                  isSuccess: false,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPeriodCategoryTag(tagColor, isDark),
                      const SizedBox(height: 5),
                      _buildTwoToneTitle(
                        periodText,
                        subjectText,
                        isDark,
                        tagColor,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Marked Absent',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: tagColor,
                          letterSpacing: 0.1,
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

    // Attendance already marked — amber pending card
    if (_hasMarkedAttendance) {
      final periodText = _periodInfo.isNotEmpty ? _periodInfo : '';
      final subjectText = _subjectName.isNotEmpty
          ? _subjectName
          : 'Class Attendance';

      final color = AppStyles.amberWarning;

      return Padding(
        padding: const EdgeInsets.only(bottom: 12.0, top: 4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: isDark ? 0.14 : 0.06),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: color.withValues(alpha: 0.28),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: isDark ? 0.14 : 0.07),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              _CampusStatusIconWidget(
                icon: Icons.hourglass_top_rounded,
                color: color,
                shouldPulse: true,
                shouldSpin: true,
                isDark: isDark,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPeriodCategoryTag(color, isDark),
                    const SizedBox(height: 5),
                    _buildTwoToneTitle(periodText, subjectText, isDark, color),
                    const SizedBox(height: 3),
                    Text(
                      'Waiting for teacher to finalize',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Closed state — inline neutral message
    if (_isClosed) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10.0),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 400),
          opacity: 1.0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.timer_off_rounded,
                  size: 18,
                  color: AppStyles.textGray,
                ),
                const SizedBox(width: 10),
                Text(
                  'Attendance window closed',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppStyles.textGray,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Do not render active window if countdown is not initialized or expired
    if (_secondsRemaining <= 0) {
      return const SizedBox.shrink();
    }

    final Color themeColor = _secondsRemaining <= 30
        ? AppStyles.errorRed
        : _secondsRemaining <= 60
        ? AppStyles.amberWarning
        : AppStyles.successGreen;
    final String minutes = (_secondsRemaining ~/ 60).toString().padLeft(2, '0');
    final String seconds = (_secondsRemaining % 60).toString().padLeft(2, '0');

    // Urgency glow intensity
    final double glowOpacity = _secondsRemaining <= 30
        ? 0.25
        : _secondsRemaining <= 60
        ? 0.12
        : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 15),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: themeColor.withValues(alpha: 0.28),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: themeColor.withValues(
                alpha: glowOpacity > 0 ? glowOpacity : 0.06,
              ),
              blurRadius: 16,
              offset: const Offset(0, 4),
              spreadRadius: glowOpacity > 0 ? 1 : 0,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Row 1: Status + Stable-Width Urgency Timer pill ──
            Row(
              children: [
                _PulsingDot(color: themeColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPeriodCategoryTag(themeColor, false),
                      const SizedBox(height: 4),
                      const Text(
                        'Attendance Window',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: AppStyles.textDark,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Active for current period',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: themeColor.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Stable timer pill with tabular figures to eliminate horizontal jitter
                ScaleTransition(
                  scale: _timerPulseAnim,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 74),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5.5,
                    ),
                    decoration: BoxDecoration(
                      color: themeColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: themeColor.withValues(alpha: 0.28),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.timer_outlined, size: 14, color: themeColor),
                        const SizedBox(width: 5),
                        Text(
                          '$minutes:$seconds',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13.5,
                            color: themeColor,
                            letterSpacing: 0.3,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Row 2: Period info on a single auto-scaled line ─────
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8.5,
              ),
              decoration: BoxDecoration(
                color: AppStyles.backgroundLight,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.black.withValues(alpha: 0.04)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.menu_book_rounded,
                    size: 15,
                    color: AppStyles.textDark.withValues(alpha: 0.75),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '$_periodInfo — $_subjectName',
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppStyles.textDark,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ── Row 3: CTA with press scale ──────────────────────────
            GestureDetector(
              onTapDown: (_) => setState(() => _ctaPressed = true),
              onTapUp: (_) {
                setState(() => _ctaPressed = false);
                final endTime =
                    _sessionDeadline ??
                    DateTime.now().add(Duration(seconds: _secondsRemaining));
                Navigator.of(context).pushNamed(
                  '/qr-precheck',
                  arguments: {
                    'session_id': _activeSessionId,
                    'deadline': _sessionDeadline,
                    'end_time': endTime,
                    'subject_name': _subjectName,
                    'period_info': _periodInfo,
                    'period_timing': _periodTiming,
                  },
                );
              },
              onTapCancel: () => setState(() => _ctaPressed = false),
              child: AnimatedScale(
                scale: _ctaPressed ? 0.96 : 1.0,
                duration: const Duration(milliseconds: 100),
                curve: Curves.easeInOut,
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: null, // handled by GestureDetector
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                    label: const Text(
                      'Scan QR Now',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        letterSpacing: -0.2,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: themeColor,
                      disabledForegroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Animated Attendance Status Icon (One-time scale/fade & subtle pulse)
// ─────────────────────────────────────────────────────────────────────────────

class _AnimatedAttendanceStatusIcon extends StatefulWidget {
  final bool isSuccess;
  final Color color;
  final IconData icon;

  const _AnimatedAttendanceStatusIcon({
    required this.isSuccess,
    required this.color,
    required this.icon,
  });

  @override
  State<_AnimatedAttendanceStatusIcon> createState() =>
      _AnimatedAttendanceStatusIconState();
}

class _AnimatedAttendanceStatusIconState
    extends State<_AnimatedAttendanceStatusIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _containerScale;
  late Animation<double> _containerOpacity;
  late Animation<double> _iconScale;
  late Animation<double> _iconOpacity;
  late Animation<double> _glowSpread;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );

    // 1. Container circle scale & fade (0 - 55%)
    _containerScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOutBack),
      ),
    );
    _containerOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.35, curve: Curves.easeOut),
      ),
    );

    // 2. Icon scale & fade (35% - 85%)
    _iconScale = Tween<double>(begin: 0.2, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.85, curve: Curves.easeOutBack),
      ),
    );
    _iconOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.70, curve: Curves.easeOut),
      ),
    );

    // 3. Subtle glow pulse & settle (55% - 100%)
    _glowSpread =
        TweenSequence<double>([
          TweenSequenceItem(
            tween: Tween<double>(
              begin: 0.0,
              end: 3.0,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 50,
          ),
          TweenSequenceItem(
            tween: Tween<double>(
              begin: 3.0,
              end: 0.0,
            ).chain(CurveTween(curve: Curves.easeIn)),
            weight: 50,
          ),
        ]).animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.55, 1.0),
          ),
        );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _containerOpacity.value,
          child: Transform.scale(
            scale: _containerScale.value,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [widget.color, widget.color.withValues(alpha: 0.82)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(
                      alpha: 0.25 + (_glowSpread.value * 0.05),
                    ),
                    blurRadius: 8 + (_glowSpread.value * 2),
                    spreadRadius: _glowSpread.value * 0.5,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: Opacity(
                  opacity: _iconOpacity.value,
                  child: Transform.scale(
                    scale: _iconScale.value,
                    child: Icon(widget.icon, color: Colors.white, size: 24),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacityAnimation = Tween<double>(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacityAnimation,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

class _ScheduleCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final bool isCurrent;
  final bool isDone;
  final bool isAbsent;
  final bool isNotRecorded;
  final int periodNum;
  final String startTime;
  final String endTime;
  final ThemeData theme;
  final bool isDark;

  final int index;

  const _ScheduleCard({
    required this.item,
    required this.isCurrent,
    required this.isDone,
    required this.isAbsent,
    this.isNotRecorded = false,
    required this.periodNum,
    required this.startTime,
    required this.endTime,
    required this.theme,
    required this.isDark,
    required this.index,
  });

  @override
  State<_ScheduleCard> createState() => _ScheduleCardState();
}

class _ScheduleCardState extends State<_ScheduleCard>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.04).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    if (widget.isCurrent) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _ScheduleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isCurrent && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isCurrent && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = widget.isDark;
    final isCurrent = widget.isCurrent;
    final isDone = widget.isDone;
    final isAbsent = widget.isAbsent;
    final isNotRecorded = widget.isNotRecorded;

    final Color neutralSlate = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);

    // ── Colors ──────────────────────────────────────────
    final Color accentColor = isCurrent
        ? theme.primaryColor
        : isDone
        ? AppStyles.successGreen
        : isAbsent
        ? AppStyles.errorRed
        : isNotRecorded
        ? neutralSlate
        : theme.primaryColor;

    final Color cardBg = isCurrent
        ? theme.primaryColor.withValues(alpha: isDark ? 0.28 : 0.09)
        : isDone
        ? AppStyles.successGreen.withValues(alpha: isDark ? 0.18 : 0.07)
        : isAbsent
        ? AppStyles.errorRed.withValues(alpha: isDark ? 0.18 : 0.07)
        : isNotRecorded
        ? (isDark
              ? const Color(0xFF1E293B).withValues(alpha: 0.5)
              : const Color(0xFFF1F5F9))
        : theme.primaryColor.withValues(alpha: isDark ? 0.10 : 0.05);

    // Subject name color
    final Color textPrimary = isCurrent
        ? theme.primaryColor
        : isDone
        ? AppStyles.successGreen
        : isAbsent
        ? AppStyles.errorRed
        : isNotRecorded
        ? (isDark ? Colors.white70 : AppStyles.textDark.withValues(alpha: 0.85))
        : theme.primaryColor;

    // Period info + teacher name color
    final Color textSecondary = isCurrent
        ? theme.primaryColor.withValues(alpha: 0.75)
        : isDone
        ? AppStyles.successGreen.withValues(alpha: 0.75)
        : isAbsent
        ? AppStyles.errorRed.withValues(alpha: 0.75)
        : isNotRecorded
        ? neutralSlate.withValues(alpha: 0.85)
        : AppStyles.textGray;

    // ── Strip config ─────────────────────────────────────
    final Color stripBg = isCurrent
        ? theme.primaryColor
        : isDone
        ? AppStyles.successGreen
        : isAbsent
        ? AppStyles.errorRed
        : isNotRecorded
        ? (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0))
        : theme.primaryColor.withValues(alpha: isDark ? 0.18 : 0.10);

    final Color stripText = isCurrent || isDone || isAbsent
        ? Colors.white
        : isNotRecorded
        ? neutralSlate
        : theme.primaryColor;

    final String stripLabel = isCurrent
        ? '● Live Now'
        : isDone
        ? '✓  Attended'
        : isAbsent
        ? '✗  Absent'
        : isNotRecorded
        ? '—  Not Recorded'
        : 'Upcoming';

    // ── Watermark icon for done/absent/current/notRecorded ───────────────────
    final IconData? watermarkIcon = isDone
        ? Icons.check_circle_outline_rounded
        : isAbsent
        ? Icons.cancel_outlined
        : isCurrent
        ? Icons.radio_button_checked_rounded
        : isNotRecorded
        ? Icons.remove_circle_outline_rounded
        : null;

    Widget card = GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeInOut,
        child: Container(
          width: 150,
          height: 120,
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: accentColor.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: isCurrent
                ? [
                    BoxShadow(
                      color: theme.primaryColor.withValues(alpha: 0.18),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : isDone
                ? [
                    BoxShadow(
                      color: AppStyles.successGreen.withValues(alpha: 0.10),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : isAbsent
                ? [
                    BoxShadow(
                      color: AppStyles.errorRed.withValues(alpha: 0.10),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.18 : 0.06,
                      ),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ── Left accent bar ──────────────────────
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 4, color: accentColor),
                ),
                // ── Watermark icon ───────────────────────
                if (watermarkIcon != null)
                  Positioned(
                    right: -8,
                    top: 6,
                    child: Icon(
                      watermarkIcon,
                      size: 52,
                      color: accentColor.withValues(alpha: 0.07),
                    ),
                  ),

                // ── Main content ─────────────────────────
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    // Content area
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Period + time on one line
                            Text(
                              'Period ${widget.periodNum}  ·  ${widget.startTime}-${widget.endTime}',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: textSecondary,
                                letterSpacing: 0.1,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            // Subject name — natural height, no Expanded
                            Text(
                              widget.item['subject'] as String,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: textPrimary,
                                height: 1.25,
                              ),
                            ),
                            if ((widget.item['teacher'] as String? ?? '')
                                .isNotEmpty) ...[
                              const SizedBox(height: 5),
                              // Faculty name — always directly below subject when assigned
                              Text(
                                widget.item['teacher'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ), // closes Expanded
                    // ── Bottom status strip ──────────────
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      color: stripBg,
                      child: Text(
                        stripLabel,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: stripText,
                          letterSpacing: 0.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (isCurrent) {
      return AnimatedBuilder(
        animation: _pulseAnim,
        builder: (context, child) =>
            Transform.scale(scale: _pulseAnim.value, child: child),
        child: card,
      );
    }

    return card;
  }
}

class _MotivationalMessage extends StatefulWidget {
  const _MotivationalMessage();
  @override
  State<_MotivationalMessage> createState() => _MotivationalMessageState();
}

class _MotivationalMessageState extends State<_MotivationalMessage> {
  double _pct = -1;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (_DashboardScreenState._cachedMotivationalPct >= 0) {
      _pct = _DashboardScreenState._cachedMotivationalPct;
      _loading = false;
    }
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;
      final studentData = await supabase
          .from('students')
          .select('class_id')
          .eq('id', user.id)
          .maybeSingle();
      if (studentData == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final classId = studentData['class_id'] as String;
      final sessions = await supabase
          .from('attendance_sessions')
          .select('id')
          .eq('status', 'finalized')
          .eq('class_id', classId);
      final ids = (sessions as List).map((s) => s['id'] as String).toList();
      if (ids.isEmpty) {
        if (mounted) {
          setState(() {
            _pct = 0;
            _loading = false;
          });
          _DashboardScreenState._cachedMotivationalPct = _pct;
        }
        return;
      }
      final records = await supabase
          .from('period_attendance')
          .select('status, face_verified')
          .eq('student_id', user.id)
          .inFilter('session_id', ids)
          .inFilter('status', ['present', 'absent']);
      final total = records.length;
      final present = records
          .where(
            (r) => r['status'] == 'present' && (r['face_verified'] == true),
          )
          .length;
      if (mounted) {
        setState(() {
          _pct = total > 0 ? present / total : 0;
          _loading = false;
        });
        _DashboardScreenState._cachedMotivationalPct = _pct;
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _pct < 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    IconData icon;
    String message;
    Color color;

    if (_pct >= 0.90) {
      icon = Icons.emoji_events_rounded;
      message = 'Outstanding! You\'re a top performer.';
      color = AppStyles.successGreen;
    } else if (_pct >= 0.75) {
      icon = Icons.check_circle_rounded;
      message = 'Good standing! Keep attending regularly.';
      color = AppStyles.successGreen;
    } else if (_pct >= 0.60) {
      icon = Icons.warning_rounded;
      message = 'Condonation risk. Attend more classes to be safe.';
      color = AppStyles.amberWarning;
    } else if (_pct == 0 && _pct.isNaN == false) {
      icon = Icons.menu_book_rounded;
      message = 'No sessions yet. You\'re all caught up!';
      color = AppStyles.successGreen;
    } else {
      icon = Icons.gpp_maybe_rounded;
      message = 'Detention risk! Contact your advisor immediately.';
      color = AppStyles.errorRed;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppStyles.textDark,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SleepingZAnimation extends StatefulWidget {
  const _SleepingZAnimation();

  @override
  State<_SleepingZAnimation> createState() => _SleepingZAnimationState();
}

class _SleepingZAnimationState extends State<_SleepingZAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _slideAnim = Tween<double>(
      begin: 0,
      end: -10,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _fadeAnim = TweenSequence([
      TweenSequenceItem(tween: Tween<double>(begin: 0, end: 1), weight: 30),
      TweenSequenceItem(tween: Tween<double>(begin: 1, end: 1), weight: 40),
      TweenSequenceItem(tween: Tween<double>(begin: 1, end: 0), weight: 30),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _slideAnim.value),
          child: Opacity(
            opacity: _fadeAnim.value,
            child: const Text(
              'Z',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppStyles.primaryBlue,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AnimatedFaceVerifiedBadge extends StatefulWidget {
  final Color color;
  const _AnimatedFaceVerifiedBadge({required this.color});

  @override
  State<_AnimatedFaceVerifiedBadge> createState() =>
      _AnimatedFaceVerifiedBadgeState();
}

class _AnimatedFaceVerifiedBadgeState extends State<_AnimatedFaceVerifiedBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scaleAnimation = TweenSequence([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.8,
          end: 1.1,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.1,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 40,
      ),
    ]).animate(_controller);

    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Opacity(
            opacity: _controller.value.clamp(0.0, 1.0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: widget.color.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.face_retouching_natural_rounded,
                    size: 14,
                    color: widget.color,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Face Verified',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: widget.color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AnimatedHourglass extends StatefulWidget {
  const _AnimatedHourglass();

  @override
  State<_AnimatedHourglass> createState() => _AnimatedHourglassState();
}

class _AnimatedHourglassState extends State<_AnimatedHourglass>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // Pauses at 0, flips fast, pauses at pi, flips fast
        double angle = 0;
        final t = _controller.value;
        if (t > 0.4 && t < 0.6) {
          final curve = Curves.easeInOut.transform((t - 0.4) * 5);
          angle = 3.14159 * curve;
        } else if (t >= 0.6) {
          angle = 3.14159;
        }

        return Transform.rotate(
          angle: angle,
          child: Icon(
            Icons.hourglass_top_rounded,
            color: Colors.orange.shade700,
            size: 24,
          ),
        );
      },
    );
  }
}

class _CompactGeofenceBadge extends StatefulWidget {
  final String status;
  const _CompactGeofenceBadge({required this.status});
  @override
  State<_CompactGeofenceBadge> createState() => _CompactGeofenceBadgeState();
}

class _CompactGeofenceBadgeState extends State<_CompactGeofenceBadge>
    with TickerProviderStateMixin {
  late AnimationController _spinController;
  late AnimationController _pulseController;
  late Animation<double> _pulseScaleAnim;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _pulseScaleAnim = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _updateAnimations();
  }

  void _updateAnimations() {
    if (widget.status == 'checking') {
      _spinController.repeat();
      _pulseController.stop();
    } else if (widget.status == 'oncampus') {
      _spinController.stop();
      _pulseController.repeat(reverse: true);
    } else {
      _spinController.stop();
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void didUpdateWidget(covariant _CompactGeofenceBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status != oldWidget.status) _updateAnimations();
  }

  @override
  void dispose() {
    _spinController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color color;
    Widget inner;

    switch (widget.status) {
      case 'oncampus':
        color = AppStyles.successGreen;
        inner = ScaleTransition(
          scale: _pulseScaleAnim,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 5,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        );
        break;
      case 'offcampus':
        color = AppStyles.errorRed;
        inner = Icon(Icons.location_off_rounded, size: 13, color: color);
        break;
      case 'off':
        color = AppStyles.textGray;
        inner = Icon(Icons.location_disabled_rounded, size: 13, color: color);
        break;
      default:
        color = AppStyles.textGray;
        inner = RotationTransition(
          turns: _spinController,
          child: Icon(Icons.sync_rounded, size: 13, color: color),
        );
    }

    return Tooltip(
      message: widget.status == 'oncampus'
          ? 'On Campus'
          : widget.status == 'offcampus'
          ? 'Off Campus — you are outside campus'
          : widget.status == 'off'
          ? 'Location is turned off — tap to retry'
          : 'Checking location...',
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.35), width: 1.5),
        ),
        child: Center(child: inner),
      ),
    );
  }
}

class _AttendanceStreakCard extends StatefulWidget {
  final int streak;
  final List<bool?>
  weekDays; // Mon–Sat: true=present, false=absent, null=future
  const _AttendanceStreakCard({required this.streak, required this.weekDays});
  @override
  State<_AttendanceStreakCard> createState() => _AttendanceStreakCardState();
}

class _AttendanceStreakCardState extends State<_AttendanceStreakCard>
    with TickerProviderStateMixin {
  late AnimationController _glowController;
  late Animation<double> _glowAnim;
  late AnimationController _fireScaleController;
  late Animation<double> _fireScaleAnim;
  late List<AnimationController> _circleControllers;

  static const List<String> _dayLabels = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
  ];

  // Color based on streak length
  Color get streakColor {
    if (widget.streak >= 15) return Colors.amber.shade700;
    if (widget.streak >= 10) return Colors.deepOrange.shade600;
    if (widget.streak >= 5) return Colors.deepOrange;
    return Colors.orange.shade600;
  }

  String get streakEmoji {
    if (widget.streak >= 15) return '🏆';
    if (widget.streak >= 10) return '🔥';
    if (widget.streak >= 5) return '🔥';
    if (widget.streak > 0) return '⚡';
    return '💤';
  }

  String get streakBadgeText {
    if (widget.streak >= 15) return 'Legend! 🏆';
    if (widget.streak >= 10) return 'On Fire! 🔥';
    if (widget.streak >= 5) return 'Blazing! 🔥';
    if (widget.streak > 0) return 'Keep going!';
    return 'Start now!';
  }

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _glowAnim = Tween<double>(begin: 0.2, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _fireScaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    _fireScaleAnim = Tween<double>(begin: 0.88, end: 1.12).animate(
      CurvedAnimation(parent: _fireScaleController, curve: Curves.easeInOut),
    );

    _circleControllers = List.generate(6, (i) {
      final ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 400),
      );
      Future.delayed(Duration(milliseconds: 80 * i), () {
        if (mounted) ctrl.forward();
      });
      return ctrl;
    });
  }

  @override
  void dispose() {
    _glowController.dispose();
    _fireScaleController.dispose();
    for (final c in _circleControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool hasStreak = widget.streak > 0;
    final Color color = streakColor;
    final Color cardBg = color.withValues(alpha: isDark ? 0.10 : 0.06);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.30), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top row: number + fire + label + badge ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '${widget.streak}',
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  color: hasStreak ? color : AppStyles.textGray,
                  letterSpacing: -1,
                  height: 1,
                ),
              ),
              const SizedBox(width: 10),
              // Fire with combined glow + scale animation
              AnimatedBuilder(
                animation: Listenable.merge([_glowAnim, _fireScaleAnim]),
                builder: (context, child) {
                  return Transform.scale(
                    scale: hasStreak ? _fireScaleAnim.value : 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: hasStreak
                            ? [
                                BoxShadow(
                                  color: color.withValues(
                                    alpha: _glowAnim.value * 0.8,
                                  ),
                                  blurRadius: 14 + (_glowAnim.value * 14),
                                  spreadRadius: 2 + (_glowAnim.value * 3),
                                ),
                                BoxShadow(
                                  color: Colors.orange.withValues(
                                    alpha: _glowAnim.value * 0.4,
                                  ),
                                  blurRadius: 6,
                                  spreadRadius: 0,
                                ),
                              ]
                            : [],
                      ),
                      child: Text(
                        streakEmoji,
                        style: const TextStyle(fontSize: 30),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Current',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppStyles.textGray,
                    ),
                  ),
                  Text(
                    'streak',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppStyles.textGray,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              AnimatedBuilder(
                animation: _glowAnim,
                builder: (context, child) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(
                        alpha: 0.12 + (_glowAnim.value * 0.08),
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: color.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      streakBadgeText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            hasStreak
                ? widget.streak >= 10
                      ? 'Incredible! You\'re unstoppable 🏆'
                      : widget.streak >= 5
                      ? 'Amazing consistency! Don\'t break it now.'
                      : 'Great start! Attend tomorrow to grow it.'
                : 'Start attending to build your streak!',
            style: const TextStyle(
              fontSize: 11,
              color: AppStyles.textGray,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Divider(
            height: 1,
            thickness: 1,
            color: color.withValues(alpha: 0.15),
          ),
          const SizedBox(height: 12),
          // ── Day circles Mon–Sat ───────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(6, (i) {
              final bool? dayStatus = i < widget.weekDays.length
                  ? widget.weekDays[i]
                  : null;
              final bool isPresent = dayStatus == true;
              final bool isAbsent = dayStatus == false;

              return ScaleTransition(
                scale: CurvedAnimation(
                  parent: _circleControllers[i],
                  curve: Curves.easeOutBack,
                ),
                child: Column(
                  children: [
                    isPresent
                        ? AnimatedBuilder(
                            animation: Listenable.merge([
                              _glowAnim,
                              _fireScaleAnim,
                            ]),
                            builder: (context, child) {
                              return Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: color.withValues(alpha: 0.6),
                                    width: 2.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: color.withValues(
                                        alpha: _glowAnim.value * 0.5,
                                      ),
                                      blurRadius: 8 + (_glowAnim.value * 6),
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Transform.scale(
                                    scale: _fireScaleAnim.value,
                                    child: const Text(
                                      '🔥',
                                      style: TextStyle(fontSize: 16),
                                    ),
                                  ),
                                ),
                              );
                            },
                          )
                        : isAbsent
                        ? AnimatedBuilder(
                            animation: Listenable.merge([
                              _glowAnim,
                              _fireScaleAnim,
                            ]),
                            builder: (context, child) {
                              return Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: color.withValues(
                                    alpha: isDark ? 0.18 : 0.13,
                                  ),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: color.withValues(
                                      alpha: isDark ? 0.60 : 0.48,
                                    ),
                                    width: 2.2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: color.withValues(
                                        alpha: isDark
                                            ? (0.12 + _glowAnim.value * 0.20)
                                            : (0.08 + _glowAnim.value * 0.15),
                                      ),
                                      blurRadius: 6 + (_glowAnim.value * 5),
                                      spreadRadius: 0.5,
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Transform.rotate(
                                    angle: (_fireScaleAnim.value - 1.0) * 0.65,
                                    child: Transform.scale(
                                      scale: _fireScaleAnim.value,
                                      child: const Text(
                                        '❄️',
                                        style: TextStyle(fontSize: 16.5),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          )
                        : Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: Colors.transparent,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Colors.grey.shade400,
                                width: 2,
                                strokeAlign: BorderSide.strokeAlignCenter,
                              ),
                            ),
                          ),
                    const SizedBox(height: 5),
                    Text(
                      _dayLabels[i],
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: isPresent
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: isPresent
                            ? color
                            : isAbsent
                            ? color.withValues(alpha: isDark ? 0.70 : 0.65)
                            : AppStyles.textGray,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}
