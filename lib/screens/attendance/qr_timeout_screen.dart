import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class QrTimeoutScreen extends StatefulWidget {
  final bool isTimeout;
  const QrTimeoutScreen({super.key, required this.isTimeout});

  @override
  State<QrTimeoutScreen> createState() => _QrTimeoutScreenState();
}

class _QrTimeoutScreenState extends State<QrTimeoutScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _iconController;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _iconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _scaleAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _iconController, curve: Curves.elasticOut),
    );
    _iconController.forward();
  }

  @override
  void dispose() {
    _iconController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bool isTimeout = widget.isTimeout;

    final Color accentColor = isTimeout
        ? const Color(0xFFD97706) // Muted warm amber
        : AppStyles.errorRed;
    final Color badgeBg = isTimeout
        ? const Color(0xFFFEF3C7)
        : const Color(0xFFFEE2E2);

    final IconData heroIcon = isTimeout
        ? Icons.timer_off_rounded
        : Icons.face_retouching_off_rounded;
    final String title = isTimeout ? 'Session Expired' : 'Verification Failed';
    final String message = isTimeout
        ? 'You did not complete face verification within the allowed time. Please restart the attendance process.'
        : 'Face verification could not be confirmed. Your attendance could not be marked for this period.';

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // ── Animated icon badge ────────────────────────────
                  ScaleTransition(
                    scale: _scaleAnim,
                    child: Container(
                      width: 92,
                      height: 92,
                      decoration: BoxDecoration(
                        color: isDark
                            ? accentColor.withValues(alpha: 0.15)
                            : badgeBg,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: accentColor.withValues(
                            alpha: isDark ? 0.3 : 0.2,
                          ),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: accentColor.withValues(
                              alpha: isDark ? 0.2 : 0.12,
                            ),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            color: isDark
                                ? accentColor.withValues(alpha: 0.3)
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
                          child: Icon(heroIcon, color: accentColor, size: 28),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Title ──────────────────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 250),
                    child: Text(
                      title,
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
                  const SizedBox(height: 10),

                  // ── Message ────────────────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 350),
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark
                            ? Colors.grey.shade400
                            : AppStyles.textGray,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Warning info card ──────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 450),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
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
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFFF59E0B,
                              ).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: const Icon(
                              Icons.info_outline_rounded,
                              color: Color(0xFFD97706),
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Contact your instructor or class teacher if you believe this is an error.',
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark
                                    ? Colors.grey.shade400
                                    : AppStyles.textGray,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── Dashboard button ───────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 550),
                    child: SizedBox(
                      width: double.infinity,
                      child: AnimatedButton(
                        onPressed: () => Navigator.of(
                          context,
                        ).pushReplacementNamed('/dashboard'),
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
                          'Return to Dashboard',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
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
}
