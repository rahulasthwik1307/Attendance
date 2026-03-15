import 'dart:async';
import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class AttendanceSuccessScreen extends StatefulWidget {
  const AttendanceSuccessScreen({super.key});

  @override
  State<AttendanceSuccessScreen> createState() =>
      _AttendanceSuccessScreenState();
}

class _AttendanceSuccessScreenState extends State<AttendanceSuccessScreen>
    with TickerProviderStateMixin {
  late AnimationController _checkController;
  late Animation<double> _scaleAnimation;
  late AnimationController _rippleController;

  // Progress bar for redirect
  static const int _redirectDuration = 4;
  double _progress = 0.0;
  int _elapsed = 0;
  late Timer _timer;
  late String _markedAtTime;
  late String _markedAtDate;

  @override
  void initState() {
    super.initState();

    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _checkController, curve: Curves.elasticOut),
    );

    // Single radial glow pulse — play once, not repeat
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..forward();

    _checkController.forward();

    final now = DateTime.now();
    final hour = now.hour > 12
        ? now.hour - 12
        : now.hour == 0
        ? 12
        : now.hour;
    final minute = now.minute.toString().padLeft(2, '0');
    final period = now.hour >= 12 ? 'PM' : 'AM';
    _markedAtTime = '$hour:$minute $period';

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
    _markedAtDate = '${months[now.month - 1]} ${now.day}, ${now.year}';

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      _elapsed++;
      setState(() {
        _progress = _elapsed / _redirectDuration;
      });
      if (_elapsed >= _redirectDuration) {
        timer.cancel();
        Navigator.of(context).pushReplacementNamed('/dashboard');
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _checkController.dispose();
    _rippleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: AppStyles.textDark),
          onPressed: () =>
              Navigator.of(context).pushReplacementNamed('/dashboard'),
        ),
        title: const Text(
          'Smart Attendance',
          style: TextStyle(
            color: AppStyles.textDark,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 16),
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        // Single radial glow pulse
                        AnimatedBuilder(
                          animation: _rippleController,
                          builder: (context, child) {
                            return Container(
                              width: 110 + (_rippleController.value * 40),
                              height: 110 + (_rippleController.value * 40),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppStyles.successGreen.withValues(
                                  alpha: (1 - _rippleController.value) * 0.15,
                                ),
                              ),
                            );
                          },
                        ),
                        ScaleTransition(
                          scale: _scaleAnimation,
                          child: Container(
                            padding: const EdgeInsets.all(18),
                            decoration: const BoxDecoration(
                              color: AppStyles.successGreen,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check_rounded,
                              size: 48,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const FadeSlideY(
                      delay: Duration(milliseconds: 300),
                      child: Text(
                        'You are marked Present!',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppStyles.textDark,
                        ),
                      ),
                    ),
                    const FadeSlideY(
                      delay: Duration(milliseconds: 400),
                      child: Padding(
                        padding: EdgeInsets.only(top: 8.0),
                        child: Text(
                          'Face verification successful',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            color: AppStyles.textGray,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Detail card (matching qr_success_screen style) ──────
                    AnimatedOpacity(
                      opacity: 1.0,
                      duration: const Duration(milliseconds: 400),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.black.withValues(alpha: 0.06),
                          ),
                          boxShadow: isDark
                              ? []
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                        ),
                        child: Column(
                          children: [
                            _DetailRow(
                              icon: Icons.access_time_filled_rounded,
                              iconColor: Colors.purple.shade400,
                              label: 'Marked At',
                              value: _markedAtTime,
                              valueSubtitle: _markedAtDate,
                            ),
                            _divider(isDark),
                            _DetailRow(
                              icon: Icons.verified_user_rounded,
                              iconColor: AppStyles.successGreen,
                              label: 'Face Verified',
                              value: 'Confirmed ✔',
                              valueColor: AppStyles.successGreen,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ── Progress bar + redirect text ─────────────────
                    FadeSlideY(
                      delay: const Duration(milliseconds: 600),
                      child: Column(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: SizedBox(
                              height: 3,
                              width: double.infinity,
                              child: LinearProgressIndicator(
                                value: _progress,
                                backgroundColor: isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : Colors.black.withValues(alpha: 0.06),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  AppStyles.primaryBlue,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Redirecting to dashboard…',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppStyles.textGray.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // ── Dashboard button pinned at bottom ──────────────
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                height: 52,
                width: double.infinity,
                child: AnimatedButton(
                  onPressed: () {
                    _timer.cancel();
                    Navigator.of(context).pushReplacementNamed('/dashboard');
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppStyles.successGreen,
                    elevation: 2,
                  ),
                  child: const Text('Go to Dashboard'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider(bool isDark) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 56,
      color: isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.05),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final String? valueSubtitle;
  final Color? valueColor;

  const _DetailRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.valueSubtitle,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Icon
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          // Label — fixed width, left aligned, never truncates
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppStyles.textGray,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // Value — takes remaining space, right aligned
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: valueColor ??
                        (theme.textTheme.bodyLarge?.color ?? AppStyles.textDark),
                  ),
                  textAlign: TextAlign.end,
                  softWrap: true,
                ),
                if (valueSubtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    valueSubtitle!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppStyles.textGray,
                    ),
                    textAlign: TextAlign.end,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
