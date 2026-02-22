import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../utils/app_styles.dart';
import '../utils/auth_flow_state.dart';

class FaceRegistrationScreen extends StatefulWidget {
  const FaceRegistrationScreen({super.key});

  @override
  State<FaceRegistrationScreen> createState() => _FaceRegistrationScreenState();
}

class _FaceRegistrationScreenState extends State<FaceRegistrationScreen>
    with TickerProviderStateMixin {
  late AnimationController _rotationController;
  late AnimationController _scanLineController;
  late AnimationController _textFadeController;

  final List<String> _instructions = [
    "Fit your face in the circle",
    "Move closer",
    "Move back",
    "Move left",
    "Move right",
    "Hold still…",
    "Blink to verify",
  ];
  int _instructionIndex = 0;

  @override
  void initState() {
    super.initState();

    // Security Guard: Prevent access if password hasn't been set/activated
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!AuthFlowState.instance.passwordSet) {
        Navigator.of(context).pushReplacementNamed('/sign_in');
      }
    });

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

      // After final instruction, auto-simulate capture and go to success screen
      if (i == _instructions.length - 1) {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/registration_success');
        }
      }
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _scanLineController.dispose();
    _textFadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final circleSize = screenSize.width * 0.75;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppStyles.backgroundLight,
        body: SafeArea(
          child: Column(
            children: [
              // Top App Bar Area
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 48), // Balance for icon button
                    const Spacer(),
                    const Column(
                      children: [
                        Text(
                          'Step 2 of 3',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppStyles.textGray,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'Face Registration',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppStyles.textDark,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    const SizedBox(width: 48), // Balance for icon button
                  ],
                ),
              ),
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Simulated Camera Feed Placeholder
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
                    // Frosted Glass Overlay outside circle is not easily doable with single standard ClipPath unless we invert it.
                    // Instead we use a ColorFiltered or CustomPaint over the entire screen except the circle.
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

                    // Rotating Dashed Border
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

                    // Scanning Line
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
              // Instructions
              Padding(
                padding: const EdgeInsets.only(bottom: 48.0),
                child: FadeTransition(
                  opacity: _textFadeController,
                  child: Column(
                    children: [
                      Text(
                        _instructions[_instructionIndex],
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: AppStyles.primaryBlue,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Position your face within the circle',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppStyles.textGray,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Cancel Button
              Padding(
                padding: const EdgeInsets.only(bottom: 24.0),
                child: TextButton(
                  onPressed: () =>
                      Navigator.of(context).pushReplacementNamed('/home'),
                  child: const Text(
                    'Cancel Registration',
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
