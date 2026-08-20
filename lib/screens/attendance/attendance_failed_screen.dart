import 'package:flutter/material.dart';
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';

class AttendanceFailedScreen extends StatefulWidget {
  const AttendanceFailedScreen({super.key});

  @override
  State<AttendanceFailedScreen> createState() => _AttendanceFailedScreenState();
}

class _AttendanceFailedScreenState extends State<AttendanceFailedScreen>
    with TickerProviderStateMixin {
  // ── Pop-in scale for the icon circle ────────────────────────────────────
  late AnimationController _popController;
  late Animation<double> _popAnimation;

  // ── Drawing animation for the X strokes ─────────────────────────────────
  late AnimationController _drawController;
  late Animation<double> _stroke1;
  late Animation<double> _stroke2;

  // ── Continuous soft pulse halo ───────────────────────────────────────────
  late AnimationController _haloController;

  @override
  void initState() {
    super.initState();

    // 1. Pop-in the outer circle
    _popController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _popAnimation = CurvedAnimation(
      parent: _popController,
      curve: Curves.elasticOut,
    );

    // 2. Draw the two strokes of the ✕ after the circle appears
    _drawController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _stroke1 = CurvedAnimation(
      parent: _drawController,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
    );
    _stroke2 = CurvedAnimation(
      parent: _drawController,
      curve: const Interval(0.45, 1.0, curve: Curves.easeOut),
    );

    // 3. Soft pulsing halo that repeats
    _haloController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    // Sequence: pop → draw ✕
    _popController.forward().then((_) {
      if (mounted) _drawController.forward();
    });
  }

  @override
  void dispose() {
    _popController.dispose();
    _drawController.dispose();
    _haloController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final String? mode = ModalRoute.of(context)?.settings.arguments as String?;

    // Gradient colours
    const Color redDeep = Color(0xFFDC2626);
    const Color redLight = Color(0xFFEF4444);
    final Color bgColor = isDark ? const Color(0xFF0F172A) : const Color(0xFFFFF5F5);
    final Color surfaceColor = isDark ? const Color(0xFF1E293B) : Colors.white;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.close_rounded,
            color: isDark ? Colors.white70 : AppStyles.textDark,
          ),
          onPressed: () =>
              Navigator.of(context).pushReplacementNamed('/dashboard'),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),

              // ── Premium ✕ Icon ───────────────────────────────────────────
              Center(
                child: AnimatedBuilder(
                  animation: Listenable.merge([
                    _popAnimation,
                    _stroke1,
                    _stroke2,
                    _haloController,
                  ]),
                  builder: (context, _) {
                    final halo = _haloController.value;
                    return SizedBox(
                      width: 160,
                      height: 160,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Outermost soft halo ring
                          Container(
                            width: 140 + halo * 20,
                            height: 140 + halo * 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: redDeep.withValues(
                                alpha: (0.06 - halo * 0.04).clamp(0.0, 1.0),
                              ),
                            ),
                          ),

                          // Mid halo ring
                          Container(
                            width: 112 + halo * 12,
                            height: 112 + halo * 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: redDeep.withValues(
                                alpha: (0.10 - halo * 0.05).clamp(0.0, 1.0),
                              ),
                            ),
                          ),

                          // Main circle with gradient + shadow — scales in
                          Transform.scale(
                            scale: _popAnimation.value.clamp(0.0, 1.0),
                            child: Container(
                              width: 92,
                              height: 92,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const RadialGradient(
                                  colors: [redLight, redDeep],
                                  center: Alignment(-0.3, -0.3),
                                  radius: 0.9,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: redDeep.withValues(alpha: 0.45),
                                    blurRadius: 28,
                                    spreadRadius: 2,
                                    offset: const Offset(0, 8),
                                  ),
                                  BoxShadow(
                                    color: redLight.withValues(alpha: 0.25),
                                    blurRadius: 10,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: CustomPaint(
                                painter: _CrossPainter(
                                  stroke1Progress: _stroke1.value,
                                  stroke2Progress: _stroke2.value,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 32),

              // ── Title ───────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 300),
                child: Text(
                  'Verification Failed',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // ── Subtitle ────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 380),
                child: Text(
                  mode == 'forgot_password'
                      ? 'We could not verify your identity.\nPlease try again in good lighting.'
                      : 'Face did not match the registered\nprofile. Please try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14.5,
                    color: isDark ? Colors.grey.shade400 : AppStyles.textGray,
                    height: 1.55,
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // ── Tips card ───────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 460),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: surfaceColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : const Color(0xFFE2E8F0),
                    ),
                    boxShadow: isDark
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header row — Flexible prevents overflow
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: AppStyles.primaryBlue.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: const Icon(
                              Icons.lightbulb_outline_rounded,
                              color: AppStyles.primaryBlue,
                              size: 17,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              'Tips for successful verification',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF0F172A),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _TipItem(
                        text:
                            'Ensure your face is well-lit without backlighting',
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _TipItem(
                        text: 'Look straight at the camera and keep steady',
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _TipItem(
                        text: 'Remove sunglasses, heavy masks, or hats',
                        isDark: isDark,
                      ),
                    ],
                  ),
                ),
              ),

              const Spacer(flex: 2),

              // ── CTA button ──────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 560),
                child: SizedBox(
                  width: double.infinity,
                  child: AnimatedButton(
                    onPressed: () {
                      if (mode == 'forgot_password') {
                        Navigator.of(context).pushReplacementNamed(
                          '/forgot_password_face_verify',
                        );
                      } else {
                        Navigator.of(context).pushReplacementNamed(
                          '/face_verification',
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: redDeep,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 17),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Try Again',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Custom painter that draws ✕ stroke by stroke ────────────────────────────
class _CrossPainter extends CustomPainter {
  final double stroke1Progress;
  final double stroke2Progress;

  const _CrossPainter({
    required this.stroke1Progress,
    required this.stroke2Progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final cx = size.width / 2;
    final cy = size.height / 2;
    const inset = 22.0;

    // Stroke 1: top-left → bottom-right
    final s1x = cx - inset + (2 * inset) * stroke1Progress;
    final s1y = cy - inset + (2 * inset) * stroke1Progress;
    canvas.drawLine(
      Offset(cx - inset, cy - inset),
      Offset(s1x, s1y),
      paint,
    );

    // Stroke 2: top-right → bottom-left (draws after stroke1 starts)
    if (stroke2Progress > 0) {
      final s2x = cx + inset - (2 * inset) * stroke2Progress;
      final s2y = cy - inset + (2 * inset) * stroke2Progress;
      canvas.drawLine(
        Offset(cx + inset, cy - inset),
        Offset(s2x, s2y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_CrossPainter old) =>
      old.stroke1Progress != stroke1Progress ||
      old.stroke2Progress != stroke2Progress;
}

// ── Tip row ────────────────────────────────────────────────────────────────
class _TipItem extends StatelessWidget {
  final String text;
  final bool isDark;

  const _TipItem({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6.0, right: 10.0),
          child: Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppStyles.errorRed.withValues(alpha: 0.6),
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.grey.shade400 : AppStyles.textGray,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}
