import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import '../../utils/app_styles.dart';

class QrFaceVerifyScreen extends StatefulWidget {
  const QrFaceVerifyScreen({super.key});

  @override
  State<QrFaceVerifyScreen> createState() => _QrFaceVerifyScreenState();
}

class _QrFaceVerifyScreenState extends State<QrFaceVerifyScreen>
    with TickerProviderStateMixin {
  // ── Animation controllers (matching face_verification_screen) ────────
  late AnimationController _pulseController;
  late AnimationController _scanLineController;
  late AnimationController _textFadeController;

  // ── Timer pulse (1.0 → 1.05 → 1.0 every second) ────────────────────
  late AnimationController _timerPulseController;
  late Animation<double> _timerPulseAnim;

  // ── Countdown timer ──────────────────────────────────────────────────
  static const int _totalSeconds = 60;
  int _secondsRemaining = _totalSeconds;
  Timer? _countdownTimer;
  late AnimationController _ringController;
  late Animation<double> _ringProgress;

  // ── State ─────────────────────────────────────────────────────────────
  final int _attempt = 1;
  String _statusText = 'Looking for your face...';
  bool _hasNavigated = false;
  bool _faceDetected = false;

  @override
  void initState() {
    super.initState();

    // Pulse border glow — identical to face_verification_screen
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    // Scan line — identical to face_verification_screen
    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    // Text fade for status changes
    _textFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();

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
    _ringController.forward();

    // Numeric countdown
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 1) {
        setState(() => _secondsRemaining--);
        // Subtle pulse on each tick
        _timerPulseController.forward().then((_) {
          if (mounted) _timerPulseController.reverse();
        });
      } else {
        setState(() => _secondsRemaining = 0);
        timer.cancel();
        _onTimeout();
      }
    });

    // Demo: face detection after 2s, verification success after 4s
    Future.delayed(const Duration(seconds: 2), () async {
      if (!mounted || _hasNavigated) return;
      setState(() => _faceDetected = true);
      await _textFadeController.reverse();
      if (!mounted) return;
      setState(() => _statusText = 'Verifying...');
      _textFadeController.forward();
    });

    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && !_hasNavigated) {
        _hasNavigated = true;
        Navigator.of(context).pushReplacementNamed('/qr-success');
      }
    });
  }

  void _onTimeout() {
    if (_hasNavigated) return;
    _hasNavigated = true;
    Navigator.of(context).pushReplacementNamed('/qr-timeout', arguments: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scanLineController.dispose();
    _textFadeController.dispose();
    _timerPulseController.dispose();
    _ringController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final circleSize = screenSize.width * 0.70;
    final bool isUrgent = _secondsRemaining <= 20;
    final Color timerColor = isUrgent
        ? AppStyles.errorRed
        : AppStyles.successGreen;
    // On face detection, border briefly glows green
    final Color borderColor = _faceDetected
        ? AppStyles.successGreen
        : AppStyles.primaryBlue;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppStyles.backgroundLight,
        body: SafeArea(
          child: Column(
            children: [
              // ── Header ─────────────────────────────────────────────
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
                child: Center(
                  child: Text(
                    'Face Verification',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A202C),
                    ),
                  ),
                ),
              ),

              // ── Period pill ────────────────────────────────────────
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppStyles.primaryBlue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.menu_book_rounded,
                      size: 14,
                      color: AppStyles.primaryBlue.withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Marking: 3rd Period — DBMS',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppStyles.primaryBlue,
                      ),
                    ),
                  ],
                ),
              ),

              // ── Timer ring (above face circle, centered) ──────────
              ScaleTransition(
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
              const SizedBox(height: 12),

              // ── Face circle (identical to face_verification_screen) ───
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Camera area with scan line
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
                    // Pulsing border with glow (green on detection)
                    AnimatedBuilder(
                      animation: _pulseController,
                      builder: (context, child) {
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          width: circleSize,
                          height: circleSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: borderColor, width: 2.5),
                            boxShadow: [
                              BoxShadow(
                                color: borderColor.withValues(
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
              const SizedBox(height: 14),

              // ── Attempt text ──────────────────────────────────────
              Text(
                'Attempt $_attempt of 3',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade500,
                ),
              ),
              const SizedBox(height: 8),

              // ── Status instruction card ───────────────────────────
              Expanded(
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
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: Text(
                                _statusText,
                                key: ValueKey<String>(_statusText),
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: AppStyles.primaryBlue,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Center your face within the circle',
                              textAlign: TextAlign.center,
                              style: TextStyle(
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
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// Scan line painter — identical to the one in face_verification_screen.dart
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
  bool shouldRepaint(covariant _ScanLinePainter oldDelegate) => true;
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
