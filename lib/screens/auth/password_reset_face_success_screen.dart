import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/fade_slide_y.dart';

class PasswordResetFaceSuccessScreen extends StatefulWidget {
  const PasswordResetFaceSuccessScreen({super.key});

  @override
  State<PasswordResetFaceSuccessScreen> createState() =>
      _PasswordResetFaceSuccessScreenState();
}

class _PasswordResetFaceSuccessScreenState
    extends State<PasswordResetFaceSuccessScreen>
    with TickerProviderStateMixin {
  late AnimationController _checkController;
  late Animation<double> _scaleAnimation;
  late AnimationController _rippleController;
  late AnimationController _ripple2Controller;

  @override
  void initState() {
    super.initState();

    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );

    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _checkController, curve: Curves.elasticOut),
    );

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _ripple2Controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    // Stagger second ripple by 900 ms
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) _ripple2Controller.repeat();
    });

    _checkController.forward();

    // Auto-navigate to set new password
    Future.delayed(const Duration(milliseconds: 2800), () {
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/set_new_password');
      }
    });
  }

  @override
  void dispose() {
    _checkController.dispose();
    _rippleController.dispose();
    _ripple2Controller.dispose();
    super.dispose();
  }

  Widget _buildRipple(AnimationController ctrl) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, child) {
        return Container(
          width: 130 + ctrl.value * 70,
          height: 130 + ctrl.value * 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppStyles.primaryBlue.withValues(
              alpha: (1 - ctrl.value) * 0.18,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headingColor =
        theme.textTheme.displayLarge?.color ?? AppStyles.textDark;
    final subtitleColor =
        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),

              // ── Ripple + Check Icon ────────────────────────────────────────
              Stack(
                alignment: Alignment.center,
                children: [
                  _buildRipple(_rippleController),
                  _buildRipple(_ripple2Controller),
                  ScaleTransition(
                    scale: _scaleAnimation,
                    child: Container(
                      padding: const EdgeInsets.all(26),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppStyles.primaryBlue,
                            AppStyles.primaryBlue.withValues(alpha: 0.75),
                          ],
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppStyles.primaryBlue.withValues(alpha: 0.4),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.verified_user_rounded,
                        size: 58,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 36),

              // ── Heading ────────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 400),
                child: Text(
                  'Identity Verified',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: headingColor,
                    letterSpacing: -0.4,
                  ),
                ),
              ),

              // ── Sub-text ───────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 500),
                child: Padding(
                  padding: const EdgeInsets.only(top: 10.0),
                  child: Text(
                    'Your face matches.\nSet your new password now.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.55,
                      color: subtitleColor,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 36),

              // ── Progress Indicator ─────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 600),
                child: Column(
                  children: [
                    Text(
                      'Redirecting to set your password…',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: subtitleColor.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppStyles.primaryBlue.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
