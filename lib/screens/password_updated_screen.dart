import 'package:flutter/material.dart';
import 'dart:async';
import '../utils/app_styles.dart';
import '../widgets/fade_slide_y.dart';

class PasswordUpdatedScreen extends StatefulWidget {
  const PasswordUpdatedScreen({super.key});

  @override
  State<PasswordUpdatedScreen> createState() => _PasswordUpdatedScreenState();
}

class _PasswordUpdatedScreenState extends State<PasswordUpdatedScreen> {
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        final String? mode =
            ModalRoute.of(context)?.settings.arguments as String?;
        if (mode == 'settings') {
          Navigator.of(context).pushReplacementNamed('/dashboard');
        } else {
          Navigator.of(context).pushReplacementNamed('/sign_in');
        }
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String? mode = ModalRoute.of(context)?.settings.arguments as String?;

    return Scaffold(
      backgroundColor: AppStyles.backgroundLight,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FadeSlideY(
                delay: const Duration(milliseconds: 100),
                child: Center(
                  child: Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: AppStyles.successGreen.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 48,
                      color: AppStyles.successGreen,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const FadeSlideY(
                delay: Duration(milliseconds: 200),
                child: Text(
                  'Password Updated!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1A202C),
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FadeSlideY(
                delay: const Duration(milliseconds: 300),
                child: Text(
                  mode == 'settings'
                      ? 'Your new password is now active.'
                      : 'You can now sign in with your new password.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF4A5568),
                    height: 1.6,
                  ),
                ),
              ),
              const SizedBox(height: 40),
              FadeSlideY(
                delay: const Duration(milliseconds: 400),
                child: Text(
                  mode == 'settings'
                      ? 'Redirecting to dashboard…'
                      : 'Redirecting to sign in…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppStyles.textGray,
                    fontWeight: FontWeight.w500,
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
