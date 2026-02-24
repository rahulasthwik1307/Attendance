import 'package:flutter/material.dart';
import '../utils/app_styles.dart';
import '../widgets/animated_button.dart';
import '../widgets/fade_slide_y.dart';

class LocationErrorScreen extends StatefulWidget {
  const LocationErrorScreen({super.key});

  @override
  State<LocationErrorScreen> createState() => _LocationErrorScreenState();
}

class _LocationErrorScreenState extends State<LocationErrorScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
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
              Center(
                child: AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 100 * _pulseAnimation.value,
                          height: 100 * _pulseAnimation.value,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppStyles.errorRed.withValues(alpha: 0.15),
                          ),
                        ),
                        child!,
                      ],
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppStyles.errorRed.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.location_off_rounded,
                      size: 48,
                      color: AppStyles.errorRed,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const FadeSlideY(
                delay: Duration(milliseconds: 200),
                child: Text(
                  'Outside Geo-fence',
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
                  'You must be within the designated campus area to mark your attendance.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: AppStyles.textGray,
                    height: 1.5,
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
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.directions_walk_rounded,
                        color: AppStyles.textGray,
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Estimated Distance: 1.2 miles away',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppStyles.textDark,
                          ),
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
                  onPressed: () => Navigator.of(
                    context,
                  ).pushReplacementNamed('/face_verification'),
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
