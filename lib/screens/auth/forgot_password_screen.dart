import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen>
    with TickerProviderStateMixin {
  late AnimationController _breatheController;
  late Animation<double> _breatheAnimation;
  late AnimationController _scanController;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _breatheController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat(reverse: true);

    _breatheAnimation = Tween<double>(begin: 0.93, end: 1.05).animate(
      CurvedAnimation(parent: _breatheController, curve: Curves.easeInOut),
    );

    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _breatheController.dispose();
    _scanController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final headingColor =
        theme.textTheme.displayLarge?.color ?? AppStyles.textDark;
    final subtitleColor =
        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppStyles.textDark,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Forgot Password',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppStyles.textDark,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 1),

              // ── Hero: Face Scan Visual ─────────────────────────────────────
              Flexible(
                flex: 12,
                child: FadeSlideY(
                  delay: const Duration(milliseconds: 160),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final heroSize = constraints.maxHeight.clamp(
                        160.0,
                        220.0,
                      );
                      return Center(
                        child: SizedBox(
                          width: heroSize,
                          height: heroSize,
                          child: AnimatedBuilder(
                            animation: Listenable.merge([
                              _breatheAnimation,
                              _scanController,
                              _pulseAnimation,
                            ]),
                            builder: (context, child) {
                              return Transform.scale(
                                scale: _breatheAnimation.value,
                                child: CustomPaint(
                                  painter: _SecurityScanPainter(
                                    progress: _scanController.value,
                                    pulse: _pulseAnimation.value,
                                    primaryColor: theme.primaryColor,
                                    isDark: isDark,
                                  ),
                                  child: child,
                                ),
                              );
                            },
                            child: Center(
                              child: Builder(
                                builder: (context) {
                                  final heroSize = constraints.maxHeight.clamp(
                                    160.0,
                                    220.0,
                                  );
                                  return Container(
                                    width: heroSize * 0.50,
                                    height: heroSize * 0.50,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: theme.primaryColor.withValues(
                                        alpha: 0.08,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.lock_person_rounded,
                                      size: heroSize * 0.265,
                                      color: theme.primaryColor,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

              const Spacer(flex: 1),

              // ── Headline ──────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 280),
                child: Text(
                  'Reset Your Password',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: headingColor,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // ── Sub-text ──────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 360),
                child: Text(
                  'Verify your face to reset your password.\nNo OTP. No email. Just you.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    color: subtitleColor,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),

              const Spacer(flex: 2),

              // ── Security Badge ────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 440),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: theme.primaryColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: theme.primaryColor.withValues(alpha: 0.18),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.shield_rounded,
                          size: 14,
                          color: theme.primaryColor,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Biometric — no admin required',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ── Primary CTA: Verify Face ───────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 500),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: theme.primaryColor.withValues(alpha: 0.30),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: AnimatedButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pushNamed('/forgot_password_face_verify'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      elevation: 0,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.face_retouching_natural_rounded, size: 20),
                        SizedBox(width: 8),
                        Text('Verify Face', style: TextStyle(fontSize: 16)),
                      ],
                    ),
                  ),
                ),
              ),

              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Security Scan Painter ──────────────────────────────────────────────────
class _SecurityScanPainter extends CustomPainter {
  final double progress;
  final double pulse;
  final Color primaryColor;
  final bool isDark;

  _SecurityScanPainter({
    required this.progress,
    required this.pulse,
    required this.primaryColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width / 2;
    final midRadius = outerRadius * 0.78;

    // Pulsing outer glow
    final glowPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.04 + pulse * 0.06)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, outerRadius, glowPaint);

    // Mid ring
    final ringPaint = Paint()
      ..color = primaryColor.withValues(alpha: isDark ? 0.18 : 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, midRadius, ringPaint);

    // Animated scanning arc
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        center: Alignment.center,
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [
          primaryColor.withValues(alpha: 0.0),
          primaryColor.withValues(alpha: 0.6),
          primaryColor.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
        transform: GradientRotation(progress * math.pi * 2),
      ).createShader(Rect.fromCircle(center: center, radius: midRadius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: midRadius),
      progress * math.pi * 2,
      math.pi * 2 * 0.35,
      false,
      sweepPaint,
    );

    // Corner brackets
    _drawBrackets(canvas, center, midRadius * 0.88, primaryColor);
  }

  void _drawBrackets(Canvas canvas, Offset center, double r, Color color) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    const arcLen = 0.25;
    const offsets = [
      -math.pi * 3 / 4,
      -math.pi / 4,
      math.pi / 4,
      math.pi * 3 / 4,
    ];
    for (final start in offsets) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        start - arcLen / 2,
        arcLen,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SecurityScanPainter old) =>
      old.progress != progress || old.pulse != pulse || old.isDark != isDark;
}
