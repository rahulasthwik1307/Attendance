import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import '../../utils/app_styles.dart';
import '../../utils/auth_flow_state.dart';

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

  // ── Timer ring (above face circle) ────────────────────────────────
  late AnimationController _timerPulseController;
  late Animation<double> _timerPulseAnim;
  late AnimationController _ringController;
  late Animation<double> _ringProgress;
  static const int _totalSeconds = 60;
  int _secondsRemaining = _totalSeconds;
  Timer? _countdownTimer;
  final int _attempt = 1;

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

    // Timer pulse every second
    _timerPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _timerPulseAnim = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _timerPulseController, curve: Curves.easeInOut),
    );

    // Ring countdown (smooth depletion over 60s)
    _ringController = AnimationController(
      vsync: this,
      duration: Duration(seconds: _totalSeconds),
    );
    _ringProgress = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _ringController, curve: Curves.linear));

    _locationCardController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(milliseconds: 2500));
      if (!mounted) return;

      setState(() => _locationVerified = true);

      // Start timer after location verified
      _ringController.forward();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_secondsRemaining > 1) {
          setState(() => _secondsRemaining--);
          _timerPulseController.forward().then((_) {
            if (mounted) _timerPulseController.reverse();
          });
        } else {
          setState(() => _secondsRemaining = 0);
          timer.cancel();
        }
      });

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
          final String? mode =
              ModalRoute.of(context)?.settings.arguments as String?;
          if (mode == 'password_reset') {
            Navigator.of(
              context,
            ).pushReplacementNamed('/password_reset_face_success');
          } else if (mode == 'face_reset') {
            Navigator.of(
              context,
            ).pushNamedAndRemoveUntil('/register', (route) => false);
            AuthFlowState.instance.passwordSet = true;
            AuthFlowState.instance.faceRegistered = false;
            AuthFlowState.instance.isFirstTimeUser = false;
          } else {
            Navigator.of(context).pushReplacementNamed('/attendance_success');
          }
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
    _timerPulseController.dispose();
    _ringController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final circleSize = screenSize.width * 0.75;

    // Timer color: green → amber → red
    final Color timerColor = _secondsRemaining <= 15
        ? AppStyles.errorRed
        : _secondsRemaining <= 30
        ? AppStyles.amberWarning
        : AppStyles.successGreen;

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

            // ── Timer ring (above face circle, shown after location verified) ──
            AnimatedOpacity(
              duration: const Duration(milliseconds: 400),
              opacity: _locationVerified ? 1.0 : 0.0,
              child: Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: ScaleTransition(
                  scale: _timerPulseAnim,
                  child: AnimatedBuilder(
                    animation: _ringController,
                    builder: (context, _) {
                      return SizedBox(
                        width: 56,
                        height: 56,
                        child: CustomPaint(
                          painter: _MiniRingPainter(
                            progress: _ringProgress.value,
                            color: timerColor,
                          ),
                          child: Center(
                            child: Text(
                              '${_secondsRemaining}s',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: timerColor,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Circle Stack
            AnimatedOpacity(
              duration: const Duration(milliseconds: 400),
              opacity: _locationVerified ? 1.0 : 0.0,
              child: Padding(
                padding: const EdgeInsets.only(top: 4.0),
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
                    // Breathing border with pulse glow
                    AnimatedBuilder(
                      animation: _pulseController,
                      builder: (context, child) {
                        final breatheScale =
                            1.0 + (_pulseController.value * 0.015);
                        return Transform.scale(
                          scale: breatheScale,
                          child: Container(
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
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),

            // ── Attempt text ──────────────────────────────────────
            AnimatedOpacity(
              duration: const Duration(milliseconds: 400),
              opacity: _locationVerified ? 1.0 : 0.0,
              child: Text(
                'Attempt $_attempt of 3',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade500,
                ),
              ),
            ),
            const SizedBox(height: 8),

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
            // No cancel button — this is a mandatory flow
            const SizedBox(height: 32),
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

/// Compact countdown ring.
class _MiniRingPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _MiniRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 8) / 2;

    final trackPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi,
      false,
      trackPaint,
    );

    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniRingPainter old) =>
      old.progress != progress || old.color != color;
}
