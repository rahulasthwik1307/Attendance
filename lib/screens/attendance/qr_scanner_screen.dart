import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../utils/app_styles.dart';
import '../../services/supabase_service.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen>
    with TickerProviderStateMixin {
  late AnimationController _scanLineController;
  late AnimationController _bracketGlowController;
  late Animation<double> _bracketGlowOpacity;
  late MobileScannerController _scannerController;
  int _secondsRemaining = 180; // default, overridden from route args
  Timer? _countdownTimer;
  bool _hasNavigated = false;
  bool _timerInitialized = false;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();

    _scannerController = MobileScannerController();

    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();

    // Slow breathing glow for corner brackets
    _bracketGlowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _bracketGlowOpacity = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _bracketGlowController, curve: Curves.easeInOut),
    );
  }

  // ── Real Supabase QR validation flow ─────────────────────────────────
  Future<void> _onQrDetected(String scannedToken) async {
    if (_isProcessing || _hasNavigated) return;
    setState(() => _isProcessing = true);

    try {
      final currentUserId = supabase.auth.currentUser?.id;
      if (currentUserId == null) {
        _showError('You are not signed in. Please sign in and try again.');
        return;
      }

      // ── Step 1: Validate token ──────────────────────────────────────
      final tokenRows = await supabase
          .from('qr_tokens')
          .select()
          .eq('token', scannedToken)
          .eq('is_used', false)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .limit(1);

      if (tokenRows.isEmpty) {
        _showError(
          'QR code is expired or invalid. Please wait for the next rotation.',
        );
        return;
      }

      final tokenRecord = tokenRows[0];
      final String sessionId = tokenRecord['session_id'];

      // ── Step 2: Verify attendance session is active ─────────────────
      final sessionRows = await supabase
          .from('attendance_sessions')
          .select()
          .eq('id', sessionId)
          .eq('status', 'active')
          .limit(1);

      if (sessionRows.isEmpty) {
        _showError('QR session has ended.');
        return;
      }

      // ── Step 4: Upsert attendance as present in one operation ───────
      try {
        await supabase.from('period_attendance').upsert({
          'session_id': sessionId,
          'student_id': supabase.auth.currentUser!.id,
          'scanned_at': DateTime.now().toIso8601String(),
          'face_verified': false,
          'status': 'present',
        }, onConflict: 'session_id,student_id');
        debugPrint('Upsert result: success for session $sessionId');
      } catch (upsertError) {
        debugPrint('Upsert error: $upsertError');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to mark attendance: $upsertError'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      // ── Step 5: Mark token as used ──────────────────────────────────
      await supabase
          .from('qr_tokens')
          .update({'is_used': true})
          .eq('token', scannedToken);

      // ── Step 6: Navigate to attendance success screen ───────────────
      if (mounted && !_hasNavigated) {
        _hasNavigated = true;
        Navigator.of(
          context,
        ).pushReplacementNamed('/attendance_success', arguments: sessionId);
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppStyles.errorRed,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 4),
      ),
    );
    // Allow scanning again
    if (mounted) setState(() => _isProcessing = false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read route args and start timer only once
    if (!_timerInitialized) {
      _timerInitialized = true;
      final DateTime? endTime =
          ModalRoute.of(context)?.settings.arguments as DateTime?;
      if (endTime != null) {
        final remaining = endTime.difference(DateTime.now()).inSeconds;
        _secondsRemaining = remaining > 0 ? remaining : 0;
      }
      _startCountdown();
    }
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0) {
        setState(() => _secondsRemaining--);
        if (_secondsRemaining == 0) {
          timer.cancel();
          _showWindowClosedDialog();
        }
      }
    });
  }

  void _showWindowClosedDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppStyles.errorRed.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.timer_off_rounded,
                  color: AppStyles.errorRed,
                  size: 36,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Attendance Window Closed',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppStyles.textDark,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'The QR scanning window has expired. Please try again during the next attendance window.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: AppStyles.textGray,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).pushReplacementNamed('/dashboard');
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppStyles.primaryBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Go to Dashboard',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scannerController.dispose();
    _scanLineController.dispose();
    _bracketGlowController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color timerColor = _secondsRemaining <= 30
        ? AppStyles.errorRed
        : _secondsRemaining <= 60
        ? AppStyles.amberWarning
        : AppStyles.successGreen;
    final String mm = (_secondsRemaining ~/ 60).toString().padLeft(2, '0');
    final String ss = (_secondsRemaining % 60).toString().padLeft(2, '0');

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppStyles.textDark,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        centerTitle: true,
        title: const Text(
          'Scan QR Code',
          style: TextStyle(
            color: AppStyles.textDark,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
      body: Stack(
        children: [
          // ── Full-screen camera preview ───────────────────────
          Positioned.fill(
            child: MobileScanner(
              controller: _scannerController,
              onDetect: (BarcodeCapture barcodes) {
                final rawValue = barcodes.barcodes.first.rawValue;
                if (rawValue == null) return;
                if (_isProcessing) return;
                _onQrDetected(rawValue);
              },
            ),
          ),
          // ── Overlay UI on top of camera ──────────────────────
          SafeArea(
            child: Column(
              children: [
                // ── Info card (compact) ────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: AppStyles.primaryBlue.withValues(
                              alpha: 0.08,
                            ),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: const Icon(
                            Icons.menu_book_rounded,
                            color: AppStyles.primaryBlue,
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '3rd Period — DBMS',
                                style: TextStyle(
                                  color: AppStyles.textDark,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              SizedBox(height: 1),
                              Text(
                                'Room 301',
                                style: TextStyle(
                                  color: AppStyles.textGray,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'This code expires shortly',
                                style: TextStyle(
                                  color: AppStyles.textGray.withValues(
                                    alpha: 0.8,
                                  ),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 500),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: timerColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.timer_outlined,
                                size: 13,
                                color: timerColor,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '$mm:$ss',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                  color: timerColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Central scan area ──────────────────────────────────
                const Spacer(),
                Center(
                  child: SizedBox(
                    width: 240,
                    height: 240,
                    child: Stack(
                      children: [
                        // Corner brackets with breathing glow
                        AnimatedBuilder(
                          animation: _bracketGlowOpacity,
                          builder: (context, _) {
                            return CustomPaint(
                              size: const Size(240, 240),
                              painter: _ViewfinderPainter(
                                opacity: _bracketGlowOpacity.value,
                              ),
                            );
                          },
                        ),
                        // Animated scan line
                        AnimatedBuilder(
                          animation: _scanLineController,
                          builder: (context, _) {
                            final dy = _scanLineController.value * 240;
                            return Positioned(
                              top: dy,
                              left: 12,
                              right: 12,
                              child: Container(
                                height: 2,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.transparent,
                                      AppStyles.primaryBlue.withValues(
                                        alpha: 0.9,
                                      ),
                                      Colors.transparent,
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(1),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppStyles.primaryBlue.withValues(
                                        alpha: 0.5,
                                      ),
                                      blurRadius: 12,
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
                ),
                const SizedBox(height: 32),
                const Text(
                  'Point camera at the QR code',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'This code expires shortly',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 13,
                  ),
                ),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws four corner brackets with breathing glow opacity.
class _ViewfinderPainter extends CustomPainter {
  final double opacity;
  const _ViewfinderPainter({required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    const double bracketLen = 32;
    const double strokeW = 3.5;
    const double radius = 14;
    final paint = Paint()
      ..color = AppStyles.primaryBlue.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round;

    // Top-left
    canvas.drawArc(
      Rect.fromLTWH(0, 0, radius * 2, radius * 2),
      math.pi,
      math.pi / 2,
      false,
      paint,
    );
    canvas.drawLine(Offset(0, radius), Offset(0, bracketLen), paint);
    canvas.drawLine(Offset(radius, 0), Offset(bracketLen, 0), paint);

    // Top-right
    canvas.drawArc(
      Rect.fromLTWH(size.width - radius * 2, 0, radius * 2, radius * 2),
      -math.pi / 2,
      math.pi / 2,
      false,
      paint,
    );
    canvas.drawLine(
      Offset(size.width, radius),
      Offset(size.width, bracketLen),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - radius, 0),
      Offset(size.width - bracketLen, 0),
      paint,
    );

    // Bottom-left
    canvas.drawArc(
      Rect.fromLTWH(0, size.height - radius * 2, radius * 2, radius * 2),
      math.pi / 2,
      math.pi / 2,
      false,
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height - radius),
      Offset(0, size.height - bracketLen),
      paint,
    );
    canvas.drawLine(
      Offset(radius, size.height),
      Offset(bracketLen, size.height),
      paint,
    );

    // Bottom-right
    canvas.drawArc(
      Rect.fromLTWH(
        size.width - radius * 2,
        size.height - radius * 2,
        radius * 2,
        radius * 2,
      ),
      0,
      math.pi / 2,
      false,
      paint,
    );
    canvas.drawLine(
      Offset(size.width, size.height - radius),
      Offset(size.width, size.height - bracketLen),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - radius, size.height),
      Offset(size.width - bracketLen, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ViewfinderPainter old) =>
      old.opacity != opacity;
}
