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
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _scanLineController;
  late AnimationController _bracketGlowController;
  late Animation<double> _bracketGlowOpacity;
  late AnimationController _timerPulseController;
  late Animation<double> _timerPulseAnimation;
  late MobileScannerController _scannerController;
  int _secondsRemaining = 180; // default, overridden from route args
  String? _sessionId;
  DateTime? _sessionDeadline;
  bool _isRevalidating = false;
  Timer? _countdownTimer;
  Timer? _errorDismissTimer;
  bool _hasNavigated = false;
  bool _timerInitialized = false;
  bool _isProcessing = false;
  String _subjectPeriodLabel = 'Loading...';
  bool _infoLoaded = false;
  String? _forwardedSubjectName;
  String? _forwardedPeriodInfo;
  String? _forwardedPeriodTiming;
  String? _errorMessage;

  int _calculateRemaining() {
    if (_sessionDeadline == null) return _secondsRemaining;
    final remaining =
        _sessionDeadline!.difference(DateTime.now().toUtc()).inSeconds;
    return math.max(0, remaining);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

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
            .select('period_number, start_time, end_time')
            .eq('id', sessionData['period_id'])
            .maybeSingle(),
      ]);

      final subjectName = results[0]?['name'] as String? ?? '';
      final periodNum = results[1]?['period_number'] as int? ?? 1;
      final rawStart = results[1]?['start_time'] as String? ?? '';
      final rawEnd = results[1]?['end_time'] as String? ?? '';
      String timing = '';
      if (rawStart.isNotEmpty && rawEnd.isNotEmpty) {
        final s = rawStart.length >= 5 ? rawStart.substring(0, 5) : rawStart;
        final e = rawEnd.length >= 5 ? rawEnd.substring(0, 5) : rawEnd;
        timing = '$s - $e';
      }

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
          if (timing.isNotEmpty) {
            _forwardedPeriodTiming = timing;
          }
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
    return _infoLoaded ? 'Period' : 'Loading...';
  }

  String get _timingText {
    if (_forwardedPeriodTiming != null && _forwardedPeriodTiming!.isNotEmpty) {
      return _forwardedPeriodTiming!;
    }
    return '';
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

      final sessionRecord = sessionRows[0];
      final openedAtStr = sessionRecord['opened_at'] as String?;
      DateTime? sessionDeadline;
      if (openedAtStr != null) {
        try {
          final openedAt = DateTime.parse(openedAtStr).toUtc();
          sessionDeadline = openedAt.add(const Duration(seconds: 180));
        } catch (_) {}
      }

      if (sessionDeadline != null) {
        final remaining =
            sessionDeadline.difference(DateTime.now().toUtc()).inSeconds;
        if (remaining <= 0) {
          _showError('Attendance window has closed.');
          return;
        }
      }

      // ── Step 4: Upsert attendance as pending — face verify will upgrade to present ───────
      try {
        await supabase.from('period_attendance').upsert({
          'session_id': sessionId,
          'student_id': supabase.auth.currentUser!.id,
          'scanned_at': DateTime.now().toUtc().toIso8601String(),
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
            'deadline': sessionDeadline ?? _sessionDeadline,
            'subject_name': _forwardedSubjectName,
            'period_info': _forwardedPeriodInfo,
            'period_timing': _forwardedPeriodTiming,
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
        _sessionId = args['session_id'] as String?;
        _sessionDeadline = args['deadline'] as DateTime?;
        endTime = args['end_time'] as DateTime?;
        _forwardedSubjectName = args['subject_name'] as String?;
        _forwardedPeriodInfo = args['period_info'] as String?;
        if (args['period_timing'] is String &&
            (args['period_timing'] as String).isNotEmpty) {
          _forwardedPeriodTiming = args['period_timing'] as String?;
        } else if (args['timing'] is String &&
            (args['timing'] as String).isNotEmpty) {
          _forwardedPeriodTiming = args['timing'] as String?;
        }
        if (_forwardedPeriodInfo != null && _forwardedPeriodInfo!.isNotEmpty) {
          final timeRangeRegex = RegExp(
            r'\d{1,2}:\d{2}(?:\s*[AaPp][Mm])?\s*[-–—]\s*\d{1,2}:\d{2}(?:\s*[AaPp][Mm])?',
          );
          final match = timeRangeRegex.firstMatch(_forwardedPeriodInfo!);
          if (match != null) {
            _forwardedPeriodTiming = match.group(0)?.trim();
          }
        }
        if (_forwardedSubjectName != null &&
            _forwardedSubjectName!.isNotEmpty &&
            _forwardedPeriodInfo != null &&
            _forwardedPeriodInfo!.isNotEmpty) {
          String cleanPeriod = _forwardedPeriodInfo!;
          final timeRangeRegex = RegExp(
            r'\s*\(?\s*\d{1,2}:\d{2}(?:\s*[AaPp][Mm])?\s*[-–—]\s*\d{1,2}:\d{2}(?:\s*[AaPp][Mm])?\s*\)?',
          );
          cleanPeriod = cleanPeriod.replaceAll(timeRangeRegex, '').trim();
          _forwardedPeriodInfo = cleanPeriod;
          _subjectPeriodLabel = '$cleanPeriod — $_forwardedSubjectName';
          _infoLoaded = true;
        }
      } else if (args is DateTime) {
        endTime = args;
      }
      _sessionDeadline ??= endTime;
      if (_sessionDeadline != null) {
        _secondsRemaining = _calculateRemaining();
      }
      if (_sessionId != null) {
        _revalidateSession();
      }
      _startCountdown();
    }
  }

  Future<void> _revalidateSession() async {
    if (_sessionId == null || !mounted || _isRevalidating) return;
    _isRevalidating = true;
    try {
      final sessionData = await supabase
          .from('attendance_sessions')
          .select('status, opened_at, subject_id, period_id')
          .eq('id', _sessionId!)
          .maybeSingle();

      if (!mounted || _hasNavigated) return;
      if (sessionData == null || sessionData['status'] != 'active') {
        _countdownTimer?.cancel();
        _showWindowClosedDialog();
        return;
      }

      final openedAtStr = sessionData['opened_at'] as String?;
      if (openedAtStr != null) {
        try {
          final openedAt = DateTime.parse(openedAtStr).toUtc();
          _sessionDeadline = openedAt.add(const Duration(seconds: 180));
          final remaining = _calculateRemaining();
          setState(() => _secondsRemaining = remaining);
          if (remaining <= 0) {
            _countdownTimer?.cancel();
            _showWindowClosedDialog();
            return;
          }
        } catch (_) {}
      }

      if (!_infoLoaded) {
        _fetchSessionInfo(_sessionId!);
      }
    } catch (e) {
      debugPrint('[QR_SCANNER] Error revalidating session: $e');
    } finally {
      _isRevalidating = false;
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _hasNavigated) {
        timer.cancel();
        return;
      }
      final remaining = _calculateRemaining();
      setState(() => _secondsRemaining = remaining);
      if (remaining <= 0) {
        timer.cancel();
        _showWindowClosedDialog();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted && !_hasNavigated) {
        final remaining = _calculateRemaining();
        setState(() => _secondsRemaining = remaining);
        if (remaining <= 0) {
          _countdownTimer?.cancel();
          _showWindowClosedDialog();
        } else {
          _revalidateSession();
        }
      }
    }
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
    WidgetsBinding.instance.removeObserver(this);
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
    final double infoCardTop = topSafe + kToolbarHeight + 14.0;
    const double infoCardHeight = 130.0; // increased to accommodate variable content
    final double infoCardBottom = infoCardTop + infoCardHeight;
    final double cardHorizontalMargin = math.max(
      34.0,
      (screenSize.width - 330.0) / 2.0,
    );

    // ── 2. Outer Camera Preview Geometry ────────────────────────────────────
    final double cameraPreviewSize = math.min(304.0, screenSize.width - 48.0);
    // Shift camera preview + scanner group comfortably downward
    final double cameraPreviewTop = infoCardBottom + 30.0;
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
            left: cardHorizontalMargin,
            right: cardHorizontalMargin,
            child: () {
              final subjectTheme = _getSubjectColorTheme(_subjectText);
              return Container(
                // height removed to allow flexible content size
                decoration: BoxDecoration(
                  gradient: isDark
                      ? const LinearGradient(
                          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        )
                      : LinearGradient(
                          colors: [
                            Colors.white,
                            subjectTheme.primary.withValues(alpha: 0.03),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: isDark
                        ? subjectTheme.primary.withValues(alpha: 0.35)
                        : subjectTheme.primary.withValues(alpha: 0.22),
                    width: 1.2,
                  ),
                  boxShadow: isDark
                      ? [
                          BoxShadow(
                            color: subjectTheme.primary.withValues(alpha: 0.14),
                            blurRadius: 18,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.40),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: subjectTheme.primary.withValues(alpha: 0.08),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 6,
                            offset: const Offset(0, 1),
                          ),
                        ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16.8),
                  child: Stack(
                    children: [
                      
                      // Content
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 12,
                          right: 13,
                          top: 10,
                          bottom: 10,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // ── LEFT: Period badge + Subject + Active Indicator/Timing ──
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Period label — elegant styled metadata badge
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7.5,
                                      vertical: 2.2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? subjectTheme.darkBadgeBg
                                          : subjectTheme.lightBadgeBg,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: isDark
                                            ? subjectTheme.darkBadgeBorder
                                            : subjectTheme.lightBadgeBorder,
                                        width: 0.9,
                                      ),
                                    ),
                                    child: Text(
                                      _periodText,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: isDark
                                            ? subjectTheme.darkBadgeText
                                            : subjectTheme.lightBadgeText,
                                        letterSpacing: 0.2,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(height: 3.5),
                                  // Subject name — responsive hero typography (never clips)
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      _subjectText,
                                      style: TextStyle(
                                        fontSize: 15.5,
                                        fontWeight: FontWeight.w800,
                                        color: isDark
                                            ? Colors.white
                                            : const Color(0xFF0F172A),
                                        letterSpacing: -0.3,
                                        height: 1.15,
                                      ),
                                      maxLines: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 4.0),
                                  // Visual Active Status Indicator + Period Timings on one line
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      _ActivePulseDot(
                                        pulseAnimation: _timerPulseAnimation,
                                      ),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          _timingText.isNotEmpty
                                              ? _timingText
                                              : '',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                            color: isDark
                                                ? const Color(0xFFCBD5E1)
                                                : const Color(0xFF64748B),
                                            letterSpacing: 0.15,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 10),

                            // ── RIGHT: Premium circular countdown ─────────────────────
                            _PremiumCircularCountdown(
                              secondsRemaining: _secondsRemaining,
                              timerColor: timerColor,
                              pulseAnimation: _timerPulseAnimation,
                              mm: mm,
                              ss: ss,
                              isDark: isDark,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }(),
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

// ─────────────────────────────────────────────────────────────────────────────
// Active Status Indicator — Subtle breathing pulse dot for active session
// ─────────────────────────────────────────────────────────────────────────────

class _ActivePulseDot extends StatelessWidget {
  final Animation<double> pulseAnimation;

  const _ActivePulseDot({required this.pulseAnimation});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseAnimation,
      builder: (context, child) {
        final double scale = pulseAnimation.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            // Outer translucent soft green breathing glow
            Container(
              width: 12.0 * scale,
              height: 12.0 * scale,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF22C55E).withValues(alpha: 0.22 * scale),
              ),
            ),
            // Inner solid green center dot
            Container(
              width: 6.0,
              height: 6.0,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF22C55E),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Premium Circular Countdown — UI-only helper widget
// Receives values from parent; owns no business logic.
// ─────────────────────────────────────────────────────────────────────────────

class _PremiumCircularCountdown extends StatelessWidget {
  final int secondsRemaining;
  final Color timerColor;
  final Animation<double> pulseAnimation;
  final String mm;
  final String ss;
  final bool isDark;

  const _PremiumCircularCountdown({
    required this.secondsRemaining,
    required this.timerColor,
    required this.pulseAnimation,
    required this.mm,
    required this.ss,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final bool isUrgent = secondsRemaining <= 60;

    // Ring arc color — vibrant indigo/violet in normal state; shifts to urgency color
    final Color ringColor = isUrgent
        ? timerColor
        : const Color(0xFF6366F1); // vibrant indigo

    // Text/icon color — crisp dark charcoal/navy for high contrast against the light ring
    // In urgency state both ring and text use timerColor for clear alarm signal
    final Color textColor = isUrgent
        ? timerColor
        : (isDark ? Colors.white : const Color(0xFF0F172A));

    // Track colour = very faint ring colour
    final Color trackColor = isDark
        ? ringColor.withValues(alpha: 0.14)
        : ringColor.withValues(alpha: 0.10);

    // Inner background
    final Color innerBg = isDark ? const Color(0xFF1E293B) : Colors.white;

    return ScaleTransition(
      scale: pulseAnimation,
      child: SizedBox(
        width: 56,
        height: 56,
        child: CustomPaint(
          painter: _CircularTimerPainter(
            progress: secondsRemaining / 180.0,
            ringColor: ringColor,
            trackColor: trackColor,
            innerBg: innerBg,
            isDark: isDark,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.timer_outlined, size: 9.0, color: textColor),
                const SizedBox(height: 1.0),
                Text(
                  '$mm:$ss',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: textColor,
                    letterSpacing: 0.2,
                    height: 1.0,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws the circular ring: faint background track + solid progress arc.
class _CircularTimerPainter extends CustomPainter {
  final double progress; // 0.0 – 1.0
  final Color ringColor;
  final Color trackColor;
  final Color innerBg;
  final bool isDark;

  const _CircularTimerPainter({
    required this.progress,
    required this.ringColor,
    required this.trackColor,
    required this.innerBg,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - 3.5;
    const strokeW = 2.8;

    // ── 1. Subtle drop-shadow for the ring ─────────────────────────────
    if (!isDark) {
      final shadowPaint = Paint()
        ..color = ringColor.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW + 2.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
      canvas.drawCircle(center, radius, shadowPaint);
    }

    // ── 2. Inner fill (clean white / dark surface) ──────────────────────
    final bgPaint = Paint()
      ..color = innerBg
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - strokeW / 2, bgPaint);

    // ── 3. Background track (full circle, muted) ────────────────────────
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    // ── 4. Progress arc (sweeps clockwise from 12 o'clock) ─────────────
    if (progress > 0) {
      final arcPaint = Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round;

      const startAngle = -math.pi / 2; // 12 o'clock
      final sweepAngle = 2 * math.pi * progress.clamp(0.0, 1.0);

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        arcPaint,
      );

      // ── 5. Accent dot at the sweep endpoint ────────────────────────
      final dotAngle = startAngle + sweepAngle;
      final dotX = center.dx + radius * math.cos(dotAngle);
      final dotY = center.dy + radius * math.sin(dotAngle);
      final dotPaint = Paint()
        ..color = ringColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(dotX, dotY), strokeW / 2 + 0.2, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CircularTimerPainter old) =>
      old.progress != progress ||
      old.ringColor != ringColor ||
      old.trackColor != trackColor ||
      old.innerBg != innerBg;
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

// ─────────────────────────────────────────────────────────────────────────────
// Subject Color Theme & Deterministic Color Hashing
// ─────────────────────────────────────────────────────────────────────────────

class _SubjectColorTheme {
  final Color primary;
  final Color lightBadgeBg;
  final Color lightBadgeText;
  final Color lightBadgeBorder;
  final Color darkBadgeBg;
  final Color darkBadgeText;
  final Color darkBadgeBorder;

  const _SubjectColorTheme({
    required this.primary,
    required this.lightBadgeBg,
    required this.lightBadgeText,
    required this.lightBadgeBorder,
    required this.darkBadgeBg,
    required this.darkBadgeText,
    required this.darkBadgeBorder,
  });
}

const List<_SubjectColorTheme> _kSubjectColorThemes = [
  // 0. Sky / Blue
  _SubjectColorTheme(
    primary: Color(0xFF0284C7),
    lightBadgeBg: Color(0xFFE0F2FE),
    lightBadgeText: Color(0xFF0369A1),
    lightBadgeBorder: Color(0xFFBAE6FD),
    darkBadgeBg: Color(0x330284C7),
    darkBadgeText: Color(0xFF7DD3FC),
    darkBadgeBorder: Color(0x4D38BDF8),
  ),
  // 1. Emerald / Green
  _SubjectColorTheme(
    primary: Color(0xFF059669),
    lightBadgeBg: Color(0xFFD1FAE5),
    lightBadgeText: Color(0xFF047857),
    lightBadgeBorder: Color(0xFFA7F3D0),
    darkBadgeBg: Color(0x33059669),
    darkBadgeText: Color(0xFF6EE7B7),
    darkBadgeBorder: Color(0x4D34D399),
  ),
  // 2. Amber / Warm Gold
  _SubjectColorTheme(
    primary: Color(0xFFD97706),
    lightBadgeBg: Color(0xFFFEF3C7),
    lightBadgeText: Color(0xFFB45309),
    lightBadgeBorder: Color(0xFFFDE68A),
    darkBadgeBg: Color(0x33D97706),
    darkBadgeText: Color(0xFFFCD34D),
    darkBadgeBorder: Color(0x4DFBBF24),
  ),
  // 3. Violet / Purple
  _SubjectColorTheme(
    primary: Color(0xFF7C3AED),
    lightBadgeBg: Color(0xFFEDE9FE),
    lightBadgeText: Color(0xFF6D28D9),
    lightBadgeBorder: Color(0xFFDDD6FE),
    darkBadgeBg: Color(0x337C3AED),
    darkBadgeText: Color(0xFFC4B5FD),
    darkBadgeBorder: Color(0x4DA78BFA),
  ),
  // 4. Rose / Crimson
  _SubjectColorTheme(
    primary: Color(0xFFE11D48),
    lightBadgeBg: Color(0xFFFFE4E6),
    lightBadgeText: Color(0xFFBE123C),
    lightBadgeBorder: Color(0xFFFECDD3),
    darkBadgeBg: Color(0x33E11D48),
    darkBadgeText: Color(0xFFFDA4AF),
    darkBadgeBorder: Color(0x4DFB7185),
  ),
  // 5. Indigo / Royal Blue
  _SubjectColorTheme(
    primary: Color(0xFF4F46E5),
    lightBadgeBg: Color(0xFFEEF2FF),
    lightBadgeText: Color(0xFF4338CA),
    lightBadgeBorder: Color(0xFFC7D2FE),
    darkBadgeBg: Color(0x334F46E5),
    darkBadgeText: Color(0xFFA5B4FC),
    darkBadgeBorder: Color(0x4D818CF8),
  ),
  // 6. Teal / Mint
  _SubjectColorTheme(
    primary: Color(0xFF0D9488),
    lightBadgeBg: Color(0xFFCCFBF1),
    lightBadgeText: Color(0xFF0F766E),
    lightBadgeBorder: Color(0xFF99F6E4),
    darkBadgeBg: Color(0x330D9488),
    darkBadgeText: Color(0xFF5EEAD4),
    darkBadgeBorder: Color(0x4D2DD4BF),
  ),
];

int _hashStringToNumber(String str) {
  if (str.isEmpty) return 0;
  int hash = 0;
  for (int i = 0; i < str.length; i++) {
    hash = (hash << 5) - hash + str.codeUnitAt(i);
    hash &= 0x7FFFFFFF;
  }
  return hash;
}

_SubjectColorTheme _getSubjectColorTheme(String subjectName) {
  final cleanName = subjectName.trim().toLowerCase();
  if (cleanName.isEmpty ||
      cleanName == 'loading...' ||
      cleanName == 'loading') {
    return _kSubjectColorThemes[0];
  }
  final index = _hashStringToNumber(cleanName) % _kSubjectColorThemes.length;
  return _kSubjectColorThemes[index];
}

