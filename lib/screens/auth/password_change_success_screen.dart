import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/fade_slide_y.dart';

class PasswordChangeSuccessScreen extends StatefulWidget {
  const PasswordChangeSuccessScreen({super.key});

  @override
  State<PasswordChangeSuccessScreen> createState() =>
      _PasswordChangeSuccessScreenState();
}

class _PasswordChangeSuccessScreenState
    extends State<PasswordChangeSuccessScreen>
    with TickerProviderStateMixin {
  late AnimationController _checkController;
  late Animation<double> _scaleAnimation;
  late AnimationController _rippleController;

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

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _checkController.forward();

    // Auto-redirect to Sign In after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/sign_in');
      }
    });
  }

  @override
  void dispose() {
    _checkController.dispose();
    _rippleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final headingColor = isDark
        ? Colors.white.withValues(alpha: 0.95)
        : AppStyles.textDark;
    final subtitleColor = isDark ? Colors.grey.shade400 : AppStyles.textGray;
    final surfaceColor = isDark ? AppStyles.surfaceDark : Colors.white;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),

                // ── Ripple + Check Animation ──────────────────────────────────
                Stack(
                  alignment: Alignment.center,
                  children: [
                    // Expanding ripple
                    AnimatedBuilder(
                      animation: _rippleController,
                      builder: (context, child) {
                        return Container(
                          width: 150 + (_rippleController.value * 60),
                          height: 150 + (_rippleController.value * 60),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppStyles.successGreen.withValues(
                              alpha: (1 - _rippleController.value) * 0.25,
                            ),
                          ),
                        );
                      },
                    ),
                    // Second ripple (offset in phase)
                    AnimatedBuilder(
                      animation: _rippleController,
                      builder: (context, child) {
                        final offset = (_rippleController.value + 0.5) % 1.0;
                        return Container(
                          width: 150 + (offset * 60),
                          height: 150 + (offset * 60),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppStyles.successGreen.withValues(
                              alpha: (1 - offset) * 0.15,
                            ),
                          ),
                        );
                      },
                    ),
                    // Checkmark circle
                    ScaleTransition(
                      scale: _scaleAnimation,
                      child: Container(
                        padding: const EdgeInsets.all(26),
                        decoration: BoxDecoration(
                          color: AppStyles.successGreen,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppStyles.successGreen.withValues(
                                alpha: 0.40,
                              ),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
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

                const SizedBox(height: 40),

                // ── Title ─────────────────────────────────────────────────────
                FadeSlideY(
                  delay: const Duration(milliseconds: 300),
                  child: Text(
                    'Password Updated!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: headingColor,
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // ── Subtitle ──────────────────────────────────────────────────
                FadeSlideY(
                  delay: const Duration(milliseconds: 400),
                  child: Text(
                    'Your password has been changed\nsuccessfully. You can now sign in.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: subtitleColor,
                    ),
                  ),
                ),
                const SizedBox(height: 36),

                // ── Info card ─────────────────────────────────────────────────
                FadeSlideY(
                  delay: const Duration(milliseconds: 500),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: surfaceColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppStyles.successGreen.withValues(alpha: 0.30),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.20 : 0.04,
                          ),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppStyles.successGreen.withValues(
                              alpha: 0.12,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.shield_rounded,
                            color: AppStyles.successGreen,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Account Secured',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: headingColor,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Redirecting you to Sign In…',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: subtitleColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Small animated countdown dot
                        AnimatedBuilder(
                          animation: _rippleController,
                          builder: (_, _) => Opacity(
                            opacity: 0.5 + _rippleController.value * 0.5,
                            child: const Icon(
                              Icons.circle,
                              size: 8,
                              color: AppStyles.successGreen,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const Spacer(),

                // ── Return to Sign In (manual tap) ────────────────────────────
                FadeSlideY(
                  delay: const Duration(milliseconds: 650),
                  child: TextButton(
                    onPressed: () =>
                        Navigator.of(context).pushReplacementNamed('/sign_in'),
                    child: Text(
                      'Go to Sign In now',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: theme.primaryColor,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
