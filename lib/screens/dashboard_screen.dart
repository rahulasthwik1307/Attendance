import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/custom_bottom_nav.dart';
import '../widgets/fade_slide_y.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _onNavTap(int index) {
    if (index == 0) return;
    if (index == 1) Navigator.of(context).pushReplacementNamed('/history');
    if (index == 2) Navigator.of(context).pushReplacementNamed('/settings');
    if (index == 3) Navigator.of(context).pushReplacementNamed('/profile');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppStyles.backgroundLight,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Hello, Student 👋',
              style: TextStyle(
                color: AppStyles.textDark,
                fontWeight: FontWeight.bold,
                fontSize: 24,
              ),
            ),
            Text(
              'Oct 24, 2024',
              style: TextStyle(
                color: AppStyles.textGray.withValues(alpha: 0.8),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.notifications_none_rounded,
              color: AppStyles.textDark,
            ),
            onPressed: () {},
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          children: [
            const FadeSlideY(
              delay: Duration(milliseconds: 100),
              child: _StatusCard(
                title: 'Face Status',
                value: 'Active',
                icon: Icons.face_retouching_natural_rounded,
                statusColor: AppStyles.successGreen,
                valueColor: AppStyles.textDark,
              ),
            ),
            const SizedBox(height: 16),
            const FadeSlideY(
              delay: Duration(milliseconds: 250),
              child: _StatusCard(
                title: 'Location Status',
                value: 'Set',
                icon: Icons.location_on_rounded,
                statusColor: AppStyles.successGreen,
                valueColor: AppStyles.textDark,
              ),
            ),
            const SizedBox(height: 16),
            const FadeSlideY(
              delay: Duration(milliseconds: 400),
              child: _StatusCard(
                title: 'Last Attendance',
                value: '09:00 AM',
                icon: Icons.access_time_rounded,
                statusColor: Colors.transparent,
                valueColor: AppStyles.primaryBlue,
              ),
            ),
            const SizedBox(height: 48),
            FadeSlideY(
              delay: const Duration(milliseconds: 550),
              child: AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _pulseAnimation.value,
                    child: Container(
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(
                            color: AppStyles.primaryBlue.withValues(alpha: 0.3),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ],
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: child,
                    ),
                  );
                },
                child: AnimatedButton(
                  onPressed: () =>
                      Navigator.of(context).pushNamed('/face_verification'),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.camera_alt_rounded),
                        SizedBox(width: 12),
                        Text('Verify Face'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const FadeSlideY(
              delay: Duration(milliseconds: 650),
              child: Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: 'Set Location',
                      icon: Icons.my_location_rounded,
                      isDestructive: false,
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: _ActionButton(
                      label: 'Delete Face',
                      icon: Icons.delete_outline_rounded,
                      isDestructive: true,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 48),
            FadeSlideY(
              delay: const Duration(milliseconds: 750),
              child: Center(
                child: TextButton(
                  onPressed: () =>
                      Navigator.of(context).pushReplacementNamed('/home'),
                  child: const Text(
                    'Logout',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppStyles.textGray,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: CustomBottomNav(currentIndex: 0, onTap: _onNavTap),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color statusColor;
  final Color valueColor;

  const _StatusCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.statusColor,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppStyles.primaryBlue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppStyles.primaryBlue),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppStyles.textGray,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (statusColor != Colors.transparent) ...[
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: statusColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        value,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: valueColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isDestructive;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.isDestructive,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? AppStyles.errorRed : AppStyles.primaryBlue;
    return AnimatedButton(
      onPressed: () {},
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
  }
}
