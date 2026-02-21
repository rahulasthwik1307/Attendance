import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../utils/app_styles.dart';

class FaceVerificationScreen extends StatefulWidget {
  const FaceVerificationScreen({super.key});

  @override
  State<FaceVerificationScreen> createState() => _FaceVerificationScreenState();
}

class _FaceVerificationScreenState extends State<FaceVerificationScreen>
    with TickerProviderStateMixin {
  late AnimationController _rotationController;
  late AnimationController _scanLineController;
  late AnimationController _textFadeController;
  late AnimationController _locationCardController;
  late Animation<Offset> _locationSlide;

  final List<String> _instructions = [
    "Align your face",
    "Move closer",
    "Move right",
    "Blink to verify",
    "Hold still…",
  ];
  int _instructionIndex = 0;

  @override
  void initState() {
    super.initState();

    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _textFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();

    _locationCardController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _locationSlide = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _locationCardController,
            curve: Curves.easeOutBack,
          ),
        );

    _locationCardController.forward();
    _cycleInstructions();
  }

  void _cycleInstructions() async {
    for (int i = 0; i < _instructions.length; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) break;

      await _textFadeController.reverse();
      setState(() {
        _instructionIndex = i;
      });
      await _textFadeController.forward();

      if (i == _instructions.length - 1) {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          // Typically go to success. Here just showing success for flow.
          Navigator.of(context).pushReplacementNamed('/attendance_success');
        }
      }
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _scanLineController.dispose();
    _textFadeController.dispose();
    _locationCardController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final circleSize = screenSize.width * 0.75;

    return Scaffold(
      backgroundColor: AppStyles.backgroundLight,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: circleSize,
                        height: circleSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.grey.shade300,
                          image: const DecorationImage(
                            image: NetworkImage(
                              'https://picsum.photos/400/400?grayscale',
                            ),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          Colors.white.withValues(alpha: 0.8),
                          BlendMode.srcOut,
                        ),
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.transparent,
                          ),
                          child: Container(
                            width: circleSize,
                            height: circleSize,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: _rotationController,
                        builder: (context, child) {
                          return Transform.rotate(
                            angle: _rotationController.value * 2 * math.pi,
                            child: CustomPaint(
                              size: Size(circleSize, circleSize),
                              painter: _DashedCirclePainter(),
                            ),
                          );
                        },
                      ),
                      AnimatedBuilder(
                        animation: _scanLineController,
                        builder: (context, child) {
                          return Positioned(
                            top:
                                (screenSize.height / 2 - circleSize / 2) -
                                80 +
                                (_scanLineController.value * circleSize),
                            child: Container(
                              width: circleSize * 0.9,
                              height: 3,
                              decoration: BoxDecoration(
                                color: AppStyles.primaryBlue,
                                boxShadow: [
                                  BoxShadow(
                                    color: AppStyles.primaryBlue.withValues(
                                      alpha: 0.8,
                                    ),
                                    blurRadius: 10,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 64.0),
                  child: FadeTransition(
                    opacity: _textFadeController,
                    child: Text(
                      _instructions[_instructionIndex],
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: AppStyles.primaryBlue,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 32.0),
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppStyles.textGray,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // Location Card Slide Down
            SlideTransition(
              position: _locationSlide,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 16,
                    horizontal: 20,
                  ),
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
                  child: Row(
                    children: [
                      const Icon(
                        Icons.location_searching_rounded,
                        color: AppStyles.primaryBlue,
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'Checking your location…',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppStyles.textDark,
                        ),
                      ),
                      const Spacer(),
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppStyles.primaryBlue.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashedCirclePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double radius = size.width / 2;
    final center = Offset(size.width / 2, size.height / 2);

    final paint = Paint()
      ..color = AppStyles.primaryBlue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;

    const int dashCount = 30;
    const double dashLength = (math.pi * 2) / (dashCount * 2);

    for (int i = 0; i < dashCount; i++) {
      final double startAngle = (i * 2) * dashLength;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        dashLength,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
