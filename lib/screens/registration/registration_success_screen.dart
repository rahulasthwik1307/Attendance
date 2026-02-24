import 'dart:async';
import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/fade_slide_y.dart';

class RegistrationSuccessScreen extends StatefulWidget {
  const RegistrationSuccessScreen({super.key});

  @override
  State<RegistrationSuccessScreen> createState() =>
      _RegistrationSuccessScreenState();
}

class _RegistrationSuccessScreenState extends State<RegistrationSuccessScreen>
    with TickerProviderStateMixin {
  late Timer _timer;
  late AnimationController _checkController;
  late Animation<double> _scaleAnimation;
  late AnimationController _rippleController;

  @override
  void initState() {
    super.initState();

    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _checkController, curve: Curves.elasticOut),
    );

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _checkController.forward();

    _timer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/dashboard', (route) => false);
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _checkController.dispose();
    _rippleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                // Ripple effect
                AnimatedBuilder(
                  animation: _rippleController,
                  builder: (context, child) {
                    return Container(
                      width: 150 + (_rippleController.value * 50),
                      height: 150 + (_rippleController.value * 50),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppStyles.successGreen.withValues(
                          alpha: 1 - _rippleController.value,
                        ),
                      ),
                    );
                  },
                ),
                ScaleTransition(
                  scale: _scaleAnimation,
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: const BoxDecoration(
                      color: AppStyles.successGreen,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 60,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 48),
            const FadeSlideY(
              delay: Duration(milliseconds: 300),
              child: Text(
                'Registration Successful',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppStyles.textDark,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const FadeSlideY(
              delay: Duration(milliseconds: 400),
              child: Text(
                'Face Data Saved',
                style: TextStyle(fontSize: 16, color: AppStyles.textGray),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
