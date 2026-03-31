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
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 40),
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        // Single radial glow pulse
                        AnimatedBuilder(
                          animation: _rippleController,
                          builder: (context, child) {
                            return Container(
                              width: 150 + (_rippleController.value * 50),
                              height: 150 + (_rippleController.value * 50),
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
                            padding: const EdgeInsets.all(24),
                            decoration: const BoxDecoration(
                              color: AppStyles.successGreen,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check_rounded,
                              size: 60,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
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
                    const SizedBox(height: 32),

                    // ── Detail card (matching qr_success_screen style) ──────
                    FadeSlideY(
                      delay: const Duration(milliseconds: 500),
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
                              icon: Icons.menu_book_rounded,
                              iconColor: AppStyles.primaryBlue,
                              label: 'Subject',
                              value: 'DBMS',
                            ),
                            _divider(isDark),
                            _DetailRow(
                              icon: Icons.schedule_rounded,
                              iconColor: Colors.orange.shade600,
                              label: 'Period',
                              value: '3rd Period',
                              valueSubtitle: '11:10 AM',
                            ),
                            _divider(isDark),
                            _DetailRow(
                              icon: Icons.access_time_filled_rounded,
                              iconColor: Colors.purple.shade400,
                              label: 'Marked At',
                              value: '09:05 AM',
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
                    const SizedBox(height: 24),

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
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            // ── Dashboard button pinned at bottom ──────────────
            Container(
              padding: const EdgeInsets.all(16),
              child: FadeSlideY(
                delay: const Duration(milliseconds: 700),
                child: SizedBox(
                  height: 48,
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 14),
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: AppStyles.textGray),
          ),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color:
                      valueColor ??
                      (theme.textTheme.bodyLarge?.color ?? AppStyles.textDark),
                ),
              ),
              if (valueSubtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  valueSubtitle!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppStyles.textGray,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
