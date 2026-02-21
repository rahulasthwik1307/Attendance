import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/custom_bottom_nav.dart';
import '../widgets/fade_slide_y.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with TickerProviderStateMixin {
  late AnimationController _countController;
  late Animation<int> _verifiedCountAnimation;
  late Animation<int> _rejectedCountAnimation;

  @override
  void initState() {
    super.initState();
    _countController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _verifiedCountAnimation = IntTween(begin: 0, end: 18).animate(
      CurvedAnimation(parent: _countController, curve: Curves.easeOutQuart),
    );

    _rejectedCountAnimation = IntTween(begin: 0, end: 3).animate(
      CurvedAnimation(parent: _countController, curve: Curves.easeOutQuart),
    );

    _countController.forward();
  }

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  void _onNavTap(int index) {
    if (index == 0) Navigator.of(context).pushReplacementNamed('/dashboard');
    if (index == 1) return;
    if (index == 2) Navigator.of(context).pushReplacementNamed('/settings');
    if (index == 3) Navigator.of(context).pushReplacementNamed('/profile');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'History',
              style: TextStyle(
                color:
                    Theme.of(context).textTheme.displayLarge?.color ??
                    AppStyles.textDark,
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
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: FadeSlideY(
                delay: const Duration(milliseconds: 100),
                child: Row(
                  children: [
                    Expanded(
                      child: _SummaryCard(
                        label: 'Verified',
                        countAnimation: _verifiedCountAnimation,
                        dotColor: AppStyles.successGreen,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _SummaryCard(
                        label: 'Rejected',
                        countAnimation: _rejectedCountAnimation,
                        dotColor: AppStyles.errorRed,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                children: [
                  FadeSlideY(
                    delay: const Duration(milliseconds: 200),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        'Today',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color:
                              Theme.of(context).textTheme.displayLarge?.color ??
                              AppStyles.textDark,
                        ),
                      ),
                    ),
                  ),
                  FadeSlideY(
                    delay: const Duration(milliseconds: 300),
                    child: const _HistoryItem(
                      isSuccess: true,
                      time: '09:05 AM',
                      status: 'Present',
                    ),
                  ),
                  FadeSlideY(
                    delay: const Duration(milliseconds: 400),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        'Yesterday',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color:
                              Theme.of(context).textTheme.displayLarge?.color ??
                              AppStyles.textDark,
                        ),
                      ),
                    ),
                  ),
                  FadeSlideY(
                    delay: const Duration(milliseconds: 500),
                    child: const _HistoryItem(
                      isSuccess: false,
                      time: '08:55 AM',
                      status: 'Failed',
                    ),
                  ),
                  FadeSlideY(
                    delay: const Duration(milliseconds: 600),
                    child: const _HistoryItem(
                      isSuccess: true,
                      time: '09:15 AM',
                      status: 'Present',
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: CustomBottomNav(currentIndex: 1, onTap: _onNavTap),
    );
  }
}

class _SummaryCard extends AnimatedWidget {
  final String label;
  final Color dotColor;
  final Animation<int> countAnimation;

  const _SummaryCard({
    required this.label,
    required this.dotColor,
    required this.countAnimation,
  }) : super(listenable: countAnimation);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color ?? Colors.white,
        borderRadius: BorderRadius.circular(12),
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
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppStyles.textGray,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            countAnimation.value.toString(),
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color:
                  Theme.of(context).textTheme.displayLarge?.color ??
                  AppStyles.textDark,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryItem extends StatelessWidget {
  final bool isSuccess;
  final String time;
  final String status;

  const _HistoryItem({
    required this.isSuccess,
    required this.time,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = isSuccess ? AppStyles.successGreen : AppStyles.errorRed;
    final iconData = isSuccess
        ? Icons.check_circle_rounded
        : Icons.cancel_rounded;
    final title = isSuccess ? 'Face Verified' : 'Verification Failed';

    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(iconData, color: iconColor, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color:
                          Theme.of(context).textTheme.displayLarge?.color ??
                          AppStyles.textDark,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: 14,
                      color:
                          Theme.of(context).textTheme.bodyMedium?.color ??
                          AppStyles.textGray,
                    ),
                  ),
                ],
              ),
            ),
            _StatusBadge(status: status, isSuccess: isSuccess),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatefulWidget {
  final String status;
  final bool isSuccess;

  const _StatusBadge({required this.status, required this.isSuccess});

  @override
  State<_StatusBadge> createState() => _StatusBadgeState();
}

class _StatusBadgeState extends State<_StatusBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _scaleAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.elasticOut));
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isSuccess
        ? AppStyles.successGreen
        : AppStyles.errorRed;
    return ScaleTransition(
      scale: _scaleAnimation,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          widget.status,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: color, // The vibrant pure color is preferred for both modes
          ),
        ),
      ),
    );
  }
}
