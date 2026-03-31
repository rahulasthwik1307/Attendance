import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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

  @override
  void initState() {
    super.initState();
    _fetchProfile();
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
    } catch (e) {
      debugPrint('Error fetching profile: $e');
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
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hello, ${_studentName.split(' ').first} 👋',
                style: TextStyle(
                  color:
                      theme.textTheme.displayLarge?.color ?? AppStyles.textDark,
                  fontWeight: FontWeight.bold,
                  fontSize: 24,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout_rounded, color: AppStyles.errorRed),
              onPressed: () =>
                  Navigator.of(context).pushReplacementNamed('/home'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 16.0,
            ),
            children: [
              FadeSlideY(
                delay: const Duration(milliseconds: 50),
                child: const _AttendanceBanner(),
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
                delay: const Duration(milliseconds: 400),
                child: _ActionTile(
                  label: 'Scan QR — Class Attendance',
                  subtitle: 'Scan QR code to mark period attendance',
                  icon: Icons.qr_code_scanner_rounded,
                  isDestructive: false,
                ),
              ),
              const SizedBox(height: 10),
              FadeSlideY(
                delay: const Duration(milliseconds: 460),
                child: _ActionTile(
                  label: 'Set Location',
                  subtitle: 'Update your attendance location',
                  icon: Icons.my_location_rounded,
                  isDestructive: false,
                ),
              ),
              const SizedBox(height: 10),
              FadeSlideY(
                delay: const Duration(milliseconds: 520),
                child: _ActionTile(
                  label: 'Reset Face Data',
                  subtitle: 'Re-register your face securely',
                  icon: Icons.lock_reset_rounded,
                  isDestructive: false,
                ),
              ),
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

    _checkTodayAttendance();
  }

  Future<void> _checkTodayAttendance() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        final todayStr = DateTime.now().toIso8601String().split('T')[0];

        final record = await supabase
            .from('college_attendance')
            .select('id')
            .eq('student_id', user.id)
            .eq('date', todayStr)
            .maybeSingle();

        if (mounted) {
          setState(() {
            _isPresentToday = record != null;
            _isLoading = false;
          });
          _cardController.forward();
        }
      }
    } catch (e) {
      debugPrint('Error checking today attendance: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
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
        : AppStyles.amberWarning;
    final message = _isPresentToday
        ? 'You are Present Today'
        : 'Not Yet Marked';
    final iconData = _isPresentToday
        ? Icons.check_rounded
        : Icons.pending_actions_rounded;

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
                  color: color.withValues(alpha: 0.25),
                  shape: BoxShape.circle,
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
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (_isPresentToday)
                    Wrap(
                      spacing: 8,
                      children: [
                        _StatusPill(
                          icon: Icons.location_on_rounded,
                          label: 'Campus',
                          color: color,
                        ),
                        _StatusPill(
                          icon: Icons.face_retouching_natural_rounded,
                          label: 'Face Verified',
                          color: color,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 11),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
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

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _fetchAttendanceStats();
  }

  Future<void> _fetchAttendanceStats() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        final records = await supabase
            .from('period_attendance')
            .select('status')
            .eq('student_id', user.id)
            .inFilter('status', ['present', 'absent']);

        int total = records.length;
        int present = records.where((r) => r['status'] == 'present').length;
        double pct = total > 0 ? present / total : 0.0;

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
    final Color pctColor = AppStyles.successGreen;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 26, 20),
      decoration: BoxDecoration(
        color: (theme.cardTheme.color ?? Colors.white).withValues(alpha: 0.96),
        border: Border.all(
          color: pctColor.withValues(alpha: isDark ? 0.08 : 0.04),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: pctColor.withValues(alpha: isDark ? 0.08 : 0.05),
            blurRadius: 16,
            offset: const Offset(0, 4),
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
                                    ? 'Good Standing — Above 75% Requirement'
                                    : 'Warning — Below 75% Requirement',
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

class _HeroAttendanceCard extends StatelessWidget {
  final ThemeData theme;
  const _HeroAttendanceCard({required this.theme});

  @override
  Widget build(BuildContext context) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
      decoration: BoxDecoration(
        color: theme.primaryColor,
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.primaryColor,
            theme.primaryColor.withValues(alpha: 0.75),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: theme.primaryColor.withValues(alpha: isDark ? 0.3 : 0.25),
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
          const Text(
            '09:00 AM',
            style: TextStyle(
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
              const Text(
                'Oct 24, 2024 • Present',
                style: TextStyle(
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

class _ActionTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool isDestructive;

  const _ActionTile({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.isDestructive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isDestructive ? AppStyles.errorRed : theme.primaryColor;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () {
          if (label == 'Scan QR — Class Attendance') {
            // QR scanner will be implemented with backend
            return;
          }
          if (label == 'Reset Face Data') {
            showGeneralDialog(
              context: context,
              barrierDismissible: true,
              barrierLabel: 'Dismiss',
              transitionDuration: const Duration(milliseconds: 250),
              pageBuilder: (ctx, animation, secondaryAnimation) {
                return Dialog(
                  backgroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppStyles.errorRed.withValues(alpha: 0.09),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.face_retouching_off_rounded,
                            color: AppStyles.errorRed,
                            size: 32,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Reset Face Data?',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1A202C),
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'This will permanently delete your registered face. You will need to re-register before using face attendance again.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF4A5568),
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: AppStyles.textGray.withValues(
                                      alpha: 0.3,
                                    ),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 13,
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
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  Navigator.of(
                                    context,
                                  ).pushNamed('/reset_face_verify');
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppStyles.errorRed,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 13,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text(
                                  'Continue',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
              transitionBuilder: (ctx, animation, secondaryAnimation, child) {
                return FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.85, end: 1.0).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutBack,
                      ),
                    ),
                    child: child,
                  ),
                );
              },
            );
          }
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: theme.cardTheme.color ?? Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDestructive
                  ? AppStyles.errorRed.withValues(alpha: 0.2)
                  : color.withValues(alpha: 0.1),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color:
                            theme.textTheme.displayLarge?.color ??
                            AppStyles.textDark,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            theme.textTheme.bodyMedium?.color ??
                            AppStyles.textGray,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
                size: 20,
              ),
            ],
          ),
        ),
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

  static const List<Map<String, dynamic>> _periods = [
    {
      'period': '1st',
      'time': '09:15',
      'subject': 'Data Structures',
      'room': 'Room 201',
      'status': 'done',
    },
    {
      'period': '2nd',
      'time': '10:10',
      'subject': 'Operating Systems',
      'room': 'Room 105',
      'status': 'done',
    },
    {
      'period': '3rd',
      'time': '11:10',
      'subject': 'DBMS',
      'room': 'Room 301',
      'status': 'current',
    },
    {
      'period': '4th',
      'time': '12:00',
      'subject': 'Computer Networks',
      'room': 'Room 202',
      'status': 'upcoming',
    },
    {
      'period': '5th',
      'time': '01:30',
      'subject': 'Software Engg',
      'room': 'Room 104',
      'status': 'upcoming',
    },
  ];

  @override
  void initState() {
    super.initState();
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
                            ? 'Wednesday • 5 periods'
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
                  height: 118,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    itemCount: _periods.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final period = _periods[index];
                      final status = period['status'] as String;
                      final bool isDone = status == 'done';
                      final bool isCurrent = status == 'current';
                      final theme = widget.theme;
                      final isDark = widget.isDark;

                      final Color cardColor = isCurrent
                          ? theme.primaryColor
                          : (isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : AppStyles.backgroundLight);

                      final Color textPrimary = isCurrent
                          ? Colors.white
                          : (theme.textTheme.displayLarge?.color ??
                                AppStyles.textDark);

                      final Color textSecondary = isCurrent
                          ? Colors.white.withValues(alpha: 0.75)
                          : (theme.textTheme.bodyMedium?.color ??
                                AppStyles.textGray);

                      return Container(
                        width: 120,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(12),
                          border: isCurrent
                              ? null
                              : Border.all(
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : Colors.black.withValues(alpha: 0.07),
                                  width: 1,
                                ),
                          boxShadow: isCurrent
                              ? [
                                  BoxShadow(
                                    color: theme.primaryColor.withValues(
                                      alpha: 0.3,
                                    ),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ]
                              : [],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  period['period'] as String,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: textSecondary,
                                  ),
                                ),
                                if (isDone)
                                  Icon(
                                    Icons.check_circle_rounded,
                                    size: 13,
                                    color: AppStyles.successGreen.withValues(
                                      alpha: 0.7,
                                    ),
                                  )
                                else if (isCurrent)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.2,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      'Now',
                                      style: TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              period['time'] as String,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: textPrimary,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Expanded(
                              child: Text(
                                period['subject'] as String,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: textPrimary,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              period['room'] as String,
                              style: TextStyle(
                                fontSize: 10,
                                color: textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
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
  const _AttendanceBanner();

  @override
  State<_AttendanceBanner> createState() => _AttendanceBannerState();
}

class _AttendanceBannerState extends State<_AttendanceBanner>
    with SingleTickerProviderStateMixin {
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
              if (status == 'present' && mounted) {
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

      // 4. Subscribe to Realtime for this class
      _subscription = supabase
          .channel('public:attendance_sessions')
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
              final recordId = payload.newRecord['id'] as String?;
              if (recordId == _activeSessionId) {
                return;
              }
              debugPrint(
                'AttendanceBanner: Realtime event received: ${payload.eventType} data: ${payload.newRecord}',
              );
              _fetchActiveSession();
            },
          )
          .subscribe();
    } catch (e) {
      debugPrint('Error initializing realtime: $e');
    }
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
              .eq('status', 'present')
              .maybeSingle();
          debugPrint('Period attendance query result: $attendanceRecord');

          if (attendanceRecord != null &&
              attendanceRecord['status'] == 'present' &&
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
          _startTimer();
        } else {
          _closeBanner();
        }
      } else {
        // If session status changed to finalized or no active session exists
        _closeBanner();
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
    if (!_isVisible) return const SizedBox.shrink();

    // Attendance already marked — green card
    if (_hasMarkedAttendance) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10.0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppStyles.successGreen.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: AppStyles.successGreen.withValues(alpha: 0.25),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppStyles.successGreen.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  color: AppStyles.successGreen,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Attendance Marked',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: AppStyles.successGreen,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Attendance Marked for $_subjectName',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppStyles.successGreen.withValues(alpha: 0.8),
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
