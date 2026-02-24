import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class AttendanceFailedScreen extends StatefulWidget {
  const AttendanceFailedScreen({super.key});

  @override
  State<AttendanceFailedScreen> createState() => _AttendanceFailedScreenState();
}

class _AttendanceFailedScreenState extends State<AttendanceFailedScreen>
    with TickerProviderStateMixin {
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;
  late AnimationController _rippleController;

  @override
  void initState() {
    super.initState();

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    // Shake animation logic
    _shakeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _shakeController.forward();
  }

  @override
  void dispose() {
    _shakeController.dispose();
    _rippleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String? mode = ModalRoute.of(context)?.settings.arguments as String?;

    return Scaffold(
      backgroundColor: Colors.white,
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
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _rippleController,
                    builder: (context, child) {
                      return Container(
                        width: 150 + (_rippleController.value * 50),
                        height: 150 + (_rippleController.value * 50),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppStyles.errorRed.withValues(
                            alpha: 1 - _rippleController.value,
                          ),
                        ),
                      );
                    },
                  ),
                  AnimatedBuilder(
                    animation: _shakeAnimation,
                    builder: (context, child) {
                      final sineValue = math.sin(
                        _shakeAnimation.value * math.pi * 3,
                      );
                      return Transform.translate(
                        offset: Offset(sineValue * 15, 0),
                        child: child,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: const BoxDecoration(
                        color: AppStyles.errorRed,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 60,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const FadeSlideY(
                delay: Duration(milliseconds: 300),
                child: Text(
                  'Verification Failed',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppStyles.textDark,
                  ),
                ),
              ),
              if (mode == 'forgot_password')
                const FadeSlideY(
                  delay: Duration(milliseconds: 350),
                  child: Padding(
                    padding: EdgeInsets.only(top: 8.0, left: 16.0, right: 16.0),
                    child: Text(
                      'We could not verify your identity. Please try again in good lighting.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: AppStyles.textGray),
                    ),
                  ),
                ),
              const SizedBox(height: 32),
              FadeSlideY(
                delay: const Duration(milliseconds: 400),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppStyles.backgroundLight,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: const Column(
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.lightbulb_outline_rounded,
                            color: AppStyles.textGray,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Tips for success',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: AppStyles.textDark,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                      Text(
                        '1. Make sure your face is well-lit.\n2. Look directly at the camera.\n3. Remove glasses or masks if any.',
                        style: TextStyle(
                          color: AppStyles.textGray,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              FadeSlideY(
                delay: const Duration(milliseconds: 500),
                child: AnimatedButton(
                  onPressed: () {
                    if (mode == 'forgot_password') {
                      Navigator.of(
                        context,
                      ).pushReplacementNamed('/forgot_password_face_verify');
                    } else {
                      Navigator.of(
                        context,
                      ).pushReplacementNamed('/face_verification');
                    }
                  },
                  child: const Text('Try Again'),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
