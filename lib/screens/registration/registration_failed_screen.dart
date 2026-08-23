import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class RegistrationFailedScreen extends StatefulWidget {
  final String? subtitle;

  const RegistrationFailedScreen({super.key, this.subtitle});

  @override
  State<RegistrationFailedScreen> createState() =>
      _RegistrationFailedScreenState();
}

class _RegistrationFailedScreenState extends State<RegistrationFailedScreen>
    with TickerProviderStateMixin {
  late AnimationController _iconController;
  late Animation<double> _scaleAnimation;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _iconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _iconController, curve: Curves.elasticOut),
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _iconController.forward();
  }

  @override
  void dispose() {
    _iconController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  String _getSubtitle() {
    if (widget.subtitle != null && widget.subtitle!.trim().isNotEmpty) {
      return widget.subtitle!;
    }
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['subtitle'] is String) {
      return args['subtitle'] as String;
    } else if (args is String && args.trim().isNotEmpty) {
      return args;
    }
    return "We couldn't complete your face registration.\nPlease check your connection and try again.";
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final headingColor =
        theme.textTheme.displayLarge?.color ?? AppStyles.textDark;
    final bodyColor =
        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray;
    final cardBgColor = isDark ? AppStyles.surfaceDark : Colors.white;
    final cardBorderColor = isDark
        ? Colors.white12
        : const Color(0xFFE2E8F0);
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFF1F5F9);
    final homeBorderColor = isDark
        ? AppStyles.primaryBlue.withValues(alpha: 0.55)
        : AppStyles.primaryBlue.withValues(alpha: 0.35);
    final homeBgColor = isDark
        ? AppStyles.primaryBlue.withValues(alpha: 0.12)
        : AppStyles.primaryBlue.withValues(alpha: 0.05);

    final subtitleText = _getSubtitle();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pushReplacementNamed('/home');
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          toolbarHeight: 44,
          leading: IconButton(
            icon: Icon(
              Icons.close_rounded,
              color: isDark ? Colors.white70 : AppStyles.textDark,
              size: 24,
            ),
            onPressed: () =>
                Navigator.of(context).pushReplacementNamed('/home'),
          ),
        ),
        body: SafeArea(
          child: CustomScrollView(
            physics: const ClampingScrollPhysics(),
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Top & Middle Section ─────────────────────────────
                      const SizedBox(height: 4),

                      // ── Failure Visual with Pulsing Glow ─────────────
                      Center(
                        child: AnimatedBuilder(
                          animation: _pulseController,
                          builder: (context, child) {
                            final glowOpacity =
                                0.16 + (0.12 * _pulseController.value);
                            final glowSpread =
                                3.0 + (3.0 * _pulseController.value);
                            return Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: AppStyles.errorRed.withValues(
                                      alpha: glowOpacity,
                                    ),
                                    blurRadius: 22,
                                    spreadRadius: glowSpread,
                                  ),
                                ],
                              ),
                              child: child,
                            );
                          },
                          child: ScaleTransition(
                            scale: _scaleAnimation,
                            child: Container(
                              width: 68,
                              height: 68,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFFEF4444),
                                    AppStyles.errorRed,
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppStyles.errorRed.withValues(
                                      alpha: 0.3,
                                    ),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: const Center(
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 38,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // ── Title ────────────────────────────────────────
                      FadeSlideY(
                        delay: const Duration(milliseconds: 120),
                        child: Text(
                          'Registration Failed',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                            color: headingColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),

                      // ── Subtitle ─────────────────────────────────────
                      FadeSlideY(
                        delay: const Duration(milliseconds: 200),
                        child: Text(
                          subtitleText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.45,
                            color: bodyColor,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ── Expanded & Attractive Tips Card ──────────────
                      Expanded(
                        child: FadeSlideY(
                          delay: const Duration(milliseconds: 280),
                          child: Container(
                            decoration: BoxDecoration(
                              color: cardBgColor,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: cardBorderColor,
                                width: 1.0,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: isDark ? 0.25 : 0.04,
                                  ),
                                  blurRadius: 16,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 16,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Card Header
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(7),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFEF3C7),
                                        borderRadius:
                                            BorderRadius.circular(8),
                                      ),
                                      child: const Icon(
                                        Icons.lightbulb_rounded,
                                        size: 16,
                                        color: Color(0xFFD97706),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Quick tips for retry',
                                      style: TextStyle(
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w700,
                                        color: headingColor,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                  ],
                                ),
                                Divider(
                                  height: 16,
                                  thickness: 1,
                                  color: dividerColor,
                                ),
                                // Tip 1
                                _buildTipItem(
                                  icon: Icons.wb_sunny_rounded,
                                  iconBgColor: AppStyles.primaryBlue
                                      .withValues(alpha: 0.1),
                                  iconColor: AppStyles.primaryBlue,
                                  title: 'Lighting & Visibility',
                                  subtitle:
                                      'Keep full face visible with clear, even lighting',
                                  titleColor: headingColor,
                                  subtitleColor: bodyColor,
                                ),
                                Divider(
                                  height: 16,
                                  thickness: 1,
                                  color: dividerColor,
                                ),
                                // Tip 2
                                _buildTipItem(
                                  icon: Icons.visibility_off_outlined,
                                  iconBgColor: const Color(0xFF8B5CF6)
                                      .withValues(alpha: 0.12),
                                  iconColor: const Color(0xFF8B5CF6),
                                  title: 'Remove Accessories',
                                  subtitle:
                                      'Remove sunglasses, masks, or obstructing hats',
                                  titleColor: headingColor,
                                  subtitleColor: bodyColor,
                                ),
                                Divider(
                                  height: 16,
                                  thickness: 1,
                                  color: dividerColor,
                                ),
                                // Tip 3
                                _buildTipItem(
                                  icon: Icons.stay_current_portrait_rounded,
                                  iconBgColor: AppStyles.successGreen
                                      .withValues(alpha: 0.12),
                                  iconColor: AppStyles.successGreen,
                                  title: 'Camera Stability',
                                  subtitle:
                                      'Hold phone steady; ensure only one face in frame',
                                  titleColor: headingColor,
                                  subtitleColor: bodyColor,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 18),

                      // ── Bottom Action Buttons ────────────────────────
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // ── Primary Action: Try Again ────────────────────
                          FadeSlideY(
                            delay: const Duration(milliseconds: 360),
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppStyles.primaryBlue.withValues(
                                      alpha: 0.28,
                                    ),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: AnimatedButton(
                                onPressed: () => Navigator.of(
                                  context,
                                ).pushReplacementNamed('/register'),
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 15,
                                  ),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.refresh_rounded,
                                      size: 20,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'Try Again',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                        letterSpacing: 0.1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),

                          // ── Secondary Action: Go to Home ─────────────────
                          FadeSlideY(
                            delay: const Duration(milliseconds: 440),
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(
                                context,
                              ).pushReplacementNamed('/home'),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                backgroundColor: homeBgColor,
                                side: BorderSide(
                                  color: homeBorderColor,
                                  width: 1.5,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.home_outlined,
                                    size: 19,
                                    color: AppStyles.primaryBlue,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Go to Home',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: AppStyles.primaryBlue,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTipItem({
    required IconData icon,
    required Color iconBgColor,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Color titleColor,
    required Color subtitleColor,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: iconBgColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Icon(
              icon,
              size: 20,
              color: iconColor,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: subtitleColor,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
