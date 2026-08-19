import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../utils/app_styles.dart';
import '../../services/supabase_service.dart';

Completer<void>? qrScannerReleaseCompleter;

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
  late AnimationController _timerPulseController;
  late Animation<double> _timerPulseAnimation;
  late MobileScannerController _scannerController;
  int _secondsRemaining = 180; // default, overridden from route args
  Timer? _countdownTimer;
  Timer? _errorDismissTimer;
  bool _hasNavigated = false;
  bool _timerInitialized = false;
  bool _isProcessing = false;
  String _subjectPeriodLabel = 'Loading...';
  bool _infoLoaded = false;
  String? _forwardedSubjectName;
  String? _forwardedPeriodInfo;
  String? _errorMessage;

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
    _bracketGlowOpacity = Tween<double>(begin: 0.65, end: 1.0).animate(
      CurvedAnimation(parent: _bracketGlowController, curve: Curves.easeInOut),
    );

    // Gentle breathing pulse for countdown timer
    _timerPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _timerPulseAnimation = Tween<double>(begin: 0.96, end: 1.0).animate(
      CurvedAnimation(parent: _timerPulseController, curve: Curves.easeInOut),
    );
  }

  Future<void> _fetchSessionInfo(String sessionId) async {
    try {
      final sessionData = await supabase
          .from('attendance_sessions')
          .select('subject_id, period_id')
          .eq('id', sessionId)
          .maybeSingle();
      if (sessionData == null) return;

      final results = await Future.wait([
        supabase
            .from('subjects')
            .select('name')
            .eq('id', sessionData['subject_id'])
            .maybeSingle(),
        supabase
            .from('periods')
            .select('period_number')
            .eq('id', sessionData['period_id'])
            .maybeSingle(),
      ]);

      final subjectName = results[0]?['name'] as String? ?? '';
      final periodNum = results[1]?['period_number'] as int? ?? 1;

      String getOrdinal(int n) {
        if (n >= 11 && n <= 13) return 'th';
        switch (n % 10) {
          case 1:
            return 'st';
          case 2:
            return 'nd';
          case 3:
            return 'rd';
          default:
            return 'th';
        }
      }

      if (mounted) {
        setState(() {
          _forwardedPeriodInfo = '$periodNum${getOrdinal(periodNum)} Period';
          _forwardedSubjectName = subjectName;
          _subjectPeriodLabel =
              '$periodNum${getOrdinal(periodNum)} Period — $subjectName';
          _infoLoaded = true;
        });
      }
    } catch (e) {
      debugPrint('[QR_SCANNER] Failed to fetch session info: $e');
    }
  }

  String get _periodText {
    if (_forwardedPeriodInfo != null && _forwardedPeriodInfo!.isNotEmpty) {
      return _forwardedPeriodInfo!;
    }
    if (_subjectPeriodLabel.contains(' — ')) {
      return _subjectPeriodLabel.split(' — ').first;
    }
    return _infoLoaded ? 'Active Period' : 'Loading...';
  }

  String get _subjectText {
    if (_forwardedSubjectName != null && _forwardedSubjectName!.isNotEmpty) {
      return _forwardedSubjectName!;
    }
    if (_subjectPeriodLabel.contains(' — ')) {
      return _subjectPeriodLabel.split(' — ').last;
    }
    return _subjectPeriodLabel;
  }

  // ── Real Supabase QR validation flow ─────────────────────────────────
  Future<void> _onQrDetected(String scannedToken) async {
    if (_isProcessing || _hasNavigated) return;

    // Clear any existing error state immediately on new scan attempt
    _errorDismissTimer?.cancel();
    if (mounted && _errorMessage != null) {
      setState(() => _errorMessage = null);
    }

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

      if (!_infoLoaded) _fetchSessionInfo(sessionId);

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

      // ── Step 4: Upsert attendance as pending — face verify will upgrade to present ───────
      try {
        await supabase.from('period_attendance').upsert({
          'session_id': sessionId,
          'student_id': supabase.auth.currentUser!.id,
          'scanned_at': DateTime.now().toIso8601String(),
          'face_verified': false,
          'status': 'pending',
        }, onConflict: 'session_id,student_id');
        debugPrint('Upsert result: success for session $sessionId');
      } catch (upsertError) {
        debugPrint('Upsert error: $upsertError');
        _showError('Failed to mark attendance. Please try again.');
        return;
      }

      // ── Step 5: Mark token as used ──────────────────────────────────
      await supabase
          .from('qr_tokens')
          .update({'is_used': true})
          .eq('token', scannedToken);

      // ── Step 6: Navigate to face verification ───────────────────────
      if (mounted && !_hasNavigated) {
        _hasNavigated = true;
        // Explicitly cancel error timer and wipe any lingering error state before pushing
        _errorDismissTimer?.cancel();
        _errorMessage = null;

        Navigator.of(context).pushReplacementNamed(
          '/qr-face-verify',
          arguments: {
            'session_id': sessionId,
            'subject_name': _forwardedSubjectName,
            'period_info': _forwardedPeriodInfo,
          },
        );
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    _errorDismissTimer?.cancel();
    setState(() {
      _errorMessage = message;
      _isProcessing = false;
    });

    _errorDismissTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted) {
        setState(() {
          _errorMessage = null;
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read route args and start timer only once
    if (!_timerInitialized) {
      _timerInitialized = true;
      final args = ModalRoute.of(context)?.settings.arguments;
      DateTime? endTime;
      if (args is Map) {
        endTime = args['end_time'] as DateTime?;
        _forwardedSubjectName = args['subject_name'] as String?;
        _forwardedPeriodInfo = args['period_info'] as String?;
        if (_forwardedSubjectName != null &&
            _forwardedSubjectName!.isNotEmpty &&
            _forwardedPeriodInfo != null &&
            _forwardedPeriodInfo!.isNotEmpty) {
          String cleanPeriod = _forwardedPeriodInfo!;
          final timeRangeRegex = RegExp(r'\s+\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}');
          cleanPeriod = cleanPeriod.replaceAll(timeRangeRegex, '').trim();
          _forwardedPeriodInfo = cleanPeriod;
          _subjectPeriodLabel = '$cleanPeriod — $_forwardedSubjectName';
          _infoLoaded = true;
        }
      } else if (args is DateTime) {
        endTime = args;
      }
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
    _errorDismissTimer?.cancel();
    qrScannerReleaseCompleter = Completer<void>();
    Future(() async {
      try {
        await _scannerController.dispose();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));
      qrScannerReleaseCompleter!.complete();
      qrScannerReleaseCompleter = null;
    });
    _scanLineController.dispose();
    _bracketGlowController.dispose();
    _timerPulseController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  // ─── Coordinate Filtering helper (strictly validates against qrTargetRect) ──
  bool _isBarcodeInsideTarget(
    Barcode barcode,
    Size imageSize,
    Size screenSize,
    Rect qrTargetRect,
  ) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return true;

    final double scaleX = screenSize.width / imageSize.width;
    final double scaleY = screenSize.height / imageSize.height;
    final double scale = math.max(scaleX, scaleY);
    final double scaledW = imageSize.width * scale;
    final double scaledH = imageSize.height * scale;
    final double offsetX = (screenSize.width - scaledW) / 2;
    final double offsetY = (screenSize.height - scaledH) / 2;

    if (barcode.corners.isNotEmpty) {
      double minX = double.infinity;
      double maxX = -double.infinity;
      double minY = double.infinity;
      double maxY = -double.infinity;
      double sumX = 0;
      double sumY = 0;

      for (final corner in barcode.corners) {
        final double screenX = corner.dx * scale + offsetX;
        final double screenY = corner.dy * scale + offsetY;
        minX = math.min(minX, screenX);
        maxX = math.max(maxX, screenX);
        minY = math.min(minY, screenY);
        maxY = math.max(maxY, screenY);
        sumX += screenX;
        sumY += screenY;
      }

      final Offset center = Offset(
        sumX / barcode.corners.length,
        sumY / barcode.corners.length,
      );

      // Bounding box margin for target detection tolerance while strictly excluding out-of-frame codes
      final Rect allowedBounds = qrTargetRect.inflate(16);
      final bool centerInside = allowedBounds.contains(center);
      final Rect barcodeRect = Rect.fromLTRB(minX, minY, maxX, maxY);
      final bool overlaps = allowedBounds.overlaps(barcodeRect);

      return centerInside || overlaps;
    }

    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final Color timerColor = _secondsRemaining <= 30
        ? AppStyles.errorRed
        : _secondsRemaining <= 60
        ? AppStyles.amberWarning
        : AppStyles.successGreen;
    final String mm = (_secondsRemaining ~/ 60).toString().padLeft(2, '0');
    final String ss = (_secondsRemaining % 60).toString().padLeft(2, '0');

    final Size screenSize = MediaQuery.of(context).size;
    final double topSafe = MediaQuery.of(context).padding.top;
    final double bottomSafe = MediaQuery.of(context).padding.bottom;

    // ── 1. Top Info Card Geometry ──────────────────────────────────────────
    final double infoCardTop = topSafe + 48.0;
    const double infoCardHeight = 106.0;
    final double infoCardBottom = infoCardTop + infoCardHeight;

    // ── 2. Outer Camera Preview Geometry ────────────────────────────────────
    final double cameraPreviewSize = math.min(
      304.0,
      screenSize.width - 48.0,
    );
    // Shift camera preview + scanner group comfortably downward
    final double cameraPreviewTop = infoCardBottom + 36.0;
    final double cameraPreviewLeft =
        (screenSize.width - cameraPreviewSize) / 2.0;

    final Rect cameraPreviewRect = Rect.fromLTWH(
      cameraPreviewLeft,
      cameraPreviewTop,
      cameraPreviewSize,
      cameraPreviewSize,
    );

    // ── 3. Inner Blue QR Target Frame Geometry (Centered inside preview) ──────
    const double targetInset = 34.0;
    final double qrTargetSize = cameraPreviewSize - (targetInset * 2.0);

    final Rect qrTargetRect = Rect.fromLTWH(
      cameraPreviewRect.left + targetInset,
      cameraPreviewRect.top + targetInset,
      qrTargetSize,
      qrTargetSize,
    );

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
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
            fontWeight: FontWeight.w700,
            fontSize: 18,
            letterSpacing: -0.3,
          ),
        ),
      ),
      body: Stack(
        children: [
          // ── Layer 1: Full-screen camera preview at base layer ──────────────────
          Positioned.fill(
            child: MobileScanner(
              controller: _scannerController,
              scanWindow: qrTargetRect,
              onDetect: (BarcodeCapture barcodes) {
                if (_isProcessing || _hasNavigated) return;
                for (final barcode in barcodes.barcodes) {
                  final rawValue = barcode.rawValue;
                  if (rawValue == null || rawValue.isEmpty) continue;

                  // Restrict barcode detection strictly to the INNER QR target frame
                  final bool isInside = _isBarcodeInsideTarget(
                    barcode,
                    barcodes.size,
                    screenSize,
                    qrTargetRect,
                  );

                  if (isInside) {
                    _onQrDetected(rawValue);
                    break;
                  } else {
                    debugPrint(
                      '[QR_SCANNER] Ignored barcode outside inner QR target frame',
                    );
                  }
                }
              },
            ),
          ),

          // ── Layer 2: White/Light Background Cutout Mask (Outer cameraPreviewRect) ──
          Positioned.fill(
            child: CustomPaint(
              painter: _ScanWindowCutoutPainter(
                cameraPreviewRect: cameraPreviewRect,
                backgroundColor: theme.scaffoldBackgroundColor,
              ),
            ),
          ),

          // ── Layer 3: Inner Blue QR Target Frame & Laser Scan Line ─────────────
          Positioned(
            left: qrTargetRect.left,
            top: qrTargetRect.top,
            width: qrTargetRect.width,
            height: qrTargetRect.height,
            child: Stack(
              children: [
                // Corner brackets with breathing glow animation
                AnimatedBuilder(
                  animation: _bracketGlowOpacity,
                  builder: (context, _) {
                    return CustomPaint(
                      size: Size(qrTargetRect.width, qrTargetRect.height),
                      painter: _ViewfinderPainter(
                        opacity: _bracketGlowOpacity.value,
                      ),
                    );
                  },
                ),
                // Animated laser scan line bounded strictly inside qrTargetRect
                AnimatedBuilder(
                  animation: _scanLineController,
                  builder: (context, _) {
                    final dy = _scanLineController.value * qrTargetRect.height;
                    return Positioned(
                      top: dy,
                      left: 10,
                      right: 10,
                      child: Container(
                        height: 2.5,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              AppStyles.primaryBlue.withValues(alpha: 0.95),
                              Colors.transparent,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(2),
                          boxShadow: [
                            BoxShadow(
                              color: AppStyles.primaryBlue.withValues(
                                alpha: 0.65,
                              ),
                              blurRadius: 12,
                              spreadRadius: 2.0,
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

          // ── Layer 4: Top Info Card (Premium Attendance Session Indicator) ─────
          Positioned(
            top: infoCardTop,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.1)
                      : const Color(0xFFE2E8F0),
                  width: 1.2,
                ),
                boxShadow: isDark
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 18,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Top Row: Icon  +  Period label  +  Timer pill ──────
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Book icon
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: AppStyles.primaryBlue.withValues(
                            alpha: isDark ? 0.22 : 0.09,
                          ),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: const Icon(
                          Icons.menu_book_rounded,
                          color: AppStyles.primaryBlue,
                          size: 19,
                        ),
                      ),
                      const SizedBox(width: 11),

                      // Period label (e.g. "4th Period") takes remaining space
                      Expanded(
                        child: Text(
                          _periodText,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? Colors.grey.shade400
                                : AppStyles.textGray,
                            letterSpacing: -0.1,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 10),

                      // ── Countdown timer pill ──────────────────────────
                      ScaleTransition(
                        scale: _timerPulseAnimation,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 76),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: timerColor.withValues(alpha: 0.11),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: timerColor.withValues(alpha: 0.30),
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.timer_outlined,
                                size: 14,
                                color: timerColor,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                '$mm:$ss',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                  color: timerColor,
                                  letterSpacing: 0.5,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),

                  // ── Subject Name (full width — no clipping possible) ──
                  Text(
                    _subjectText,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: isDark ? Colors.white : AppStyles.textDark,
                      letterSpacing: -0.4,
                      height: 1.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),

                  // ── Status line ───────────────────────────────────────
                  Text(
                    'Active attendance session',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: timerColor.withValues(alpha: 0.80),
                      letterSpacing: 0.0,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),

          // ── Layer 5: Instructions below camera preview ────────────────────────
          Positioned(
            top: cameraPreviewRect.bottom + 24.0,
            left: 20,
            right: 20,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Point camera at the QR code',
                  style: TextStyle(
                    color: isDark ? Colors.white : const Color(0xFF1E293B),
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Rotating QR code refreshes periodically',
                  style: TextStyle(
                    color: isDark ? Colors.grey.shade400 : AppStyles.textGray,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // ── Layer 6: In-flow Error Banner (Dismissible & Auto-cleared) ──────────
          Positioned(
            bottom: math.max(bottomSafe + 16, 24),
            left: 20,
            right: 20,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.2),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: _errorMessage != null
                  ? Container(
                      key: ValueKey<String>(_errorMessage!),
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppStyles.errorRed.withValues(alpha: 0.12)
                            : const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppStyles.errorRed.withValues(
                            alpha: isDark ? 0.3 : 0.2,
                          ),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppStyles.errorRed.withValues(alpha: 0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: AppStyles.errorRed.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.info_outline_rounded,
                              color: AppStyles.errorRed,
                              size: 16,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? Colors.red.shade200
                                    : const Color(0xFF991B1B),
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Creates a solid background with a transparent rounded-rectangle cutout
/// for the outer camera preview area.
class _ScanWindowCutoutPainter extends CustomPainter {
  final Rect cameraPreviewRect;
  final Color backgroundColor;

  const _ScanWindowCutoutPainter({
    required this.cameraPreviewRect,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Path backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final Path cameraPreviewPath = Path()
      ..addRRect(
        RRect.fromRectAndRadius(cameraPreviewRect, const Radius.circular(20)),
      );

    final Path cutoutPath = Path.combine(
      PathOperation.difference,
      backgroundPath,
      cameraPreviewPath,
    );

    final Paint paint = Paint()..color = backgroundColor;
    canvas.drawPath(cutoutPath, paint);

    // Subtle polished border around the outer camera preview window
    final Paint borderPaint = Paint()
      ..color = const Color(0xFF3B82F6).withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawRRect(
      RRect.fromRectAndRadius(cameraPreviewRect, const Radius.circular(20)),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScanWindowCutoutPainter oldDelegate) {
    return oldDelegate.cameraPreviewRect != cameraPreviewRect ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}

/// Draws four perfectly symmetrical corner brackets with breathing glow opacity.
class _ViewfinderPainter extends CustomPainter {
  final double opacity;
  const _ViewfinderPainter({required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    const double bracketLen = 28.0;
    const double strokeW = 4.0;
    const double radius = 14.0;

    final paint = Paint()
      ..color = AppStyles.primaryBlue.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round;

    // Top-left corner
    canvas.drawArc(
      Rect.fromLTWH(0, 0, radius * 2, radius * 2),
      math.pi,
      math.pi / 2,
      false,
      paint,
    );
    canvas.drawLine(Offset(0, radius), Offset(0, bracketLen), paint);
    canvas.drawLine(Offset(radius, 0), Offset(bracketLen, 0), paint);

    // Top-right corner
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

    // Bottom-left corner
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

    // Bottom-right corner
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
