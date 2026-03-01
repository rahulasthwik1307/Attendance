import 'package:flutter/material.dart';
import 'dart:async';
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class QrSuccessScreen extends StatefulWidget {
  const QrSuccessScreen({super.key});

  @override
  State<QrSuccessScreen> createState() => _QrSuccessScreenState();
}

class _QrSuccessScreenState extends State<QrSuccessScreen>
    with TickerProviderStateMixin {
  late AnimationController _checkController;
  late Animation<double> _scaleAnim;
  late AnimationController _rippleController;
  Timer? _timer;

  // Progress line instead of "Redirecting in X seconds..."
  static const int _redirectDuration = 3;
  double _progress = 0.0;
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();

    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scaleAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _checkController, curve: Curves.elasticOut),
    );

    // Single radial glow pulse
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..forward();

    _checkController.forward();

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _elapsed++;
      setState(() => _progress = _elapsed / _redirectDuration);
      if (_elapsed >= _redirectDuration) {
        _goToDashboard();
      }
    });
  }

  void _goToDashboard() {
    _timer?.cancel();
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/dashboard');
  }

  @override
  void dispose() {
    _checkController.dispose();
    _rippleController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ── Animated checkmark with radial glow ────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 0),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Single radial glow pulse
                        AnimatedBuilder(
                          animation: _rippleController,
                          builder: (context, child) {
                            return Container(
                              width: 130 + (_rippleController.value * 40),
                              height: 130 + (_rippleController.value * 40),
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
                          scale: _scaleAnim,
                          child: Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: AppStyles.successGreen.withValues(
                                alpha: 0.12,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: const BoxDecoration(
                                color: AppStyles.successGreen,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.check_rounded,
                                color: Colors.white,
                                size: 48,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // ── Title ──────────────────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 250),
                    child: Text(
                      'Attendance Marked!',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color:
                            theme.textTheme.displayLarge?.color ??
                            AppStyles.textDark,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // ── Details card ───────────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 450),
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
                            value: '11:14 AM',
                          ),
                          _divider(isDark),
                          _DetailRow(
                            icon: Icons.verified_user_rounded,
                            iconColor: AppStyles.successGreen,
                            label: 'Face Verified',
                            value: 'Confirmed ✓',
                            valueColor: AppStyles.successGreen,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── Thin progress line (replaces countdown text) ───
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
                  const SizedBox(height: 24),

                  // ── Dashboard button with elevation & bounce ───────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 700),
                    child: SizedBox(
                      width: double.infinity,
                      child: AnimatedButton(
                        onPressed: _goToDashboard,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppStyles.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 2,
                        ),
                        child: const Text(
                          'Go to Dashboard',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
