import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
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
  final _rollController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  String? _errorMessage;

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
    _rollController.dispose();
    _breatheController.dispose();
    _scanController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _onVerifyFace() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final rollNumber = _rollController.text.trim().toUpperCase();

      // Call Next.js API to get temporary session
      // Local development + production support
      const apiBase = String.fromEnvironment(
        'API_BASE',
        defaultValue: 'https://attend-secure.vercel.app',
      );

      final response = await http.post(
        Uri.parse('$apiBase/api/auth/forgot-password-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'roll_number': rollNumber}),
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode != 200) {
        setState(() {
          _errorMessage = data['error'] as String? ?? 'Something went wrong.';
          _isLoading = false;
        });
        return;
      }

      final refreshToken = data['refresh_token'] as String;

      // Establish session using both tokens
      await Supabase.instance.client.auth.setSession(refreshToken);

      if (!mounted) return;

      setState(() => _isLoading = false);

      // Navigate to real face verification with password_reset mode
      Navigator.of(
        context,
      ).pushNamed('/face_verification', arguments: 'password_reset');
    } catch (e) {
      debugPrint('[FORGOT_PW] Error: $e');

      if (mounted) {
        setState(() {
          _errorMessage = 'Network error. Check your connection and try again.';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final headingColor =
        theme.textTheme.displayLarge?.color ?? AppStyles.textDark;
    final subtitleColor =
        theme.textTheme.bodyMedium?.color ?? AppStyles.textGray;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.07);
    final inputFill = isDark
        ? const Color(0xFF1E2433)
        : AppStyles.backgroundLight;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: headingColor,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Forgot Password',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: headingColor,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),

              // ── Hero animation ──────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 160),
                child: Center(
                  child: SizedBox(
                    width: 180,
                    height: 180,
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
                        child: Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.primaryColor.withValues(alpha: 0.08),
                          ),
                          child: Icon(
                            Icons.lock_person_rounded,
                            size: 48,
                            color: theme.primaryColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // ── Heading ─────────────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 280),
                child: Text(
                  'Reset Your Password',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: headingColor,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              const SizedBox(height: 10),

              FadeSlideY(
                delay: const Duration(milliseconds: 340),
                child: Text(
                  'Enter your roll number, then verify\nyour face to reset your password.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    color: subtitleColor,
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // ── Roll number input ────────────────────────────────────────
              FadeSlideY(
                delay: const Duration(milliseconds: 400),
                child: Form(
                  key: _formKey,
                  child: TextFormField(
                    controller: _rollController,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _onVerifyFace(),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: headingColor,
                      letterSpacing: 0.5,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Roll Number',
                      hintText: 'e.g. 227Z1A6755',
                      labelStyle: const TextStyle(
                        color: AppStyles.textGray,
                        fontSize: 14,
                      ),
                      hintStyle: TextStyle(
                        color: AppStyles.textGray.withValues(alpha: 0.45),
                        fontSize: 14,
                      ),
                      prefixIcon: Icon(
                        Icons.badge_outlined,
                        size: 20,
                        color: AppStyles.textGray.withValues(alpha: 0.65),
                      ),
                      filled: true,
                      fillColor: inputFill,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: borderColor, width: 1),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: theme.primaryColor,
                          width: 1.5,
                        ),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: AppStyles.errorRed,
                          width: 1.2,
                        ),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: AppStyles.errorRed,
                          width: 1.5,
                        ),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Please enter your roll number';
                      }
                      return null;
                    },
                  ),
                ),
              ),

              // ── Error message ────────────────────────────────────────────
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                FadeSlideY(
                  delay: Duration.zero,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppStyles.errorRed.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppStyles.errorRed.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: AppStyles.errorRed,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppStyles.errorRed,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 24),

              // ── Security badge ────────────────────────────────────────────
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
                          'Face verified — no admin required',
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

              // ── Verify Face button ────────────────────────────────────────
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
                    onPressed: _isLoading ? () {} : _onVerifyFace,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      elevation: 0,
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: _isLoading
                          ? const SizedBox(
                              key: ValueKey('loading'),
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Row(
                              key: ValueKey('default'),
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.face_retouching_natural_rounded,
                                  size: 20,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Verify Face',
                                  style: TextStyle(fontSize: 16),
                                ),
                              ],
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

// ─── Security Scan Painter (unchanged) ─────────────────────────────────────
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

    final glowPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.04 + pulse * 0.06)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, outerRadius, glowPaint);

    final ringPaint = Paint()
      ..color = primaryColor.withValues(alpha: isDark ? 0.18 : 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, midRadius, ringPaint);

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
