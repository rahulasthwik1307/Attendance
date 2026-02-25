import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import '../../utils/app_styles.dart';
import '../../widgets/custom_bottom_nav.dart';
import '../../widgets/fade_slide_y.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with TickerProviderStateMixin {
  late AnimationController _borderRotationController;

  static const String _name = 'Rahul Sharma';
  static const String _rollNumber = '2021CS047';
  static const String _department = 'CSE — Computer Science';
  static const String _year = '3rd Year';
  static const double _attendancePct = 0.78;
  static const int _attendanceDays = 18;
  static const int _totalDays = 23;

  @override
  void initState() {
    super.initState();
    _borderRotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _borderRotationController.dispose();
    super.dispose();
  }

  void _onNavTap(int index) {
    if (index == 0) Navigator.of(context).pushReplacementNamed('/dashboard');
    if (index == 1) Navigator.of(context).pushReplacementNamed('/history');
    if (index == 2) Navigator.of(context).pushReplacementNamed('/settings');
    if (index == 3) return;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = theme.textTheme.displayLarge?.color ?? AppStyles.textDark;
    final cardColor = theme.cardTheme.color ?? Colors.white;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Dismiss',
          transitionDuration: const Duration(milliseconds: 250),
          pageBuilder: (context, animation, secondaryAnimation) {
            return Dialog(
              backgroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Exit App',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppStyles.textDark,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Are you sure you want to exit?',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppStyles.textGray,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: AppStyles.textGray.withValues(alpha: 0.3),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 12,
                            ),
                          ),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(
                              color: AppStyles.textGray,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () => SystemNavigator.pop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade600,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 12,
                            ),
                            elevation: 0,
                          ),
                          child: const Text(
                            'Exit',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
          transitionBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.85, end: 1.0).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                ),
                child: child,
              ),
            );
          },
        );
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          title: Text(
            'Profile',
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 24,
            ),
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 16.0,
            ),
            children: [
              FadeSlideY(
                delay: const Duration(milliseconds: 100),
                child: Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _borderRotationController,
                        builder: (context, child) {
                          return Transform.rotate(
                            angle:
                                _borderRotationController.value * 2 * math.pi,
                            child: Container(
                              width: 130,
                              height: 130,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: SweepGradient(
                                  colors: [
                                    AppStyles.primaryBlue,
                                    Colors.transparent,
                                  ],
                                  stops: [0.0, 0.5],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.primaryColor.withValues(alpha: 0.12),
                          border: Border.all(color: cardColor, width: 4),
                        ),
                        child: ClipOval(
                          child: Center(
                            child: Text(
                              'RS',
                              style: TextStyle(
                                fontSize: 36,
                                fontWeight: FontWeight.w800,
                                color: theme.primaryColor,
                                letterSpacing: -1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FadeSlideY(
                delay: const Duration(milliseconds: 200),
                child: Center(
                  child: Text(
                    _name,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              FadeSlideY(
                delay: const Duration(milliseconds: 260),
                child: Center(
                  child: Text(
                    _rollNumber,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppStyles.textGray,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Attendance percentage badge
              FadeSlideY(
                delay: const Duration(milliseconds: 320),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppStyles.successGreen.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: AppStyles.successGreen.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.trending_up_rounded,
                          size: 14,
                          color: AppStyles.successGreen,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${(_attendancePct * 100).round()}% Attendance — $_attendanceDays / $_totalDays Days',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppStyles.successGreen,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              FadeSlideY(
                delay: const Duration(milliseconds: 400),
                child: Container(
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      _buildInfoRow(
                        Icons.person_outline_rounded,
                        'Student Name',
                        _name,
                        textColor,
                        isDark,
                      ),
                      Divider(
                        height: 1,
                        color: isDark
                            ? Colors.grey.shade800
                            : const Color(0xFFE2E8F0),
                      ),
                      _buildInfoRow(
                        Icons.badge_outlined,
                        'Roll Number',
                        _rollNumber,
                        textColor,
                        isDark,
                      ),
                      Divider(
                        height: 1,
                        color: isDark
                            ? Colors.grey.shade800
                            : const Color(0xFFE2E8F0),
                      ),
                      _buildInfoRow(
                        Icons.domain_rounded,
                        'Department',
                        _department,
                        textColor,
                        isDark,
                      ),
                      Divider(
                        height: 1,
                        color: isDark
                            ? Colors.grey.shade800
                            : const Color(0xFFE2E8F0),
                      ),
                      _buildInfoRow(
                        Icons.school_outlined,
                        'Year',
                        _year,
                        textColor,
                        isDark,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FadeSlideY(
                delay: const Duration(milliseconds: 500),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: AppStyles.successGreen.withValues(
                      alpha: isDark ? 0.15 : 0.08,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppStyles.successGreen.withValues(alpha: 0.25),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppStyles.successGreen.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.face_retouching_natural_rounded,
                          color: AppStyles.successGreen,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Face Registration',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppStyles.textGray,
                              ),
                            ),
                            const SizedBox(height: 3),
                            const Text(
                              'Approved — Active',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppStyles.successGreen,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppStyles.successGreen.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.verified_rounded,
                          color: AppStyles.successGreen,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
        bottomNavigationBar: CustomBottomNav(currentIndex: 3, onTap: _onNavTap),
      ),
    );
  }

  Widget _buildInfoRow(
    IconData icon,
    String label,
    String value,
    Color textColor,
    bool isDark,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
      child: Row(
        children: [
          Icon(icon, color: AppStyles.textGray, size: 20),
          const SizedBox(width: 14),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: AppStyles.textGray,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
