import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math' as math;
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/custom_bottom_nav.dart';
import '../../widgets/fade_slide_y.dart';

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

  @override
  void initState() {
    super.initState();
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
                'Hello, Rahul 👋',
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

    // Short delay to allow screen to build before starting
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) _cardController.forward();
    });
  }

  @override
  void dispose() {
    _cardController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          color: AppStyles.successGreen.withValues(
            alpha: widget.isDark ? 0.15 : 0.07,
          ),
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
                  color: AppStyles.successGreen.withValues(alpha: 0.25),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: AppStyles.successGreen,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'You are Present Today',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      color: AppStyles.successGreen,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      _StatusPill(
                        icon: Icons.location_on_rounded,
                        label: 'Campus',
                        color: AppStyles.successGreen,
                      ),
                      _StatusPill(
                        icon: Icons.face_retouching_natural_rounded,
                        label: 'Face Verified',
                        color: AppStyles.successGreen,
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

  static const double _pct = 0.77;
  static const int _present = 144;
  static const int _total = 186;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _progressAnim = Tween<double>(
      begin: 0,
      end: _pct,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _counterAnim = IntTween(
      begin: 0,
      end: 77,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    Future.delayed(const Duration(milliseconds: 500), () {
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
      child: Row(
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
                        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
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
                        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray,
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
                          'Good Standing — Above 75% Requirement',
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
  int _secondsRemaining = 147;
  Timer? _timer;
  bool _isVisible = true;
  bool _isClosed = false;
  bool _ctaPressed = false;

  // Timer pill pulse
  late AnimationController _timerPulseController;
  late Animation<double> _timerPulseAnim;

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
    _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0) {
        setState(() => _secondsRemaining--);
        // Subtle pulse on each tick
        _timerPulseController.forward().then((_) {
          if (mounted) _timerPulseController.reverse();
        });
        if (_secondsRemaining == 0) {
          _closeBanner();
        }
      }
    });
  }

  void _closeBanner() {
    _timer?.cancel();
    if (!mounted) return;
    setState(() => _isClosed = true);
    // Auto-hide the closed banner after 4 seconds
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _isVisible = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timerPulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVisible) return const SizedBox.shrink();

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
                  const Text(
                    '3rd Period — DBMS',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppStyles.textGray,
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
