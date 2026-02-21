import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/fade_slide_y.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _floatController;
  late Animation<double> _floatAnimation;

  @override
  void initState() {
    super.initState();
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _floatAnimation = Tween<double>(begin: -10, end: 10).animate(
      CurvedAnimation(parent: _floatController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _floatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const FadeSlideY(
                delay: Duration(milliseconds: 100),
                child: Text(
                  'Welcome to\nSmart Attendance',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                    color: AppStyles.textDark,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const FadeSlideY(
                delay: Duration(milliseconds: 200),
                child: Text(
                  'Secure. Fast. Reliable.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: AppStyles.textGray,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 64),
              FadeSlideY(
                delay: const Duration(milliseconds: 300),
                child: AnimatedBuilder(
                  animation: _floatAnimation,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, _floatAnimation.value),
                      child: child,
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(48),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: AppStyles.primaryBlue.withValues(alpha: 0.15),
                          blurRadius: 30,
                          spreadRadius: 10,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.fingerprint_rounded,
                      size: 100,
                      color: AppStyles.primaryBlue,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 80),
              FadeSlideY(
                delay: const Duration(milliseconds: 400),
                child: AnimatedButton(
                  onPressed: () => Navigator.of(context).pushNamed('/register'),
                  style: Theme.of(context).outlinedButtonTheme.style,
                  child: const Text('Register Face'),
                ),
              ),
              const SizedBox(height: 16),
              FadeSlideY(
                delay: const Duration(milliseconds: 500),
                child: AnimatedButton(
                  onPressed: () =>
                      Navigator.of(context).pushReplacementNamed('/dashboard'),
                  child: const Text('Go to Dashboard'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
