import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../utils/app_styles.dart';
import '../../utils/auth_flow_state.dart';

class ResetFaceVerifyScreen extends StatefulWidget {
  const ResetFaceVerifyScreen({super.key});

  @override
  State<ResetFaceVerifyScreen> createState() => _ResetFaceVerifyScreenState();
}

class _ResetFaceVerifyScreenState extends State<ResetFaceVerifyScreen>
    with TickerProviderStateMixin {
  bool _isSuccess = false;
  bool _isFailed = false;
  Color _borderColor = AppStyles.primaryBlue;

  late AnimationController _pulseController;
  late AnimationController _textFadeController;
  late AnimationController _scanLineController;

  final Map<String, String> _subtitles = {
    "Fit your face in the circle":
        "Make sure your full face is clearly visible",
    "Move closer": "Step a little closer to the camera",
    "Move back": "You are too close, step back slightly",
    "Hold still…": "Almost done, stay steady",
    "Verifying identity…": "Confirming it is really you",
  };

  final List<String> _instructions = [
    "Fit your face in the circle",
    "Move closer",
    "Move back",
    "Hold still…",
    "Verifying identity…",
  ];
  int _instructionIndex = 0;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _textFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();

    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

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

        final bool failed = DateTime.now().second % 3 == 0;
        if (failed) {
          if (mounted) {
            setState(() {
              _isFailed = true;
              _borderColor = AppStyles.errorRed;
            });
          }
          return;
        }

        if (mounted) {
          setState(() {
            _isSuccess = true;
            _borderColor = AppStyles.successGreen;
          });
          await Future.delayed(const Duration(seconds: 2));
          if (mounted) {
            AuthFlowState.instance.isFaceReset = true;
            AuthFlowState.instance.faceRegistered = false;
            AuthFlowState.instance.passwordSet = true;
            AuthFlowState.instance.isFirstTimeUser = false;
            Navigator.of(
              context,
            ).pushNamedAndRemoveUntil('/register', (route) => false);
          }
        }
      }
    }
  }

  void _onRetry() {
    setState(() {
      _isFailed = false;
      _isSuccess = false;
      _borderColor = AppStyles.primaryBlue;
      _instructionIndex = 0;
    });
    _textFadeController.forward();
    _cycleInstructions();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _textFadeController.dispose();
    _scanLineController.dispose();
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
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              children: [
                // Header
                const Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: 16.0,
                    horizontal: 16.0,
                  ),
                  child: Row(
                    children: [
                      SizedBox(width: 48), // Balance for centering
                      Spacer(),
                      Column(
                        children: [
                          Text(
                            'Confirm Your Identity',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1A202C),
                              letterSpacing: -0.3,
                            ),
                          ),
                        ],
                      ),
                      Spacer(),
                      SizedBox(width: 48), // Balance for centering
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 24.0),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Camera Placeholder inside ClipOval
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
                            // Scan Line
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

                      // Invert mask using ColorFiltered
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

                      // Pulsing Glow Border
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          return Container(
                            width: circleSize,
                            height: circleSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _borderColor,
                                width: 2.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _borderColor.withAlpha(
                                    (_pulseController.value * 255 * 0.5)
                                        .toInt(),
                                  ),
                                  blurRadius: 8 + (_pulseController.value * 12),
                                ),
                                BoxShadow(
                                  color: Colors.black.withAlpha(
                                    (0.1 * 255).toInt(),
                                  ),
                                  blurRadius: 20,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Instructions
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: 24.0,
                    left: 24.0,
                    right: 24.0,
                  ),
                  child: FadeTransition(
                    opacity: _textFadeController,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _isSuccess
                            ? AppStyles.successGreen.withValues(alpha: 0.06)
                            : _isFailed
                            ? AppStyles.errorRed.withValues(alpha: 0.06)
                            : AppStyles.primaryBlue.withValues(alpha: 0.06),
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
                            _isSuccess
                                ? 'Identity Confirmed ✓'
                                : _isFailed
                                ? 'Verification Failed'
                                : _instructions[_instructionIndex],
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: _isSuccess
                                  ? AppStyles.successGreen
                                  : _isFailed
                                  ? AppStyles.errorRed
                                  : AppStyles.primaryBlue,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _isSuccess
                                ? 'You can now register your new face.'
                                : _isFailed
                                ? 'We could not verify your identity.'
                                : _subtitles[_instructions[_instructionIndex]] ??
                                      '',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: AppStyles.textDark.withValues(alpha: 0.65),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  child: _isFailed
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 24),
                          child: GestureDetector(
                            onTap: _onRetry,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: AppStyles.primaryBlue.withValues(
                                  alpha: 0.08,
                                ),
                                borderRadius: BorderRadius.circular(30),
                                border: Border.all(
                                  color: AppStyles.primaryBlue.withValues(
                                    alpha: 0.3,
                                  ),
                                  width: 1.2,
                                ),
                              ),
                              child: const Text(
                                'Try Again',
                                style: TextStyle(
                                  color: AppStyles.primaryBlue,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
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
