import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
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
        ? Colors.orange.shade700
        : AppStyles.errorRed;
    final IconData heroIcon = isTimeout
        ? Icons.timer_off_rounded
        : Icons.face_retouching_off;
    final String title = isTimeout ? 'Session Expired' : 'Verification Failed';
    final String message = isTimeout
        ? 'You did not complete face verification within 60 seconds. Your session has been invalidated.'
        : 'Face verification failed after 3 attempts. Your attendance could not be marked for this period.';

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
                  // ── Animated icon ──────────────────────────────────
                  ScaleTransition(
                    scale: _scaleAnim,
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: accentColor,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(heroIcon, color: Colors.white, size: 44),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── Title ──────────────────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 300),
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color:
                            theme.textTheme.displayLarge?.color ??
                            AppStyles.textDark,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Message ────────────────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 400),
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        color: AppStyles.textGray,
                        height: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── Warning info card ──────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 500),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.orange.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.orange.shade700,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Please contact your instructor or class teacher if you believe this is an error.',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppStyles.textGray,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // ── Dashboard button ───────────────────────────────
                  FadeSlideY(
                    delay: const Duration(milliseconds: 600),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
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
}
