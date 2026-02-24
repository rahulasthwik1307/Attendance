import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // Breathing / glow animation for the face hero
  late AnimationController _breatheController;
  late Animation<double> _breatheAnimation;

  // Slow scan ring rotation
  late AnimationController _scanController;

  @override
  void initState() {
    super.initState();

    _breatheController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat(reverse: true);
    _breatheAnimation = Tween<double>(begin: 0.92, end: 1.04).animate(
      CurvedAnimation(parent: _breatheController, curve: Curves.easeInOut),
    );

    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    )..repeat();
  }

  @override
  void dispose() {
    _breatheController.dispose();
    _scanController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headingColor =
        theme.textTheme.displayLarge?.color ?? AppStyles.textDark;
    final subtitleColor =
        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),

              // ── Branding ─────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 60),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: theme.primaryColor,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.shield_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Smart Attendance',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: theme.primaryColor,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(flex: 1),

              // ── Hero Visual ─────────────────────────────────────────────
              // Flexible so it gracefully shrinks on compact screens without overflow
              Flexible(
                flex: 12,
                child: FadeSlideY(
                  delay: const Duration(milliseconds: 160),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Cap hero between 160–220px based on available height
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
                            ]),
                            builder: (context, child) {
                              return Transform.scale(
                                scale: _breatheAnimation.value,
                                child: CustomPaint(
                                  painter: _FaceScanPainter(
                                    progress: _scanController.value,
                                    primaryColor: theme.primaryColor,
                                    isDark: isDark,
                                  ),
                                  child: child,
                                ),
                              );
                            },
                            child: Center(
                              child: Container(
                                width: heroSize * 0.50,
                                height: heroSize * 0.50,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: theme.primaryColor.withValues(
                                    alpha: 0.08,
                                  ),
                                ),
                                child: Icon(
                                  Icons.face_retouching_natural_rounded,
                                  size: heroSize * 0.265,
                                  color: theme.primaryColor,
                                ),
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

              // ── Heading ───────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 280),
                child: Text(
                  'Your Face is\nYour Key',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                    color: headingColor,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // ── Sub-heading ───────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 360),
                child: Text(
                  'Attendance powered by facial recognition\nand geo-fenced location security.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: subtitleColor,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),

              const Spacer(flex: 1),

              // ── Primary CTA: Activate Account ─────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 440),
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
                    onPressed: () =>
                        Navigator.of(context).pushNamed('/activate'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      elevation: 0, // shadow from Container
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person_add_alt_1_rounded, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Activate Account',
                          style: TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // ── Secondary CTA: Sign In ────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 520),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () =>
                        Navigator.of(context).pushNamed('/sign_in'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      side: BorderSide(
                        color: theme.primaryColor.withValues(alpha: 0.55),
                        width: 1.5,
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Sign In',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
              // Flexible so tagline gracefully disappears under pressure on tiny screens
              Flexible(
                fit: FlexFit.loose,
                child: FadeSlideY(
                  delay: const Duration(milliseconds: 600),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 13,
                          color: subtitleColor.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'Secure face & location-based attendance',
                          style: TextStyle(
                            fontSize: 12,
                            color: subtitleColor.withValues(alpha: 0.6),
                            fontWeight: FontWeight.w500,
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
      ),
    );
  }
}

// ─── Face Scan Ring Painter ────────────────────────────────────────────────────
class _FaceScanPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final bool isDark;

  _FaceScanPainter({
    required this.progress,
    required this.primaryColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width / 2;
    final midRadius = outerRadius * 0.78;

    // Static outer glow ring
    final glowPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.07)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, outerRadius, glowPaint);

    // Static mid ring (subtle border)
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
          primaryColor.withValues(alpha: 0.55),
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
      math.pi * 2 * 0.35, // 35% arc sweep
      false,
      sweepPaint,
    );

    // Corner bracket accents (top-left, top-right, bottom-left, bottom-right)
    _drawBracket(canvas, center, midRadius * 0.88, primaryColor);
  }

  void _drawBracket(Canvas canvas, Offset center, double r, Color color) {
    final bracketPaint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    const arcLen = 0.25; // in radians
    const offsets = [
      -math.pi * 3 / 4, // top-left
      -math.pi / 4, // top-right
      math.pi / 4, // bottom-right
      math.pi * 3 / 4, // bottom-left
    ];
    for (final start in offsets) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        start - arcLen / 2,
        arcLen,
        false,
        bracketPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_FaceScanPainter old) =>
      old.progress != progress || old.isDark != isDark;
}
