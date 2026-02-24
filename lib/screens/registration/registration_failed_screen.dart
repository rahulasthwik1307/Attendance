import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/fade_slide_y.dart';

class RegistrationFailedScreen extends StatefulWidget {
  const RegistrationFailedScreen({super.key});

  @override
  State<RegistrationFailedScreen> createState() =>
      _RegistrationFailedScreenState();
}

class _RegistrationFailedScreenState extends State<RegistrationFailedScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _shakeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );
    _shakeController.forward();
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: AppStyles.textDark),
          onPressed: () => Navigator.of(context).pushReplacementNamed('/home'),
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
              Center(
                child: AnimatedBuilder(
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
                    decoration: BoxDecoration(
                      color: AppStyles.errorRed,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppStyles.errorRed.withValues(alpha: 0.4),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 60,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const FadeSlideY(
                delay: Duration(milliseconds: 200),
                child: Text(
                  'Registration Failed',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppStyles.textDark,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const FadeSlideY(
                delay: Duration(milliseconds: 300),
                child: Text(
                  'Could not capture your face clearly',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: AppStyles.textGray),
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
                            'Tips for successful registration',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: AppStyles.textDark,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                      Text(
                        '1. Remove glasses/accessories.\n2. Ensure good lighting on your face.\n3. Make sure only your face is in the frame.',
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
                  onPressed: () =>
                      Navigator.of(context).pushReplacementNamed('/register'),
                  child: const Text('Try Again'),
                ),
              ),
              const SizedBox(height: 16),
              FadeSlideY(
                delay: const Duration(milliseconds: 600),
                child: TextButton(
                  onPressed: () =>
                      Navigator.of(context).pushReplacementNamed('/home'),
                  child: const Text(
                    'Go to Home',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppStyles.primaryBlue,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
