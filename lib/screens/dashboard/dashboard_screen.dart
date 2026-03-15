import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'dart:math' as math;
import '../../utils/app_styles.dart';
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

  String _studentName = 'Student';
  String _upcomingPeriodText = '';

  bool _teacherFinalized = false;
  String _finalizedSubject = '';
  String _finalizedPeriod = '';
  bool _teacherFinalizedAbsent = false;
  String _absentSubject = '';
  String _absentPeriod = '';

  String _geofenceStatus = 'checking';
  String _liveTime = '';
  Timer? _clockTimer;
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
  // ─────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _fetchProfile();
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
    _liveTime = _getAnimatedTime();
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _liveTime = _getAnimatedTime());
    });
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
    _clockTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
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

  String _getAnimatedTime() {
    final now = DateTime.now();
    final hour = now.hour > 12
        ? now.hour - 12
        : (now.hour == 0 ? 12 : now.hour);
    final minute = now.minute.toString().padLeft(2, '0');
    final period = now.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
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

      double centerLat = 17.409904;
      double centerLng = 78.590623;
      double radiusMeters = 200.0;

      try {
        final settings = await supabase
            .from('geofence_settings')
            .select('latitude, longitude, radius_meters')
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
        final startStr = (row['period'] as Map?)?['start_time'] as String? ?? '00:00';
        final parts = startStr.split(':');
        final startMin = int.parse(parts[0]) * 60 + int.parse(parts[1]);
        if (startMin > nowMinutes) remaining++;
      }
      final remainingLabel = remaining > 1 ? ' · $remaining left' : '';
      if (mounted) {
        setState(
          () => _upcomingPeriodText =
              'Period $periodNum · $subjectName · $startTime$remainingLabel',
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
      
      for (int d = 0; d < 6; d++) { // Mon to Sat
        final day = monday.add(Duration(days: d));
        final dayStr = day.toIso8601String().split('T')[0];
        final todayStr = today.toIso8601String().split('T')[0];
        
        if (day.isAfter(today)) {
          weekDays.add(null); // Future day
        } else if (dayStr == todayStr) {
          final status = attendanceMap[dayStr];
          weekDays.add(status == 'present' ? true : null); // Today — only mark if present
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
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 400),
                              transitionBuilder: (child, anim) => SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.5),
                                  end: Offset.zero,
                                ).animate(anim),
                                child: FadeTransition(
                                  opacity: anim,
                                  child: child,
                                ),
                              ),
                              child: Text(
                                _liveTime,
                                key: ValueKey(_liveTime),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.blueGrey.shade800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () {
                        if (mounted) setState(() => _geofenceStatus = 'checking');
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
          child: ListView(
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
                                    color: isDark ? Colors.white : AppStyles.primaryBlue,
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
                                          color: isDark ? Colors.white : AppStyles.primaryBlue,
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
                child: _AttendancePercentageCard(theme: theme, isDark: isDark),
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
                              color: theme.primaryColor.withValues(alpha: 0.3),
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
        bottomNavigationBar: CustomBottomNav(currentIndex: 0, onTap: _onNavTap),
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

    _scaleAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _cardController,
        curve: const Interval(0.2, 1.0, curve: Curves.easeOutBack),
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

    final color = _isPresentToday
        ? AppStyles.successGreen
        : (!_isPresentToday && _isPastCutoff)
        ? AppStyles.errorRed
        : AppStyles.amberWarning;
    final message = _isPresentToday
        ? 'You are Present Today'
        : (!_isPresentToday && _isPastCutoff)
        ? 'Absent Today'
        : 'Not Yet Marked';
    final iconData = _isPresentToday
        ? Icons.verified_user_rounded
        : (!_isPresentToday && _isPastCutoff)
        ? Icons.cancel_rounded
        : Icons.pending_actions_rounded;
    final subtitle = _isPresentToday
        ? 'Marked at $_markedAtTime'
        : (!_isPresentToday && _isPastCutoff)
        ? 'Attendance window has closed'
        : 'College hours end at 4:00 PM';

    return AnimatedBuilder(
      animation: _cardController,
      builder: (context, child) {
        return Opacity(
          opacity: _fadeAnim.value,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - _fadeAnim.value)),
            child: child,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: widget.isDark ? 0.15 : 0.07),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: widget.isDark ? 0.15 : 0.08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            AnimatedBuilder(
              animation: _scaleAnim,
              builder: (context, child) {
                return Transform.scale(scale: _scaleAnim.value, child: child);
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(
                    alpha: widget.isDark ? 0.15 : 0.9,
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(iconData, color: color, size: 24),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: widget.isDark ? Colors.white : AppStyles.textDark,
                    ),
                  ),
                  const SizedBox(height: 4),
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
            .select('status')
            .eq('student_id', user.id)
            .inFilter('session_id', finalizedIds)
            .inFilter('status', ['present', 'absent']);

        int total = records.length;
        int present = records.where((r) => r['status'] == 'present').length;
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
          color: (_pct >= 0.75
              ? Colors.indigo.shade400
              : _pct >= 0.60
              ? AppStyles.amberWarning
              : AppStyles.errorRed).withValues(alpha: isDark ? 0.55 : 0.45),
          width: 2.5,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: (_pct >= 0.75
                ? Colors.indigo.shade400
                : _pct >= 0.60
                ? AppStyles.amberWarning
                : AppStyles.errorRed).withValues(alpha: isDark ? 0.15 : 0.10),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: (_pct >= 0.75
                ? Colors.indigo.shade400
                : _pct >= 0.60
                ? AppStyles.amberWarning
                : AppStyles.errorRed).withValues(alpha: isDark ? 0.05 : 0.03),
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
          .map((r) => r['teacher_id'] as String)
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

      // Fetch today's attendance sessions for this class
      final today = DateTime.now().toIso8601String().split('T')[0];
      final todaySessions = await supabase
          .from('attendance_sessions')
          .select('id, subject_id, period_id, status')
          .eq('class_id', classId)
          .eq('session_date', today);

      // Map: "subjectId" → { sessionId, status }
      final Map<String, Map<String, String>> sessionMap = {};
      for (final s in todaySessions) {
        final key = s['subject_id'] as String;
        sessionMap[key] = {
          'sessionId': s['id'] as String,
          'status': s['status'] as String,
        };
      }

      // Fetch student's period_attendance for today's sessions
      final todaySessionIds = todaySessions
          .map((s) => s['id'] as String)
          .toList();
      Map<String, String> studentAttendance = {};
      if (todaySessionIds.isNotEmpty) {
        final pa = await supabase
            .from('period_attendance')
            .select('session_id, status')
            .eq('student_id', user.id)
            .inFilter('session_id', todaySessionIds);
        for (final a in pa) {
          studentAttendance[a['session_id'] as String] = a['status'] as String;
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

      final List<Map<String, dynamic>> items = [];
      for (final row in sortedRows) {
        final subjectId = row['subject_id'] as String;

        final teacherId = row['teacher_id'] as String;
        final subjectName =
            (row['subject'] as Map?)?['name'] as String? ?? 'Unknown';
        final periodNumber =
            (row['period'] as Map?)?['period_number'] as int? ?? 0;
        final startTime =
            ((row['period'] as Map?)?['start_time'] as String? ?? '').substring(
              0,
              5,
            );
        final endTime = ((row['period'] as Map?)?['end_time'] as String? ?? '')
            .substring(0, 5);
        final title = teacherTitles[teacherId] ?? 'Mr';
        final fullName = teacherFullNames[teacherId] ?? '';
        final facultyName = fullName.isNotEmpty ? '$title. $fullName' : title;

        final key = subjectId;
        final session = sessionMap[key];
        final sessionStatus = session?['status'];
        final sessionId = session?['sessionId'];
        final studentStatus = sessionId != null
            ? studentAttendance[sessionId]
            : null;

        String cardStatus = 'upcoming';
        if (sessionStatus == 'active') {
          cardStatus = 'current';
        } else if (sessionStatus == 'finalized' ||
            sessionStatus == 'reviewing') {
          cardStatus = studentStatus == 'present' ? 'done' : 'absent';
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
    with SingleTickerProviderStateMixin {
  VoidCallback? get _onSessionFinalized => widget.onSessionFinalized;

  int _secondsRemaining = 0;
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
  // ignore: unused_field
  String _teacherName = '';
  // ignore: unused_field
  DateTime? _qrTokenExpiresAt;

  RealtimeChannel? _subscription;
  RealtimeChannel? _attendanceSubscription;
  String? _userClassId;
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
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

      // 2. Fetch active session initially
      _fetchActiveSession();

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
              final status = newRecord['status'] as String?;
              // Student scanned + face verified → show pending banner
              if ((status == 'present' || status == 'pending') && mounted) {
                setState(() {
                  _hasMarkedAttendance = true;
                });
                _countdownTimer?.cancel();
                _pollingTimer?.cancel();
                _pollingTimer = null;
              }
            },
          )
          .subscribe();

      // 4. Single unified channel for attendance_sessions — handles both active and finalized
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
            callback: (payload) async {
              final newRecord = payload.newRecord;
              final status = newRecord['status'] as String?;
              final sessionId = newRecord['id'] as String?;

              debugPrint(
                '[BANNER] attendance_sessions event: status=$status sessionId=$sessionId',
              );

              if (status == 'finalized' && mounted) {
                debugPrint('[BANNER] Session finalized event received');
                await _handleFinalization(sessionId);
              } else if (status == 'active') {
                _fetchActiveSession();
              }
            },
          )
          .subscribe((status, [error]) {
            debugPrint('[BANNER] Unified channel status: $status error=$error');
          });

      // 5. Polling fallback — checks every 15s for latest finalized session
      _startFinalizationPolling();
    } catch (e) {
      debugPrint('Error initializing realtime: $e');
    }
  }

  Future<void> _handleFinalization(String? sessionId) async {
    if (sessionId == null) return;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    debugPrint(
      '[BANNER] Checking period_attendance for sessionId=$sessionId studentId=${user.id}',
    );
    final record = await supabase
        .from('period_attendance')
        .select('status')
        .eq('session_id', sessionId)
        .eq('student_id', user.id)
        .maybeSingle();

    debugPrint('[BANNER] period_attendance result: $record');
    final studentStatus = record?['status'] as String?;
    debugPrint('[BANNER] Student status in finalized session: $studentStatus');

    if (studentStatus == 'present' && mounted) {
      final savedSubject = _subjectName.isNotEmpty
          ? _subjectName
          : widget.finalizedSubject;
      final savedPeriod = _periodInfo.isNotEmpty
          ? _periodInfo
          : widget.finalizedPeriod;
      setState(() {
        _hasMarkedAttendance = false;
        _isClosed = false;
        _isVisible = true;
      });
      debugPrint('[BANNER] Showing green confirmed card');
      widget.onTeacherFinalized?.call(savedSubject, savedPeriod);
      _onSessionFinalized?.call();
    } else if (studentStatus == 'absent' && mounted) {
      final savedSubject = _subjectName.isNotEmpty ? _subjectName : '';
      final savedPeriod = _periodInfo.isNotEmpty ? _periodInfo : '';
      setState(() {
        _hasMarkedAttendance = false;
        _isClosed = false;
        _isVisible = false;
      });
      debugPrint('[BANNER] Student absent — showing absent card');
      widget.onTeacherFinalizedAbsent?.call(savedSubject, savedPeriod);
      _onSessionFinalized?.call();
    }
  }

  String? _lastCheckedFinalizedSessionId;

  void _startFinalizationPolling() {
    // Poll every 15s as fallback for when realtime misses events
    Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_userClassId == null) return;
      // Only check if we're in a state where we might be waiting for finalization
      if (!_hasMarkedAttendance &&
          !widget.teacherFinalized &&
          !widget.teacherFinalizedAbsent) {
        return;
      }

      final user = supabase.auth.currentUser;
      if (user == null) return;

      try {
        // Find the most recently finalized session for this class
        final sessions = await supabase
            .from('attendance_sessions')
            .select('id')
            .eq('class_id', _userClassId!)
            .eq('status', 'finalized')
            .order('finalized_at', ascending: false)
            .limit(1);

        if (sessions.isEmpty) return;
        final latestId = sessions.first['id'] as String;

        // Don't re-process the same session
        if (latestId == _lastCheckedFinalizedSessionId) return;
        _lastCheckedFinalizedSessionId = latestId;

        debugPrint(
          '[BANNER] Polling fallback: checking finalized session $latestId',
        );
        await _handleFinalization(latestId);
      } catch (e) {
        debugPrint('[BANNER] Polling fallback error: $e');
      }
    });
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (!mounted) return;
      debugPrint(
        'AttendanceBanner: Fallback polling checking for active session...',
      );
      _fetchActiveSession();
    });
  }

  Future<void> _fetchActiveSession() async {
    if (_userClassId == null || !mounted) return;
    try {
      // Step 1: Fetch active session without joins
      final sessionData = await supabase
          .from('attendance_sessions')
          .select(
            'id, subject_id, period_id, teacher_id, current_qr_token, qr_token_expires_at, status, opened_at',
          )
          .eq('class_id', _userClassId!)
          .eq('status', 'active')
          .order('opened_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (!mounted) return;

      if (sessionData != null) {
        final fetchedSessionId = sessionData['id'] as String?;

        // If we already know this session and attendance is marked, skip
        if (fetchedSessionId == _activeSessionId &&
            _isVisible &&
            _hasMarkedAttendance) {
          return;
        }

        // Check if student has already marked attendance for this session
        final user = supabase.auth.currentUser;
        if (user != null && fetchedSessionId != null && !_hasMarkedAttendance) {
          debugPrint('Checking attendance for session id: $fetchedSessionId');
          final attendanceRecord = await supabase
              .from('period_attendance')
              .select('status')
              .eq('session_id', fetchedSessionId)
              .eq('student_id', user.id)
              .inFilter('status', ['present', 'pending'])
              .maybeSingle();
          debugPrint('Period attendance query result: $attendanceRecord');

          if (attendanceRecord != null &&
              (attendanceRecord['status'] == 'present' ||
                  attendanceRecord['status'] == 'pending') &&
              mounted) {
            debugPrint(
              'Setting hasMarkedAttendance to true and stopping all timers',
            );
            // Student already marked — show green card
            // Still need to fetch subject info for display
            final subjectId = sessionData['subject_id'];
            final subjectData = await supabase
                .from('subjects')
                .select('name')
                .eq('id', subjectId)
                .maybeSingle();

            if (!mounted) return;

            _hasMarkedAttendance = true;
            _pollingTimer?.cancel();
            _pollingTimer = null;
            _countdownTimer?.cancel();

            setState(() {
              _activeSessionId = fetchedSessionId;
              _subjectName =
                  subjectData?['name'] as String? ?? 'Unknown Subject';
              _isVisible = true;
              _isClosed = false;
            });
            return;
          }
        }

        // If session already visible and not yet marked, don't re-init banner
        if (fetchedSessionId == _activeSessionId && _isVisible) {
          return;
        }

        // Start 180 second flat countdown from when the active session is first seen
        int remainingSeconds = 180;
        final openedAtStr = sessionData['opened_at'] as String?;
        if (openedAtStr != null) {
          final openedAt = DateTime.parse(openedAtStr).toLocal();
          final elapsed = DateTime.now().difference(openedAt).inSeconds;
          remainingSeconds = math.max(0, 180 - elapsed);
        }

        if (remainingSeconds > 0) {
          // Step 2: Parallel fetch for references
          final subjectId = sessionData['subject_id'];
          final periodId = sessionData['period_id'];
          final teacherId = sessionData['teacher_id'];

          final results = await Future.wait([
            supabase
                .from('subjects')
                .select('name')
                .eq('id', subjectId)
                .maybeSingle(),
            supabase
                .from('periods')
                .select('period_number, start_time, end_time')
                .eq('id', periodId)
                .maybeSingle(),
            // Check if teacher exists in public.teachers, then get name from public.users
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
          ]);

          if (!mounted) return;

          final subjectData = results[0];
          final periodData = results[1];
          final teacherData = results[2];

          debugPrint(
            'AttendanceBanner: Found active session for class_id $_userClassId, subject: ${subjectData?['name']}',
          );

          String formattedPeriod = 'Unknown Period';
          if (periodData != null) {
            final int periodNum = periodData['period_number'] as int? ?? 1;
            final String start = periodData['start_time'] as String? ?? '';
            final String end = periodData['end_time'] as String? ?? '';

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

            formattedPeriod = '$periodNum${getOrdinal(periodNum)} Period';
            if (start.isNotEmpty && end.isNotEmpty) {
              formattedPeriod += ' $start - $end';
            }
          }

          setState(() {
            _activeSessionId = fetchedSessionId;
            _subjectName = subjectData?['name'] as String? ?? 'Unknown Subject';
            _periodInfo = formattedPeriod;
            _teacherName =
                teacherData?['full_name'] as String? ?? 'Unknown Teacher';
            // We do not use qrTokenExpiresAt for banner logic anymore, but keep the assignment valid
            _qrTokenExpiresAt = DateTime.now().add(
              const Duration(seconds: 180),
            );
            _secondsRemaining = remainingSeconds;
            _hasMarkedAttendance = false;

            if (!_isVisible) {
              debugPrint('AttendanceBanner: Setting banner to visible');
            }
            _isClosed = false;
            _isVisible = true;
          });
          widget.onNewSession?.call();
          _startTimer();
        } else {
          _closeBanner();
        }
      } else {
        // Only close if student hasn't submitted attendance (don't clear "waiting" card)
        if (!_hasMarkedAttendance &&
            !widget.teacherFinalized &&
            !widget.teacherFinalizedAbsent) {
          _closeBanner();
        }
      }
    } catch (e) {
      debugPrint('Error fetching session data: $e');
    }
  }

  void _startTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _secondsRemaining--);
        // Subtle pulse on each tick
        _timerPulseController.forward().then((_) {
          if (mounted) _timerPulseController.reverse();
        });
        if (_secondsRemaining <= 0) {
          _closeBanner();
        }
      } else {
        _closeBanner();
      }
    });
  }

  void _closeBanner() {
    _activeSessionId = null;
    _countdownTimer?.cancel();
    if (!mounted) return;
    setState(() => _isClosed = true);
    // Auto-hide the closed banner after 4 seconds
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _isVisible = false);
    });
  }

  @override
  void dispose() {
    _subscription?.unsubscribe();
    _attendanceSubscription?.unsubscribe();
    _pollingTimer?.cancel();
    _countdownTimer?.cancel();
    _timerPulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVisible &&
        !widget.teacherFinalized &&
        !widget.teacherFinalizedAbsent) {
      return const SizedBox.shrink();
    }

    // Teacher finalized — green confirmed card (persists until next session)
    if (widget.teacherFinalized) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12.0, top: 4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppStyles.successGreen.withValues(alpha: 0.4),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: AppStyles.successGreen.withValues(alpha: 0.2),
                blurRadius: 16,
                spreadRadius: 2,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppStyles.successGreen,
                      AppStyles.successGreen.withValues(alpha: 0.8),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppStyles.successGreen.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Attendance Confirmed',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: AppStyles.successGreen,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.finalizedPeriod} — ${widget.finalizedSubject}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppStyles.textGray,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Marked present by teacher',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppStyles.successGreen.withValues(alpha: 0.9),
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

    // Teacher finalized — red absent card (persists until next session)
    if (widget.teacherFinalizedAbsent) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10.0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppStyles.errorRed.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: AppStyles.errorRed.withValues(alpha: 0.25),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppStyles.errorRed.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.cancel_rounded,
                  color: AppStyles.errorRed,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Marked Absent',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: AppStyles.errorRed,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${widget.absentPeriod} — ${widget.absentSubject}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppStyles.errorRed.withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'You were not present for this class',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppStyles.errorRed.withValues(alpha: 0.7),
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

    // Attendance already marked — amber pending card
    if (_hasMarkedAttendance) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12.0, top: 4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.orange.shade300.withValues(alpha: 0.3),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.orange.shade100.withValues(alpha: 0.5),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.orange.shade200.withValues(alpha: 0.5),
                  ),
                ),
                child: const _AnimatedHourglass(),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Attendance Submitted',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: AppStyles.textDark,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$_periodInfo — $_subjectName',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppStyles.textGray,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Waiting for teacher to finalize',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Colors.orange.shade800,
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
      padding: const EdgeInsets.only(bottom: 10.0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          color: themeColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: themeColor.withValues(alpha: 0.25),
            width: 1.5,
          ),
          boxShadow: glowOpacity > 0
              ? [
                  BoxShadow(
                    color: themeColor.withValues(alpha: glowOpacity),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
              : [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Row 1: Status + Timer pill ─────────────────────
            Row(
              children: [
                _PulsingDot(color: themeColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                          color: themeColor.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Pulsing timer pill
                ScaleTransition(
                  scale: _timerPulseAnim,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: themeColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.timer_outlined, size: 14, color: themeColor),
                        const SizedBox(width: 4),
                        Text(
                          '$minutes:$seconds',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: themeColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Row 2: Period info ─────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.menu_book_rounded,
                    size: 15,
                    color: AppStyles.textGray,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$_periodInfo — $_subjectName',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppStyles.textGray,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ── CTA with press scale ──────────────────────────
            GestureDetector(
              onTapDown: (_) => setState(() => _ctaPressed = true),
              onTapUp: (_) {
                setState(() => _ctaPressed = false);
                // Pass absolute end time for perfect timer sync
                final endTime = DateTime.now().add(
                  Duration(seconds: _secondsRemaining),
                );
                Navigator.of(
                  context,
                ).pushNamed('/qr-precheck', arguments: endTime);
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
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text(
                      'Scan QR Now',
                      style: TextStyle(fontWeight: FontWeight.w700),
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

    // ── Colors ──────────────────────────────────────────
    final Color accentColor = isCurrent
        ? theme.primaryColor
        : isDone
        ? AppStyles.successGreen
        : isAbsent
        ? AppStyles.errorRed
        : theme.primaryColor;

    final Color cardBg = isCurrent
        ? theme.primaryColor.withValues(alpha: isDark ? 0.28 : 0.09)
        : isDone
        ? AppStyles.successGreen.withValues(alpha: isDark ? 0.18 : 0.07)
        : isAbsent
        ? AppStyles.errorRed.withValues(alpha: isDark ? 0.18 : 0.07)
        : theme.primaryColor.withValues(alpha: isDark ? 0.10 : 0.05);

    // Subject name color
    final Color textPrimary = isCurrent
        ? theme.primaryColor
        : isDone
        ? AppStyles.successGreen
        : isAbsent
        ? AppStyles.errorRed
        : theme.primaryColor;

    // Period info + teacher name color
    final Color textSecondary = isCurrent
        ? theme.primaryColor.withValues(alpha: 0.75)
        : isDone
        ? AppStyles.successGreen.withValues(alpha: 0.75)
        : isAbsent
        ? AppStyles.errorRed.withValues(alpha: 0.75)
        : AppStyles.textGray;

    // ── Strip config ─────────────────────────────────────
    final Color stripBg = isCurrent
        ? theme.primaryColor
        : isDone
        ? AppStyles.successGreen
        : isAbsent
        ? AppStyles.errorRed
        : theme.primaryColor.withValues(alpha: isDark ? 0.18 : 0.10);

    final Color stripText = isCurrent || isDone || isAbsent
        ? Colors.white
        : theme.primaryColor;

    final String stripLabel = isCurrent
        ? '● Live Now'
        : isDone
        ? '✓  Attended'
        : isAbsent
        ? '✗  Absent'
        : 'Upcoming';

    // ── Watermark icon for done/absent ───────────────────
    final IconData? watermarkIcon = isDone
        ? Icons.check_circle_outline_rounded
        : isAbsent
        ? Icons.cancel_outlined
        : isCurrent
        ? Icons.radio_button_checked_rounded
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
                            const SizedBox(height: 5),
                            // Faculty name — always directly below subject
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
          .select('status')
          .eq('student_id', user.id)
          .inFilter('session_id', ids)
          .inFilter('status', ['present', 'absent']);
      final total = records.length;
      final present = records.where((r) => r['status'] == 'present').length;
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
          ? 'Off Campus'
          : widget.status == 'off'
          ? 'Location Off'
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
  final List<bool?> weekDays; // Mon–Sat: true=present, false=absent, null=future
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

  static const List<String> _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

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
        border: Border.all(
          color: color.withValues(alpha: 0.30),
          width: 1.5,
        ),
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
                                  color: color.withValues(alpha: _glowAnim.value * 0.8),
                                  blurRadius: 14 + (_glowAnim.value * 14),
                                  spreadRadius: 2 + (_glowAnim.value * 3),
                                ),
                                BoxShadow(
                                  color: Colors.orange.withValues(alpha: _glowAnim.value * 0.4),
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
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12 + (_glowAnim.value * 0.08)),
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
          Divider(height: 1, thickness: 1, color: color.withValues(alpha: 0.15)),
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
                            animation: Listenable.merge([_glowAnim, _fireScaleAnim]),
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
                                      color: color.withValues(alpha: _glowAnim.value * 0.5),
                                      blurRadius: 8 + (_glowAnim.value * 6),
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Transform.scale(
                                    scale: _fireScaleAnim.value,
                                    child: const Text('🔥', style: TextStyle(fontSize: 16)),
                                  ),
                                ),
                              );
                            },
                          )
                        : isAbsent
                        ? Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.red.shade400,
                                width: 2.5,
                              ),
                            ),
                            child: Center(
                              child: Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: Colors.red.shade500,
                              ),
                            ),
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
                        fontWeight: FontWeight.w700,
                        color: isPresent
                            ? color
                            : isAbsent
                            ? Colors.red.shade500
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
