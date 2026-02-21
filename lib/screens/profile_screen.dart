import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../utils/app_styles.dart';
import '../widgets/custom_bottom_nav.dart';
import '../widgets/fade_slide_y.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with TickerProviderStateMixin {
  late AnimationController _borderRotationController;

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
    return Scaffold(
      backgroundColor: AppStyles.backgroundLight,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text(
          'Profile',
          style: TextStyle(
            color: AppStyles.textDark,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
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
                          angle: _borderRotationController.value * 2 * math.pi,
                          child: Container(
                            width: 130,
                            height: 130,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const SweepGradient(
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
                        color: Colors.white,
                        border: Border.all(color: Colors.white, width: 4),
                        image: const DecorationImage(
                          image: NetworkImage(
                            'https://picsum.photos/200/200?people',
                          ),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppStyles.primaryBlue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                        child: const Icon(
                          Icons.camera_alt_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const FadeSlideY(
              delay: Duration(milliseconds: 200),
              child: Center(
                child: Text(
                  'John Doe',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppStyles.textDark,
                  ),
                ),
              ),
            ),
            const FadeSlideY(
              delay: Duration(milliseconds: 300),
              child: Center(
                child: Text(
                  '2021CS001',
                  style: TextStyle(fontSize: 16, color: AppStyles.textGray),
                ),
              ),
            ),
            const SizedBox(height: 32),
            FadeSlideY(
              delay: const Duration(milliseconds: 400),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
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
                      'John Doe',
                    ),
                    const Divider(height: 1, color: Color(0xFFE2E8F0)),
                    _buildInfoRow(
                      Icons.badge_outlined,
                      'Roll Number',
                      '2021CS001',
                    ),
                    const Divider(height: 1, color: Color(0xFFE2E8F0)),
                    _buildInfoRow(
                      Icons.domain_rounded,
                      'Department',
                      'Computer Science',
                    ),
                    const Divider(height: 1, color: Color(0xFFE2E8F0)),
                    _buildInfoRow(Icons.school_outlined, 'Year', '3rd Year'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            FadeSlideY(
              delay: const Duration(milliseconds: 500),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: AppStyles.successGreen.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppStyles.successGreen.withValues(alpha: 0.3),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.face_retouching_natural_rounded,
                      color: AppStyles.successGreen,
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'Face Registered — Active',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppStyles.successGreen,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.check_circle_rounded,
                      color: AppStyles.successGreen,
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
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
      child: Row(
        children: [
          Icon(icon, color: AppStyles.textGray, size: 22),
          const SizedBox(width: 16),
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: AppStyles.textGray),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppStyles.textDark,
            ),
          ),
        ],
      ),
    );
  }
}
