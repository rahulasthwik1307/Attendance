import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class AttendanceFailedScreen extends StatefulWidget {
  const AttendanceFailedScreen({super.key});

  @override
  State<AttendanceFailedScreen> createState() => _AttendanceFailedScreenState();
}

class _AttendanceFailedScreenState extends State<AttendanceFailedScreen>
    with TickerProviderStateMixin {
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;
  late AnimationController _rippleController;

  @override
  void initState() {
    super.initState();

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    // Shake animation logic
    _shakeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..forward();

    _shakeController.forward();
  }

  @override
  void dispose() {
    _shakeController.dispose();
    _rippleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final String? mode = ModalRoute.of(context)?.settings.arguments as String?;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: AppStyles.textDark),
          onPressed: () =>
              Navigator.of(context).pushReplacementNamed('/dashboard'),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _rippleController,
                      builder: (context, child) {
                        return Container(
                          width: 110 + (_rippleController.value * 36),
                          height: 110 + (_rippleController.value * 36),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppStyles.errorRed.withValues(
                              alpha: (1 - _rippleController.value) * 0.12,
                            ),
                          ),
                        );
                      },
                    ),
                    AnimatedBuilder(
                      animation: _shakeAnimation,
                      builder: (context, child) {
                        final sineValue = math.sin(
                          _shakeAnimation.value * math.pi * 3,
                        );
                        return Transform.translate(
                          offset: Offset(sineValue * 12, 0),
                          child: child,
                        );
                      },
                      child: Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDark
                              ? AppStyles.errorRed.withValues(alpha: 0.15)
                              : const Color(0xFFFEE2E2),
                          border: Border.all(
                            color: AppStyles.errorRed.withValues(
                              alpha: isDark ? 0.3 : 0.2,
                            ),
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppStyles.errorRed.withValues(
                                alpha: isDark ? 0.2 : 0.1,
                              ),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? AppStyles.errorRed.withValues(alpha: 0.35)
                                  : Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: isDark
                                  ? null
                                  : [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.04,
                                        ),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 32,
                              color: AppStyles.errorRed,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              FadeSlideY(
                delay: const Duration(milliseconds: 250),
                child: Text(
                  'Verification Failed',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color:
                        theme.textTheme.displayLarge?.color ??
                        AppStyles.textDark,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FadeSlideY(
                delay: const Duration(milliseconds: 320),
                child: Text(
                  mode == 'forgot_password'
                      ? 'We could not verify your identity. Please try again in good lighting.'
                      : 'Face did not match the registered profile. Please try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.grey.shade400 : AppStyles.textGray,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // ── Tips card ─────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 420),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : const Color(0xFFE2E8F0),
                    ),
                    boxShadow: isDark
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF3B82F6,
                              ).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.lightbulb_outline_rounded,
                              color: AppStyles.primaryBlue,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Tips for successful verification',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color:
                                  theme.textTheme.bodyLarge?.color ??
                                  AppStyles.textDark,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _TipItem(
                        text: 'Ensure your face is well-lit without backlighting',
                        isDark: isDark,
                      ),
                      const SizedBox(height: 6),
                      _TipItem(
                        text: 'Look straight at the camera and keep steady',
                        isDark: isDark,
                      ),
                      const SizedBox(height: 6),
                      _TipItem(
                        text: 'Remove sunglasses, heavy masks, or hats',
                        isDark: isDark,
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              FadeSlideY(
                delay: const Duration(milliseconds: 550),
                child: SizedBox(
                  width: double.infinity,
                  child: AnimatedButton(
                    onPressed: () {
                      if (mode == 'forgot_password') {
                        Navigator.of(
                          context,
                        ).pushReplacementNamed('/forgot_password_face_verify');
                      } else {
                        Navigator.of(
                          context,
                        ).pushReplacementNamed('/face_verification');
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppStyles.primaryBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Try Again',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _TipItem extends StatelessWidget {
  final String text;
  final bool isDark;

  const _TipItem({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5.0, right: 8.0),
          child: Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? Colors.grey.shade400 : AppStyles.textGray,
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.grey.shade400 : AppStyles.textGray,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
