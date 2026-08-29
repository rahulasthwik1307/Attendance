import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class LocationErrorScreen extends StatefulWidget {
  const LocationErrorScreen({super.key});

  @override
  State<LocationErrorScreen> createState() => _LocationErrorScreenState();
}

class _LocationErrorScreenState extends State<LocationErrorScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

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
                child: AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 90 * _pulseAnimation.value,
                          height: 90 * _pulseAnimation.value,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppStyles.errorRed.withValues(
                              alpha: isDark ? 0.15 : 0.08,
                            ),
                          ),
                        ),
                        child!,
                      ],
                    );
                  },
                  child: Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: isDark
                          ? AppStyles.errorRed.withValues(alpha: 0.15)
                          : const Color(0xFFFEE2E2),
                      shape: BoxShape.circle,
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
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                        ),
                        child: const Icon(
                          Icons.location_off_rounded,
                          size: 30,
                          color: AppStyles.errorRed,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              FadeSlideY(
                delay: const Duration(milliseconds: 200),
                child: Text(
                  'Outside Campus Boundary',
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
                delay: const Duration(milliseconds: 300),
                child: Text(
                  'You must be physically present within the designated campus area to mark your attendance.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.grey.shade400 : AppStyles.textGray,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              FadeSlideY(
                delay: const Duration(milliseconds: 400),
                child: Container(
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
                            0xFF3B82F6,
                          ).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(
                          Icons.navigation_rounded,
                          color: AppStyles.primaryBlue,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Move closer to campus and ensure device location is active.',
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
              const Spacer(),
              FadeSlideY(
                delay: const Duration(milliseconds: 500),
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
                      'Back to Dashboard',
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
