import 'dart:async';
import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/fade_slide_y.dart';

class FaceUpdatedSuccessScreen extends StatefulWidget {
  const FaceUpdatedSuccessScreen({super.key});

  @override
  State<FaceUpdatedSuccessScreen> createState() =>
      _FaceUpdatedSuccessScreenState();
}

class _FaceUpdatedSuccessScreenState extends State<FaceUpdatedSuccessScreen>
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
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
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
                        Icons.face_retouching_natural_rounded,
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
                  'Face Updated!',
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
                  'Your face has been successfully re-registered.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: AppStyles.textGray,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
