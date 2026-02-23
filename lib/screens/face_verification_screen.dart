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
  late AnimationController _pulseController;
  late AnimationController _scanLineController;
  late AnimationController _textFadeController;
  late AnimationController _locationCardController;
  late Animation<double> _locationFade;
  bool _locationVerified = false;

  final Map<String, String> _subtitles = {
    "Align your face": "Center your face within the circle",
    "Move closer": "Step a little closer to the camera",
    "Move right": "Shift slightly to the right",
    "Blink to verify": "Blink naturally to confirm your identity",
    "Hold still…": "Almost done, stay steady",
  };

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

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _textFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();

    _locationCardController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _locationFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _locationCardController, curve: Curves.easeOut),
    );

    _locationCardController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 2500));
      if (!mounted) return;

      setState(() => _locationVerified = true);

      await Future.delayed(const Duration(milliseconds: 1000));
      if (!mounted) return;

      await _locationCardController.reverse();
      _cycleInstructions();
    });
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
          Navigator.of(context).pushReplacementNamed('/attendance_success');
        }
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
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
        child: Column(
          children: [
            // Header
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16.0, horizontal: 16.0),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Face Verification',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1A202C),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Location Card
            FadeTransition(
              opacity: _locationFade,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24.0),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 12.0,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
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
                    Icon(
                      _locationVerified
                          ? Icons.check_circle_rounded
                          : Icons.location_searching_rounded,
                      color: _locationVerified
                          ? AppStyles.successGreen
                          : AppStyles.primaryBlue,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _locationVerified
                            ? 'Location verified'
                            : 'Checking your location…',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppStyles.textDark,
                        ),
                      ),
                    ),
                    if (!_locationVerified)
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
            // Circle Stack
            AnimatedOpacity(
              duration: const Duration(milliseconds: 400),
              opacity: _locationVerified ? 1.0 : 0.0,
              child: Padding(
                padding: const EdgeInsets.only(top: 24.0),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipOval(
                      child: Stack(
                        children: [
                          Container(
                            width: circleSize,
                            height: circleSize,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              image: const DecorationImage(
                                image: NetworkImage(
                                  'https://picsum.photos/400/400?grayscale',
                                ),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          AnimatedBuilder(
                            animation: _scanLineController,
                            builder: (context, child) {
                              return CustomPaint(
                                size: Size(circleSize, circleSize),
                                painter: _ScanLinePainter(
                                  scanValue: _scanLineController.value,
                                  circleSize: circleSize,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    AnimatedBuilder(
                      animation: _pulseController,
                      builder: (context, child) {
                        return Container(
                          width: circleSize,
                          height: circleSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppStyles.primaryBlue,
                              width: 2.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppStyles.primaryBlue.withValues(
                                  alpha: _pulseController.value * 0.5,
                                ),
                                blurRadius: 8 + (_pulseController.value * 12),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Instruction card
            Expanded(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 400),
                opacity: _locationVerified ? 1.0 : 0.0,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: FadeTransition(
                      opacity: _textFadeController,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppStyles.primaryBlue.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _instructions[_instructionIndex],
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: AppStyles.primaryBlue,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _subtitles[_instructions[_instructionIndex]] ??
                                  '',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: Color(0xFF4A5568),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Cancel button
            Padding(
              padding: const EdgeInsets.only(bottom: 32, top: 8),
              child: Center(
                child: GestureDetector(
                  onTap: () =>
                      Navigator.of(context).pushReplacementNamed('/dashboard'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppStyles.errorRed.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: AppStyles.errorRed.withValues(alpha: 0.3),
                        width: 1.2,
                      ),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        color: AppStyles.errorRed,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
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

class _ScanLinePainter extends CustomPainter {
  final double scanValue;
  final double circleSize;

  _ScanLinePainter({required this.scanValue, required this.circleSize});

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = circleSize / 2;
    final double yOffset = (scanValue - 0.5) * circleSize;
    final double halfWidth = math.sqrt(
      math.max(0.0, radius * radius - yOffset * yOffset),
    );

    final paint = Paint()
      ..color = AppStyles.primaryBlue
      ..strokeWidth = 2.5
      ..shader = LinearGradient(
        colors: [
          AppStyles.primaryBlue.withValues(alpha: 0),
          AppStyles.primaryBlue,
          AppStyles.primaryBlue.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(radius - halfWidth, 0, halfWidth * 2, 1));

    final Offset start = Offset(radius - halfWidth, radius + yOffset);
    final Offset end = Offset(radius + halfWidth, radius + yOffset);

    canvas.drawLine(start, end, paint);

    final glowPaint = Paint()
      ..color = AppStyles.primaryBlue
      ..strokeWidth = 2.5
      ..shader = paint.shader
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);

    canvas.drawLine(start, end, glowPaint);
  }

  @override
  bool shouldRepaint(covariant _ScanLinePainter oldDelegate) {
    return true;
  }
}
