// lib/screens/attendance/qr_face_verify_screen.dart
//
// Face verification screen for QR attendance flow — captures 5 front frames after
// randomized liveness check, generates embeddings and compares against stored multi-template profile.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:facial_liveness_verification/facial_liveness_verification.dart'
    show ChallengeType;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/face_ml_service.dart';
import '../../services/face_landmark_service.dart';
import '../../utils/app_styles.dart';
import '../../utils/camera_stabilizer.dart';
import 'qr_scanner_screen.dart';

// ─── Verification phases ──────────────────────────────────────────────────────
enum _Phase {
  initializing,
  positioning, // face centering + steady check
  liveness, // blink/turn challenge
  capturing, // capturing 5 front frames
  processing, // running embeddings + comparing
  done,
  error,
}

class QrFaceVerifyScreen extends StatefulWidget {
  const QrFaceVerifyScreen({super.key});

  @override
  State<QrFaceVerifyScreen> createState() => _QrFaceVerifyScreenState();
}

class _QrFaceVerifyScreenState extends State<QrFaceVerifyScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // ─── Animation controllers ──────────────────────────────────────────────
  late AnimationController _pulseController;
  late AnimationController _textFadeController;
  late AnimationController _blinkCountdownController;
  late AnimationController _successBounceController;
  late AnimationController _particleController;

  // ─── Timer ring (Dedicated 60s face verification window) ──────────────────
  // Deliberately separate from the liveness challenge countdown timer.
  late AnimationController _timerPulseController;
  late Animation<double> _timerPulseAnim;
  late AnimationController _ringController;
  late Animation<double> _ringProgress;
  static const int _totalSeconds = 60;
  int _secondsRemaining = _totalSeconds;
  DateTime? _sessionDeadline;
  DateTime? _verificationDeadline;
  DateTime? _verificationStartedAt;
  bool _isRevalidatingSession = false;
  Timer? _countdownTimer;
  int _sessionSecondsRemaining = 0;

  int _calculateRemainingSeconds() {
    if (_verificationDeadline != null) {
      final diffMs = _verificationDeadline!
          .difference(DateTime.now())
          .inMilliseconds;
      final remaining = (diffMs / 1000.0).ceil();
      return math.max(0, remaining);
    }
    return _totalSeconds;
  }

  int _calculateSessionRemainingSeconds() {
    if (_sessionDeadline != null) {
      final diffMs = _sessionDeadline!
          .difference(DateTime.now().toUtc())
          .inMilliseconds;
      final remaining = (diffMs / 1000.0).ceil();
      return math.max(0, remaining);
    }
    return _sessionSecondsRemaining;
  }

  // ─── Camera ─────────────────────────────────────────────────────────────
  CameraController? _cameraController;
  bool _cameraInitialized = false;
  bool _cameraPreviewReady = false;
  int _cameraGeneration = 0;

  // ─── ML ─────────────────────────────────────────────────────────────────
  final FaceMlService _mlService = FaceMlService();
  final FaceLandmarkService _landmarkService = FaceLandmarkService();
  final LivenessChallengeService _livenessService = LivenessChallengeService();
  bool _isProcessingFrame = false;
  DateTime _lastFrameTime = DateTime.now();
  CameraImage? _lastCameraImage;
  DateTime _lastCaptureTime = DateTime.fromMillisecondsSinceEpoch(0);

  // ─── Verification state ─────────────────────────────────────────────────
  _Phase _phase = _Phase.initializing;

  final List<List<double>> _liveEmbeddings = [];
  final List<Uint8List> _capturedVerificationFrames = [];
  final List<Map<String, double>> _capturedVerificationFramesStats = [];
  final List<Map<String, double>> _allFramesStats = [];
  final List<BatchEmbeddingResult> _validResults = [];
  int _validFrameCount = 0;
  bool _cameraFrozen = false;
  Uint8List? _lastCapturedFrameBytes;
  bool _isSubmitting = false;
  late CameraStabilizer _cameraStabilizer;
  Face? _lastProcessedFace;
  int _nextCaptureInterval = 300;
  final Stopwatch _captureStopwatch = Stopwatch();
  final Stopwatch _apiStopwatch = Stopwatch();
  final Stopwatch _comparisonStopwatch = Stopwatch();
  final Stopwatch _totalStopwatch = Stopwatch();
  static const int _framesPerPhase = 5;

  bool _meteringApplied = false;
  int _stabilityRejectCount = 0;
  DateTime _lastExposureAdjustTime = DateTime.fromMillisecondsSinceEpoch(0);

  String _livenessPlan = 'blink_only';
  bool _blinkDone = false;
  bool _turnDone = false;
  DateTime? _turnStartTime;

  List<List<double>>? _storedTemplates;
  double _verificationThreshold = 0.68;

  int _attemptCount = 1;
  bool _isTerminal = false;

  // Instruction / UI state
  String _instructionTitle = 'Setting up camera…';
  String _instructionSubtitle = 'Please wait';
  Color _borderColor = AppStyles.primaryBlue;
  bool _challengeVerified = false;

  // ─── Challenge verification timeout ─────────────────────────────────────
  DateTime? _challengeStartTime;
  int _lastKnownBlinkCount = 0;
  int _captureProgress = 0;

  // ignore: unused_field
  String? _errorMessage;

  // ─── Session state (QR flow) ────────────────────────────────────
  String? _sessionId;
  String _subjectName = '';
  String _periodInfo = '';

  // ─── Face positioning state ─────────────────────────────────────────────
  DateTime? _steadyStartTime;
  bool _isFaceReady = false;
  Timer? _instructionDebounceTimer;

  // ── Flash effect ──
  bool _showFlash = false;

  // Layout info captured from LayoutBuilder
  double _uiCircleSize = 0;
  double _uiAvailW = 0;
  double _uiAvailH = 0;

  // ─── Smoothing buffer ─────────────────────────────────────────────────
  static const int _smoothingBufferSize = 5;
  final List<double> _bufFaceWidth = [];
  final List<double> _bufFaceHeight = [];
  final List<double> _bufFaceCX = [];
  final List<double> _bufFaceCY = [];
  final List<double> _bufYaw = [];
  final List<double> _bufPitch = [];

  // ─── Hysteresis state ─────────────────────────────────────────────────
  String? _lastPosInstruction;

  // ─── Instruction strings ──────────────────────────────────────────────
  final Map<String, String> _subtitles = {
    "Setting up camera…": "Please wait",
    "Fit your face in the circle": "Make sure your full face is visible",
    "Move closer to the camera":
        "Step a little closer so your face fills the circle",
    "Move slightly backward": "You are too close, step back a little",
    "Move to the center of the circle": "Center your face in the circle",
    "Hold still…": "Almost ready, stay steady",
    "Scanning your face silently": "Scanning your face silently",
    "Calibrating…": "Look straight at the camera and hold still",
    "Blink to verify": "Blink naturally to confirm you are present",
    "Blink 2-3 times": "Blink naturally 2 to 3 times",
    "Turn slightly left": "Turn your head slightly to the left",
    "Turn slightly right": "Turn your head slightly to the right",
    "Turn verified!": "Preparing capture…",
    "Too bright — move out of direct sunlight":
        "Reduce direct lighting on your face",
    "Too dark — improve the lighting on your face":
        "Face a light source or move to a brighter spot",
    "Processing…": "Comparing your face",
    "Verifying Identity": "Comparing your live face securely…",
    "Verified!": "Face matched successfully",
    "Verification Failed": "Face did not match",
    "Something went wrong": "Please try again",
  };

  // Camera release guard — prevents new screen from grabbing camera before old one releases
  static Future<void>? _cameraReleaseFuture;
  static int _cameraInitGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _verificationStartedAt ??= DateTime.now();
    _verificationDeadline ??= _verificationStartedAt!.add(
      const Duration(seconds: _totalSeconds),
    );

    // ── Animation setup ────────────────────────────────────────────────────
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _textFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..forward();

    // Liveness local challenge countdown controller
    _blinkCountdownController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );

    _successBounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _particleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    // 60-second screen session countdown ring timer
    _timerPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _timerPulseAnim = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _timerPulseController, curve: Curves.easeInOut),
    );

    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: _totalSeconds),
    );
    _ringProgress = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _ringController, curve: Curves.linear));

    // Ensure _sessionId is extracted before starting camera initialization
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        _sessionId = args['session_id'] as String?;
        final forwardedDeadline = args['deadline'] as DateTime?;
        if (forwardedDeadline != null) {
          _sessionDeadline = forwardedDeadline;
          _sessionSecondsRemaining = _calculateSessionRemainingSeconds();
          if (mounted) setState(() {});
        }
        final forwardedSubject = args['subject_name'] as String?;
        final forwardedPeriod = args['period_info'] as String?;
        if (forwardedSubject != null &&
            forwardedSubject.isNotEmpty &&
            forwardedPeriod != null &&
            forwardedPeriod.isNotEmpty) {
          // Data already known from the QR scanner — render immediately,
          // no network round trip needed before the screen is usable.
          String cleanPeriod = forwardedPeriod;
          final timeRangeRegex = RegExp(
            r'\s+\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}',
          );
          cleanPeriod = cleanPeriod.replaceAll(timeRangeRegex, '').trim();
          setState(() {
            _subjectName = forwardedSubject;
            _periodInfo = cleanPeriod;
          });
        } else {
          // Fallback only if not forwarded — e.g. deep link or old nav path
          await _fetchSessionInfo();
        }
      }
      await _initializeCamera();
    });
  }

  // ─── Fetch session info (QR flow) ──────────────────────────────────────
  Future<void> _fetchSessionInfo() async {
    if (_sessionId == null) return;
    try {
      final data = await Supabase.instance.client
          .from('attendance_sessions')
          .select('''
            subject_id,
            period_id,
            status,
            opened_at,
            subjects ( name ),
            periods ( period_number )
          ''')
          .eq('id', _sessionId!)
          .maybeSingle();

      if (data != null && mounted) {
        final status = data['status'] as String?;
        final openedAtStr = data['opened_at'] as String?;
        if (openedAtStr != null && _sessionDeadline == null) {
          try {
            final openedAt = DateTime.parse(openedAtStr).toUtc();
            _sessionDeadline = openedAt.add(const Duration(seconds: 180));
            _sessionSecondsRemaining = _calculateSessionRemainingSeconds();
          } catch (_) {}
        }
        if (status != null && status != 'active') {
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            'Teacher session is not active: $status',
          );
          _navigateToTimeout(isTimeout: true);
          return;
        }

        final subjectData = data['subjects'] as Map<String, dynamic>?;
        final periodData = data['periods'] as Map<String, dynamic>?;

        final subjectName = subjectData?['name'] as String? ?? 'Class';
        final periodNum = periodData?['period_number'] as int? ?? 1;

        final suffix = _ordinalSuffix(periodNum);

        setState(() {
          _subjectName = subjectName;
          _periodInfo = '$periodNum$suffix Period';
        });
      }
    } catch (e) {
      debugPrint('[QR_FACE_VER] Failed to fetch session info: $e');
    }
  }

  Future<bool> _isSessionActive() async {
    if (_sessionId == null) return false;
    try {
      final data = await Supabase.instance.client
          .from('attendance_sessions')
          .select('status')
          .eq('id', _sessionId!)
          .maybeSingle();
      if (data != null) {
        final status = data['status'] as String?;
        return status == 'active';
      }
    } catch (e) {
      debugPrint('[QR_FACE_VER] Error checking session status: $e');
    }
    return false;
  }

  void _navigateToTimeout({required bool isTimeout}) {
    if (_isTerminal || !mounted) return;
    _isTerminal = true;
    _countdownTimer?.cancel();
    _instructionDebounceTimer?.cancel();
    try {
      _cameraController?.stopImageStream();
    } catch (_) {}
    Navigator.of(
      context,
    ).pushReplacementNamed('/qr-timeout', arguments: isTimeout);
  }

  void _navigateToSuccess() {
    if (_isTerminal || !mounted) return;
    _isTerminal = true;
    _countdownTimer?.cancel();
    _instructionDebounceTimer?.cancel();
    try {
      _cameraController?.stopImageStream();
    } catch (_) {}
    Navigator.of(context).pushReplacementNamed(
      '/qr-success',
      arguments: {
        'session_id': _sessionId,
        'subject_name': _subjectName,
        'period_info': _periodInfo,
      },
    );
  }

  String _ordinalSuffix(int n) {
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

  // ─────────────────────────────────────────────────────────────────────────
  // CAMERA INITIALIZATION
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _initializeCamera() async {
    debugPrint(
      '[CAM_INIT] _initializeCamera called — waiting for any pending release',
    );

    // Wait for any previous camera to fully release before initializing
    if (_cameraReleaseFuture != null) {
      debugPrint('[CAM_INIT] Previous release in progress — awaiting...');
      await _cameraReleaseFuture;
      debugPrint('[CAM_INIT] Previous release complete');
    }

    final scannerFuture = qrScannerReleaseCompleter?.future;
    if (scannerFuture != null) {
      debugPrint('[CAM_INIT] Waiting for QR scanner camera release...');
      await scannerFuture;
      debugPrint('[CAM_INIT] QR scanner camera released');
    }
    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) {
      debugPrint('[CAM_INIT] Not mounted after waiting for release — aborting');
      return;
    }

    try {
      debugPrint('[CAM_INIT] Getting available cameras');
      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      debugPrint('[CAM_INIT] Front camera found: ${frontCamera.name}');

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      debugPrint('[CAM_INIT] Initializing CameraController');
      await _cameraController!.initialize();
      debugPrint('[CAM_INIT] CameraController initialized');

      _cameraStabilizer = CameraStabilizer(
        controller: _cameraController!,
        sessionId: _sessionId ?? 'QR_VER',
        logPrefix: 'FACE_VER',
      );
      await _cameraStabilizer.stabilize();

      // Increment generation so CameraPreview gets a new key and fully rebuilds
      _cameraInitGeneration++;

      try {
        final minZoom = await _cameraController!.getMinZoomLevel();
        await _cameraController!.setZoomLevel(minZoom);
        debugPrint('[CAM_INIT] Zoom set to minimum: $minZoom');
      } catch (e) {
        debugPrint('[CAM_INIT] Zoom not supported: $e');
      }

      if (!mounted) {
        debugPrint(
          '[CAM_INIT] Not mounted after initialize — disposing and aborting',
        );
        await _cameraController!.dispose();
        _cameraController = null;
        return;
      }

      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;

      setState(() {
        _cameraInitialized = true;
        _cameraGeneration = _cameraInitGeneration;
      });
      debugPrint(
        '[CAM_INIT] _cameraInitialized = true, generation=$_cameraGeneration (static=$_cameraInitGeneration), building preview',
      );

      await _landmarkService.initialize();
      debugPrint('[CAM_INIT] ML landmark service initialized');

      await _loadEmbeddings();
      if (_storedTemplates == null || _storedTemplates!.isEmpty) {
        debugPrint('[CAM_INIT] Embeddings missing — aborting');
        return;
      }
      debugPrint('[CAM_INIT] Embeddings loaded');

      await _cameraController!.startImageStream(_onCameraFrame);
      debugPrint('[CAM_INIT] Image stream started');

      _livenessService.logPrefix = 'FACE_VER';
      _livenessService.sessionId = _sessionId ?? 'QR_VER';

      final double rPlan = math.Random().nextDouble();
      if (rPlan < 0.40) {
        _livenessPlan = 'blink_only';
      } else if (rPlan < 0.70) {
        _livenessPlan = 'blink_left';
      } else {
        _livenessPlan = 'blink_right';
      }
      _blinkDone = false;
      _turnDone = false;
      _turnStartTime = null;
      _meteringApplied = false;
      _stabilityRejectCount = 0;
      debugPrint('[FACE_VER] Selected liveness plan: $_livenessPlan');

      _setPhase(_Phase.positioning);

      if (!mounted) return;
      // On second+ attempts Android surface texture needs extra time to bind
      final int bindDelay = _cameraInitGeneration > 1 ? 1000 : 200;
      debugPrint(
        '[CAM_INIT] Waiting ${bindDelay}ms for surface texture bind (generation=$_cameraInitGeneration)',
      );
      await Future.delayed(Duration(milliseconds: bindDelay));
      if (!mounted) return;
      setState(() => _cameraPreviewReady = true);
      debugPrint('[CAM_INIT] Camera preview ready');

      _ringController.forward();
      _startCountdownTimer();
    } catch (e) {
      debugPrint('[CAM_INIT] ERROR: $e');
      _setError('Camera failed to start: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LOAD EMBEDDINGS — cache-first from SharedPreferences, fallback Supabase
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _loadEmbeddings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedStudentId = prefs.getString('emb_student_id');
      final cachedAt = prefs.getInt('emb_cached_at') ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final isExpired = (now - cachedAt) > (24 * 60 * 60 * 1000);
      final user = Supabase.instance.client.auth.currentUser;

      if (user != null &&
          cachedStudentId == user.id &&
          !isExpired &&
          cachedStudentId != null) {
        final cachedTemplatesJson = prefs.getString('emb_stored_templates');
        final String? thresholdStr = prefs.getString(
          'emb_threshold_${user.id}',
        );
        if (cachedTemplatesJson != null) {
          final List<dynamic> decoded = jsonDecode(cachedTemplatesJson);
          _storedTemplates = decoded
              .map(
                (item) =>
                    (item as List).map((e) => (e as num).toDouble()).toList(),
              )
              .toList();
          _verificationThreshold = thresholdStr != null
              ? double.tryParse(thresholdStr) ?? 0.68
              : 0.68;
          _verificationThreshold = math.min(_verificationThreshold, 0.62);
          debugPrint(
            '[FACE_VER] Threshold loaded from cache: $_verificationThreshold',
          );
          debugPrint(
            '[FACE_VER] Stored templates loaded from cache: ${_storedTemplates?.length} vector(s)',
          );
          return;
        }
      }

      // Cache miss — fetch from Supabase
      if (user == null) {
        _setError('Could not load face profile. Please try again.');
        return;
      }

      final data = await Supabase.instance.client
          .from('students')
          .select(
            'embedding_a, embedding_b, embedding_c, embedding_up, embedding_down, face_embedding, verification_threshold',
          )
          .eq('id', user.id)
          .maybeSingle();

      if (data == null) {
        _setError('Could not load face profile. Please try again.');
        return;
      }

      final List<List<double>> templatesList = [];

      void addIfValid(dynamic rawVal) {
        if (rawVal != null && rawVal is List && rawVal.isNotEmpty) {
          templatesList.add(rawVal.map((e) => (e as num).toDouble()).toList());
        }
      }

      addIfValid(data['embedding_a']);
      addIfValid(data['embedding_b']);
      addIfValid(data['embedding_c']);
      addIfValid(data['embedding_up']);
      addIfValid(data['embedding_down']);

      // Fallback to face_embedding if no pose templates exist
      if (templatesList.isEmpty && data['face_embedding'] != null) {
        final rawList = data['face_embedding'] as List;
        if (rawList.isNotEmpty && rawList[0] is List) {
          for (final item in rawList) {
            templatesList.add(
              (item as List).map((e) => (e as num).toDouble()).toList(),
            );
          }
        } else if (rawList.isNotEmpty) {
          templatesList.add(rawList.map((e) => (e as num).toDouble()).toList());
        }
      }

      if (templatesList.isEmpty) {
        _setError('Could not load face profile. Please try again.');
        return;
      }

      _storedTemplates = templatesList;
      _verificationThreshold =
          (data['verification_threshold'] as num?)?.toDouble() ?? 0.68;
      _verificationThreshold = math.min(_verificationThreshold, 0.62);
      debugPrint(
        '[FACE_VER] Threshold loaded from Supabase: $_verificationThreshold',
      );
      debugPrint(
        '[FACE_VER] Stored templates loaded from Supabase: ${_storedTemplates?.length} vector(s)',
      );

      // Clear any previous user's cached embeddings first
      await prefs.remove('emb_a');
      await prefs.remove('emb_b');
      await prefs.remove('emb_c');
      await prefs.remove('emb_master');
      await prefs.remove('emb_stored_templates');
      await prefs.remove('emb_student_id');
      await prefs.remove('emb_cached_at');

      if (_storedTemplates != null) {
        await prefs.setString(
          'emb_stored_templates',
          jsonEncode(_storedTemplates),
        );
      }
      await prefs.setString(
        'emb_threshold_${user.id}',
        _verificationThreshold.toString(),
      );
      await prefs.setString('emb_student_id', user.id);
      await prefs.setInt('emb_cached_at', now);
      debugPrint('[FACE_VER] Stored templates loaded from Supabase and cached');
    } catch (e) {
      _setError('Could not load face profile. Please try again.');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CAMERA FRAME PROCESSING — rate-limited to 10fps
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _onCameraFrame(CameraImage cameraImage) async {
    if (!_cameraStabilizer.isStable) return;
    _lastCameraImage = cameraImage;

    final now = DateTime.now();
    final bool isBlinkPhase =
        _phase == _Phase.liveness && !_challengeVerified && _isFaceReady;
    if (!isBlinkPhase) {
      final int limit = (_phase == _Phase.liveness && !_challengeVerified)
          ? 33
          : 100;
      if (now.difference(_lastFrameTime).inMilliseconds < limit) return;
    }
    if (_isProcessingFrame) return;
    if (!mounted) return;

    if (_phase == _Phase.initializing ||
        _phase == _Phase.processing ||
        _phase == _Phase.done ||
        _phase == _Phase.error) {
      return;
    }

    _lastFrameTime = now;
    _isProcessingFrame = true;

    try {
      debugPrint(
        '[QR_FACE][FRAME] frame received | isStable=${_cameraStabilizer.isStable} phase=$_phase isFaceReady=$_isFaceReady',
      );
      final InputImage? inputImage = _convertToInputImage(cameraImage);
      if (inputImage == null) {
        _isProcessingFrame = false;
        return;
      }

      final List<Face> faces = await _mlService.faceDetector.processImage(
        inputImage,
      );
      debugPrint('[QR_FACE][FRAME] ${faces.length} face(s) detected');

      if (!mounted) {
        _isProcessingFrame = false;
        return;
      }

      if (faces.isEmpty) {
        if ((_phase == _Phase.positioning || _phase == _Phase.liveness) &&
            !_challengeVerified) {
          _clearSmoothing();
          _steadyStartTime = null;
          if (_isFaceReady) {
            _isFaceReady = false;
            _livenessService.resetCalibration();
            _challengeStartTime = null;
            _turnStartTime = null;
            _blinkDone = false;
            _turnDone = false;
            _blinkCountdownController.stop();
            _blinkCountdownController.reset();
          }
          _updateInstruction('Fit your face in the circle', animate: false);
        }
        _isProcessingFrame = false;
        return;
      }

      final Face? face = _selectBiggestCenteredFace(faces, cameraImage);
      if (face == null) {
        _updateInstruction('Fit your face in the circle', animate: false);
        _isProcessingFrame = false;
        return;
      }

      // Same-face tracking continuity
      if (_lastProcessedFace != null) {
        bool isSame = false;
        if (face.trackingId != null && _lastProcessedFace!.trackingId != null) {
          isSame = face.trackingId == _lastProcessedFace!.trackingId;
          if (!isSame) {
            debugPrint(
              '[FACE_CAMERA] [FACE_VER][${_sessionId ?? 'QR_VER'}] Face tracking ID changed: ${_lastProcessedFace!.trackingId} -> ${face.trackingId}',
            );
          }
        } else {
          final double iou = _calculateIoU(
            face.boundingBox,
            _lastProcessedFace!.boundingBox,
          );
          isSame = iou >= 0.5;
          if (!isSame) {
            debugPrint(
              '[FACE_CAMERA] [FACE_VER][${_sessionId ?? 'QR_VER'}] Face tracking lost via IoU (IoU: ${iou.toStringAsFixed(2)})',
            );
          }
        }
        if (!isSame) {
          debugPrint(
            '[FACE_CAMERA] [FACE_VER][${_sessionId ?? 'QR_VER'}] Face tracking lost — resetting captured frames and buffer',
          );
          _clearSmoothing();
          _capturedVerificationFrames.clear();
          _capturedVerificationFramesStats.clear();
          _allFramesStats.clear();
          _validResults.clear();
          _validFrameCount = 0;
          _captureProgress = 0;
          _steadyStartTime = null;
          _isFaceReady = false;
          _livenessService.resetCalibration();
          _challengeStartTime = null;
          _turnStartTime = null;
          _blinkDone = false;
          _turnDone = false;
          _blinkCountdownController.stop();
          _blinkCountdownController.reset();
        }
      }
      _lastProcessedFace = face;

      _pushSmoothing(face);

      if (!_meteringApplied) {
        final String? posInstructionCheck = _getPositioningInstruction(
          face,
          cameraImage,
          strict: !_isFaceReady,
        );
        if (posInstructionCheck == null) {
          final int sensorOrientation =
              _cameraController?.description.sensorOrientation ?? 90;
          double rawCX;
          double rawCY;

          if (sensorOrientation == 90) {
            rawCX = face.boundingBox.top + face.boundingBox.height / 2.0;
            rawCY =
                cameraImage.height -
                (face.boundingBox.left + face.boundingBox.width / 2.0);
          } else if (sensorOrientation == 270) {
            rawCX =
                cameraImage.width -
                (face.boundingBox.top + face.boundingBox.height / 2.0);
            rawCY = face.boundingBox.left + face.boundingBox.width / 2.0;
          } else if (sensorOrientation == 180) {
            rawCX =
                cameraImage.width -
                (face.boundingBox.left + face.boundingBox.width / 2.0);
            rawCY =
                cameraImage.height -
                (face.boundingBox.top + face.boundingBox.height / 2.0);
          } else {
            rawCX = face.boundingBox.left + face.boundingBox.width / 2.0;
            rawCY = face.boundingBox.top + face.boundingBox.height / 2.0;
          }

          final double normX = (rawCX / cameraImage.width).clamp(0.0, 1.0);
          final double normY = (rawCY / cameraImage.height).clamp(0.0, 1.0);

          _cameraStabilizer.applyFaceMetering(normX, normY);
          _meteringApplied = true;
        }
      }

      // Adapt camera exposure to face region (throttled to 1000ms)
      final frameStats = _cameraStabilizer.computeFrameStats(
        cameraImage,
        faceBoundingBox: face.boundingBox,
        sensorOrientation: _cameraController!.description.sensorOrientation,
      );
      final double faceBrightness = frameStats['brightness'] ?? 0.0;
      final nowAdjust = DateTime.now();
      if (nowAdjust.difference(_lastExposureAdjustTime).inMilliseconds >=
          1000) {
        _lastExposureAdjustTime = nowAdjust;
        _cameraStabilizer.adjustFaceExposure(faceBrightness);
      }

      // ── Positioning gate (positioning + liveness before challenge verified) ──
      if ((_phase == _Phase.positioning || _phase == _Phase.liveness) &&
          !_challengeVerified) {
        final bool strict = !_isFaceReady;
        final String? posInstruction = _getPositioningInstruction(
          face,
          cameraImage,
          strict: strict,
        );
        debugPrint(
          '[QR_FACE][POSITION] positioning result: ${posInstruction ?? "CENTERED"} | strict: $strict',
        );

        if (posInstruction != null) {
          if (_isFaceReady) {
            _isFaceReady = false;
            _livenessService.resetCalibration();
            _challengeStartTime = null;
            _turnStartTime = null;
            _blinkDone = false;
            _turnDone = false;
            _blinkCountdownController.stop();
            _blinkCountdownController.reset();
          }
          _steadyStartTime = null;
          _updateInstruction(posInstruction, animate: false);
          _isProcessingFrame = false;
          return;
        }

        // Face is centered — track steadiness
        _steadyStartTime ??= DateTime.now();
        final int steadyMs = DateTime.now()
            .difference(_steadyStartTime!)
            .inMilliseconds;

        if (!_isFaceReady) {
          if (steadyMs < 800) {
            _updateInstruction(
              'Hold still…',
              subtitle: 'Almost ready, stay steady',
              animate: false,
            );
            _isProcessingFrame = false;
            return;
          }
          _isFaceReady = true;
          _livenessService.reset();

          // If still in positioning, transition to liveness
          if (_phase == _Phase.positioning) {
            _setPhase(_Phase.liveness);
          }

          _updateInstruction(
            'Calibrating…',
            subtitle: 'Look straight at the camera and hold still',
            animate: false,
          );
        }
      }

      // Route to correct phase handler
      switch (_phase) {
        case _Phase.liveness:
          if (!_challengeVerified) {
            await _handleLivenessChallenge(face, ChallengeType.blink);
          } else {
            // Liveness verified — transition to capturing with reduced delay (120ms)
            await Future.delayed(const Duration(milliseconds: 120));
            if (mounted) _setPhase(_Phase.capturing);
          }
          break;
        case _Phase.capturing:
          await _handleCapture(face, cameraImage);
          break;
        default:
          break;
      }
    } catch (e) {
      // Swallow frame errors silently
    } finally {
      _isProcessingFrame = false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LIVENESS CHALLENGE HANDLER
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _handleLivenessChallenge(
    Face face,
    ChallengeType challenge,
  ) async {
    debugPrint(
      '[QR_FACE][LIVENESS] challenge state: plan=$_livenessPlan blinkDone=$_blinkDone turnDone=$_turnDone verified=$_challengeVerified',
    );
    // ── Turn Challenge Branch ──
    if (_livenessPlan != 'blink_only' && _blinkDone && !_turnDone) {
      _turnStartTime ??= DateTime.now();
      final int elapsed = DateTime.now()
          .difference(_turnStartTime!)
          .inMilliseconds;
      const int turnTimeout = 3800; // Adjusted turn timeout: 3800ms

      final bool isLeft = _livenessPlan == 'blink_left';
      final String turnInstruction = isLeft
          ? 'Turn slightly left'
          : 'Turn slightly right';

      if (elapsed > turnTimeout) {
        _livenessService.reset();
        _turnStartTime = DateTime.now();
        _updateInstruction(
          'No turn detected',
          subtitle: 'Hold still while we confirm',
          animate: false,
        );
        await Future.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;
        _updateInstruction(
          turnInstruction,
          subtitle: 'Hold still while we confirm',
          animate: false,
        );
        return;
      }

      final bool turnDetected = isLeft
          ? _livenessService.detectTurnLeft(face)
          : _livenessService.detectTurnRight(face);

      if (turnDetected) {
        FaceLogger.ver(_sessionId ?? 'QR_VER', 'Turn challenge VERIFIED ✓');
        _turnDone = true;
        _challengeVerified = true;
        _livenessService.reset();
        _turnStartTime = null;

        _captureStopwatch.start();

        if (mounted) {
          setState(() {
            _borderColor = AppStyles.successGreen;
          });
          HapticFeedback.lightImpact();
        }
        _updateInstruction(
          'Turn verified!',
          subtitle: 'Preparing capture…',
          animate: false,
        );
      }
      return;
    }

    // ── Blink Challenge Branch ──
    _challengeStartTime ??= DateTime.now();

    final int elapsed = DateTime.now()
        .difference(_challengeStartTime!)
        .inMilliseconds;

    const int timeout = 3000;

    if (elapsed > timeout) {
      _livenessService.reset();
      _challengeStartTime = DateTime.now();

      if (challenge == ChallengeType.blink) {
        _blinkCountdownController.stop();
      }

      _updateInstruction(
        'No blink detected',
        subtitle: 'Blink naturally 2 to 3 times to confirm presence',
        animate: false,
      );

      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      if (challenge == ChallengeType.blink) {
        _blinkCountdownController.duration = const Duration(milliseconds: 3000);
        _blinkCountdownController.reset();
        _blinkCountdownController.forward(from: 0.0);
      }
      _updateInstruction(
        _getChallengeInstruction(challenge),
        subtitle: 'Blink naturally 2 to 3 times to confirm presence',
        animate: false,
      );
      return;
    }

    // Calibration before detecting
    if (challenge == ChallengeType.blink &&
        !_livenessService.isBlinkCalibrated) {
      final bool calibDone = _livenessService.calibrateBlink(face);
      if (!calibDone) {
        return;
      }
      _challengeStartTime = DateTime.now();
      _lastKnownBlinkCount = 0;
      // Explicitly set 3000ms duration for blink countdown
      _blinkCountdownController.duration = const Duration(milliseconds: 3000);
      _blinkCountdownController.reset();
      _blinkCountdownController.forward();
      _updateInstruction(
        'Blink 2-3 times',
        subtitle: 'Blink naturally 2 to 3 times',
        animate: false,
      );
      return;
    }

    // Try to detect the challenge
    bool detected = false;
    switch (challenge) {
      case ChallengeType.blink:
        detected = _livenessService.detectBlink(face);
        final int currentBlinkCount = _livenessService.blinkCount;
        if (!detected && currentBlinkCount > _lastKnownBlinkCount) {
          _lastKnownBlinkCount = currentBlinkCount;
          if (mounted) {
            setState(() => _borderColor = AppStyles.successGreen);
          }
          await Future.delayed(const Duration(milliseconds: 250));
          if (mounted && !_challengeVerified && !_blinkDone) {
            setState(() => _borderColor = AppStyles.primaryBlue);
          }
        }
        break;
      default:
        break;
    }

    if (detected) {
      FaceLogger.ver(_sessionId ?? 'QR_VER', 'Blink challenge VERIFIED ✓');
      _blinkDone = true;
      _challengeStartTime = null;
      _blinkCountdownController.stop();

      if (_livenessPlan == 'blink_only') {
        _challengeVerified = true;
        _livenessService.reset();
        _captureStopwatch.start();

        if (mounted) {
          setState(() {
            _borderColor = AppStyles.successGreen;
          });
          HapticFeedback.lightImpact();
        }
        _updateInstruction(
          'Blink verified!',
          subtitle: 'Preparing capture…',
          animate: false,
        );
      } else {
        _livenessService.reset();
        if (mounted) {
          setState(() {
            _borderColor = AppStyles.successGreen;
          });
          HapticFeedback.lightImpact();
        }
        final String turnInstruction = _livenessPlan == 'blink_left'
            ? 'Turn slightly left'
            : 'Turn slightly right';
        _updateInstruction(
          turnInstruction,
          subtitle: 'Hold still while we confirm',
          animate: false,
        );
        _turnStartTime = DateTime.now();
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && !_challengeVerified) {
            setState(() => _borderColor = AppStyles.primaryBlue);
          }
        });
      }
    }
  }

  String _getChallengeInstruction(ChallengeType challenge) {
    switch (challenge) {
      case ChallengeType.blink:
        return 'Blink to verify';
      default:
        return 'Hold still…';
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CAPTURE HANDLER — front-only, 5 frames
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _handleCapture(Face face, CameraImage cameraImage) async {
    if (_cameraFrozen) return;

    final now = DateTime.now();
    if (now.difference(_lastCaptureTime).inMilliseconds <
        _nextCaptureInterval) {
      return;
    }

    // Check yaw for front pose (±15°)
    final double? yawRaw = face.headEulerAngleY;
    if (yawRaw == null) return;
    final double yaw = -yawRaw;
    if (yaw.abs() > 15) {
      _updateInstruction('Look straight ahead', animate: false);
      return;
    }

    if (!_isFaceAcceptable(face, cameraImage)) {
      _isProcessingFrame = false;
      return;
    }

    // Compute stats for face region
    final stats = _cameraStabilizer.computeFrameStats(
      cameraImage,
      faceBoundingBox: face.boundingBox,
      sensorOrientation: _cameraController!.description.sensorOrientation,
    );
    final double faceBrightness = stats['brightness'] ?? 0.0;

    if (faceBrightness > 245.0) {
      _updateInstruction(
        'Too bright — move out of direct sunlight',
        subtitle: 'Reduce direct lighting on your face',
        animate: false,
      );
      _isProcessingFrame = false;
      return;
    }
    if (faceBrightness < 40.0) {
      _updateInstruction(
        'Too dark — improve the lighting on your face',
        subtitle: 'Face a light source or move to a brighter spot',
        animate: false,
      );
      _isProcessingFrame = false;
      return;
    }

    // Stable frame selection check with anti-stuck override
    if (!_cameraStabilizer.checkFrameStability(cameraImage, threshold: 35.0)) {
      _stabilityRejectCount++;
      if (_stabilityRejectCount < 8) {
        _isProcessingFrame = false;
        return;
      }
      _stabilityRejectCount = 0;
      debugPrint(
        '[FACE_VER] Force-bypassing frame stability check after 8 consecutive rejections',
      );
    }

    // Grab frame
    final Uint8List? jpegBytes = await _captureCurrentFrame();
    if (jpegBytes == null) return;

    _stabilityRejectCount = 0;

    _lastCapturedFrameBytes = jpegBytes; // Store for freeze preview

    debugPrint('[FACE_VER] CAPTURE frame accepted | size=${jpegBytes.length}b');

    _capturedVerificationFrames.add(jpegBytes);
    stats['yaw'] = face.headEulerAngleY ?? 0.0;
    stats['pitch'] = face.headEulerAngleX ?? 0.0;
    stats['roll'] = face.headEulerAngleZ ?? 0.0;
    _capturedVerificationFramesStats.add(stats);
    _allFramesStats.add(stats);

    setState(() {
      _captureProgress = _validFrameCount + _capturedVerificationFrames.length;
      _borderColor = AppStyles.successGreen;
    });
    HapticFeedback.lightImpact();

    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted && _phase == _Phase.capturing) {
        setState(() => _borderColor = AppStyles.primaryBlue);
      }
    });

    _lastCaptureTime = DateTime.now();
    _nextCaptureInterval = 250 + math.Random().nextInt(100);

    // Check if the target valid count is reached in the current batch
    final int needed = _framesPerPhase - _validFrameCount;
    if (_capturedVerificationFrames.length >= needed) {
      _captureStopwatch.stop();

      FaceLogger.ver(
        _sessionId ?? 'QR_VER',
        'Stopped | totalCaptured=${_capturedVerificationFrames.length} validCount=$_validFrameCount',
      );
      try {
        await _cameraController?.stopImageStream();
      } catch (_) {}

      // Cancel countdown timer
      _countdownTimer?.cancel();

      setState(() {
        _cameraFrozen = true;
        _isProcessingFrame = true; // Ignore future frames
      });

      _setPhase(_Phase.processing);
      await Future.delayed(const Duration(milliseconds: 50));
      await _processAndVerify();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PROCESS AND VERIFY
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _processAndVerify() async {
    if (!mounted) return;
    if (_isSubmitting) return;

    _totalStopwatch.start();

    setState(() {
      _isSubmitting = true;
    });

    try {
      FaceLogger.ver(_sessionId ?? 'QR_VER', 'Processing Started');

      _liveEmbeddings.clear();
      _validResults.clear();
      const List<String> poseNames = ['left', 'front', 'right', 'up', 'down'];
      int framesAboveThresholdCount = 0;
      double overallBestFrameScore = 0.0;
      int processedNonNullCount = 0;

      _apiStopwatch.start();
      final List<BatchEmbeddingResult> batchResults = await _landmarkService
          .generateEmbeddingBatch(
            jpegBytesList: _capturedVerificationFrames,
            localStatsList: _capturedVerificationFramesStats,
            sessionId: _sessionId,
            prefix: 'FACE_VER',
            storedTemplates: _storedTemplates,
            threshold: _verificationThreshold,
          );
      _apiStopwatch.stop();

      final bool livenessPassed = batchResults.isNotEmpty
          ? batchResults.first.livenessPassed
          : true;
      final bool apiFailed =
          batchResults.isNotEmpty && batchResults.first.apiFailed;

      if (apiFailed) {
        FaceLogger.ver(_sessionId ?? 'QR_VER', 'API FAILED');
        setState(() {
          _isSubmitting = false;
        });
        _updateInstruction(
          'Connection failed',
          subtitle:
              'Unable to connect to the face server. Please check your connection and try again.',
          animate: false,
        );
        return;
      }

      bool spoofDetected = false;

      for (int i = 0; i < batchResults.length; i++) {
        final res = batchResults[i];

        // 🔴 CRITICAL: Check Anti-Spoofing result from backend
        if (!res.livenessPassed) {
          spoofDetected = true;
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            '🚨 SPOOF DETECTED on Frame #${i + 1} by backend!',
          );
        }

        // Only accept if embedding exists, quality is good, AND it's a real face
        final bool accepted =
            res.embedding != null && res.qualityPassed && res.livenessPassed;

        if (accepted) {
          processedNonNullCount++;
          _liveEmbeddings.add(res.embedding!);
          _validResults.add(res);

          double frameMaxScore = -1.0;
          String bestPose = 'unknown';

          if (_storedTemplates != null && _storedTemplates!.isNotEmpty) {
            for (int t = 0; t < _storedTemplates!.length; t++) {
              final storedVec = _storedTemplates![t];
              final double sim = _landmarkService.cosineSimilarity(
                res.embedding!,
                storedVec,
              );
              if (sim > frameMaxScore) {
                frameMaxScore = sim;
                bestPose = t < poseNames.length ? poseNames[t] : 'pose_$t';
              }
            }
          }

          if (frameMaxScore >= _verificationThreshold) {
            framesAboveThresholdCount++;
          }
          if (frameMaxScore > overallBestFrameScore) {
            overallBestFrameScore = frameMaxScore;
          }

          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            'Frame #${i + 1}: maxScore=${frameMaxScore.toStringAsFixed(4)} ($bestPose)',
          );

          if (framesAboveThresholdCount >= 2) {
            FaceLogger.ver(
              _sessionId ?? 'QR_VER',
              'Early exit triggered: 2 frames above threshold reached at frame #${i + 1}',
            );
            break;
          }
        } else {
          debugPrint('[FACE_VER] Frame rejected by backend.');
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            'Frame #${i + 1}: backend quality reject (${res.rejectionReason ?? "null"})',
          );
        }
      }

      // 🚨 Handle Spoofing Attempt (Gated by _attemptCount < 2)
      if (spoofDetected) {
        FaceLogger.ver(
          _sessionId ?? 'QR_VER',
          'Verification aborted due to Anti-Spoofing failure.',
        );
        setState(() => _borderColor = AppStyles.errorRed);
        _updateInstruction(
          'Liveness check failed',
          subtitle: 'Please present a real face',
        );

        if (_attemptCount < 2) {
          await Future.delayed(const Duration(seconds: 2));
          if (!mounted || _isTerminal || _secondsRemaining <= 0) return;

          final bool sessionActive = await _isSessionActive();
          if (!sessionActive) {
            FaceLogger.ver(
              _sessionId ?? 'QR_VER',
              'Teacher session expired during spoof retry delay',
            );
            _navigateToTimeout(isTimeout: true);
            return;
          }

          if (!mounted || _isTerminal || _secondsRemaining <= 0) return;
          await _onRetry();
          return;
        } else {
          await Future.delayed(const Duration(milliseconds: 600));
          if (mounted && !_isTerminal) {
            _navigateToTimeout(isTimeout: false);
          }
          return;
        }
      }

      FaceLogger.ver(_sessionId ?? 'QR_VER', 'Processing Finished');

      _validFrameCount = processedNonNullCount;
      FaceLogger.ver(
        _sessionId ?? 'QR_VER',
        'Valid Count: $_validFrameCount/$_framesPerPhase',
      );

      if (_validFrameCount < 3 && framesAboveThresholdCount < 2) {
        FaceLogger.ver(
          _sessionId ?? 'QR_VER',
          'Backend rejected frames due to quality. Handling failure/retry.',
        );
        if (_attemptCount < 2) {
          setState(() => _borderColor = AppStyles.errorRed);
          _updateInstruction(
            'Verification Failed',
            subtitle: 'Image quality was too low. Retrying…',
          );
          await Future.delayed(const Duration(milliseconds: 1500));
          if (!mounted || _isTerminal || _secondsRemaining <= 0) return;

          final bool sessionActive = await _isSessionActive();
          if (!sessionActive) {
            FaceLogger.ver(
              _sessionId ?? 'QR_VER',
              'Teacher session expired during quality retry delay',
            );
            _navigateToTimeout(isTimeout: true);
            return;
          }

          if (!mounted || _isTerminal || _secondsRemaining <= 0) return;
          await _onRetry();
          return;
        } else {
          setState(() => _borderColor = AppStyles.errorRed);
          _updateInstruction(
            'Verification Failed',
            subtitle: 'Image quality was too low',
          );
          await Future.delayed(const Duration(milliseconds: 600));
          if (mounted && !_isTerminal) {
            _navigateToTimeout(isTimeout: false);
          }
          return;
        }
      }

      _validResults.sort((a, b) => b.qualityScore.compareTo(a.qualityScore));
      final List<BatchEmbeddingResult> topResults = _validResults.sublist(
        0,
        math.min(_framesPerPhase, _validResults.length),
      );

      List<List<double>> top3Embeddings = topResults
          .take(3)
          .map((r) => r.embedding!)
          .toList();
      if (top3Embeddings.isEmpty) {
        top3Embeddings = _liveEmbeddings.take(3).toList();
      }

      final List<double> avgEmbedding = _landmarkService.averageEmbeddings(
        top3Embeddings,
      );
      final List<double> fusedEmbedding = _landmarkService.l2Normalize(
        avgEmbedding,
      );

      double fusedScore = -1.0;
      if (_storedTemplates != null &&
          _storedTemplates!.isNotEmpty &&
          fusedEmbedding.isNotEmpty) {
        for (int t = 0; t < _storedTemplates!.length; t++) {
          final double sim = _landmarkService.cosineSimilarity(
            fusedEmbedding,
            _storedTemplates![t],
          );
          if (sim > fusedScore) {
            fusedScore = sim;
          }
        }
      }

      final double score = math.max(overallBestFrameScore, fusedScore);
      final bool rawMatch =
          (batchResults.isNotEmpty && batchResults.first.match != null)
          ? batchResults.first.match!
          : (framesAboveThresholdCount >= 2 ||
                fusedScore >= _verificationThreshold);
      final bool isMatch = livenessPassed && rawMatch;

      _comparisonStopwatch.start();
      _comparisonStopwatch.stop();
      _totalStopwatch.stop();

      FaceLogger.ver(
        _sessionId ?? 'QR_VER',
        'Per-Frame Multi-Template Decision:',
      );
      FaceLogger.ver(
        _sessionId ?? 'QR_VER',
        '  FramesAboveThreshold=$framesAboveThresholdCount/${_liveEmbeddings.length}',
      );
      FaceLogger.ver(
        _sessionId ?? 'QR_VER',
        '  bestFrameScore = ${overallBestFrameScore.toStringAsFixed(4)}',
      );
      FaceLogger.ver(
        _sessionId ?? 'QR_VER',
        '  fusedScore = ${fusedScore.toStringAsFixed(4)}',
      );
      FaceLogger.ver(
        _sessionId ?? 'QR_VER',
        '  finalScore = ${score.toStringAsFixed(4)}',
      );
      FaceLogger.ver(
        _sessionId ?? 'QR_VER',
        '  threshold = ${_verificationThreshold.toStringAsFixed(4)}',
      );
      FaceLogger.ver(
        _sessionId ?? 'QR_VER',
        '  livenessPassed = $livenessPassed',
      );
      FaceLogger.ver(
        _sessionId ?? 'QR_VER',
        '  final decision = ${isMatch ? "PASS" : "FAIL"}',
      );

      debugPrint('[QR_FACE][VERIFY] =========================');
      debugPrint('[QR_FACE][VERIFY] livenessPassed = $livenessPassed');
      debugPrint('[QR_FACE][VERIFY] rawMatch = $rawMatch');
      debugPrint(
        '[QR_FACE][VERIFY] verificationThreshold = ${_verificationThreshold.toStringAsFixed(4)}',
      );
      debugPrint(
        '[QR_FACE][VERIFY] bestFrameScore = ${overallBestFrameScore.toStringAsFixed(4)}',
      );
      debugPrint(
        '[QR_FACE][VERIFY] fusedScore = ${fusedScore.toStringAsFixed(4)}',
      );
      debugPrint('[QR_FACE][VERIFY] finalScore = ${score.toStringAsFixed(4)}');
      debugPrint(
        '[QR_FACE][VERIFY] framesAboveThreshold = $framesAboveThresholdCount/${_liveEmbeddings.length}',
      );
      debugPrint(
        '[QR_FACE][VERIFY] validFrameCount = $_validFrameCount/$_framesPerPhase',
      );
      debugPrint(
        '[QR_FACE][VERIFY] finalDecision = ${isMatch ? "PASS" : "FAIL"}',
      );
      debugPrint('[QR_FACE][VERIFY] =========================');

      if (isMatch) {
        // Step A: Pre-check session status before transitioning to success phase
        final bool sessionActiveInitial = await _isSessionActive();
        if (!sessionActiveInitial) {
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            'Face matched, but attendance session is no longer active. Refusing to mark present.',
          );
          if (mounted && !_isTerminal) {
            _navigateToTimeout(isTimeout: true);
          }
          return;
        }

        // ── Success ──
        setState(() => _borderColor = AppStyles.successGreen);

        setState(() => _showFlash = true);
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) setState(() => _showFlash = false);
        });

        _particleController.forward(from: 0.0);

        _setPhase(_Phase.done);
        _updateInstruction('Verified!', subtitle: 'Face matched successfully');

        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted || _isTerminal) return;

        _countdownTimer?.cancel();

        // Step B: Re-verify session status immediately before attendance update (race condition guard)
        final bool sessionStillActive = await _isSessionActive();
        if (!sessionStillActive) {
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            'Attendance session closed immediately before DB write. Refusing to mark present.',
          );
          if (mounted && !_isTerminal) {
            _navigateToTimeout(isTimeout: true);
          }
          return;
        }

        // Update period_attendance — set face_verified = true and status = present
        try {
          final user = Supabase.instance.client.auth.currentUser;
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            'Attempting update — sessionId: $_sessionId, userId: ${user?.id}',
          );
          if (user != null && _sessionId != null) {
            await Supabase.instance.client
                .from('period_attendance')
                .update({'face_verified': true, 'status': 'present'})
                .eq('session_id', _sessionId!)
                .eq('student_id', user.id);
            FaceLogger.ver(
              _sessionId ?? 'QR_VER',
              'period_attendance updated — face_verified = true',
            );
          }
        } catch (e) {
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            'Failed to update period_attendance: $e',
          );
        }

        if (!mounted || _isTerminal) return;
        _navigateToSuccess();
      } else {
        // ── Face Mismatch / Verification Failure ──
        setState(() => _borderColor = AppStyles.errorRed);
        _updateInstruction(
          'Verification Failed',
          subtitle: 'Face did not match',
        );

        if (_attemptCount < 2) {
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            'Attempt $_attemptCount failed (score=${score.toStringAsFixed(4)}, threshold=${_verificationThreshold.toStringAsFixed(4)}). Starting Attempt 2 retry.',
          );
          await Future.delayed(const Duration(milliseconds: 1200));
          if (!mounted || _isTerminal || _secondsRemaining <= 0) return;

          final bool sessionActive = await _isSessionActive();
          if (!sessionActive) {
            FaceLogger.ver(
              _sessionId ?? 'QR_VER',
              'Teacher session expired during retry delay',
            );
            _navigateToTimeout(isTimeout: true);
            return;
          }

          if (!mounted || _isTerminal || _secondsRemaining <= 0) return;
          await _onRetry();
        } else {
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            'Attempt $_attemptCount failed — 2 attempts exhausted. Rejecting verification.',
          );
          await Future.delayed(const Duration(milliseconds: 600));
          if (mounted && !_isTerminal) {
            _navigateToTimeout(isTimeout: false);
          }
        }
      }
    } catch (e) {
      _setError('Verification failed: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _onRetry() async {
    if (_isTerminal || !mounted || _secondsRemaining <= 0) return;

    debugPrint('[QR_FACE][RETRY] stopping image stream');
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      if (_cameraController!.value.isStreamingImages) {
        try {
          await _cameraController!.stopImageStream();
        } catch (e) {
          debugPrint('[QR_FACE][RETRY] error stopping image stream: $e');
        }
      }
    }
    debugPrint('[QR_FACE][RETRY] image stream stopped');

    if (_isTerminal || !mounted || _secondsRemaining <= 0) return;

    debugPrint('[QR_FACE][RETRY] verification state reset');
    _attemptCount++;
    FaceLogger.ver(
      _sessionId ?? 'QR_VER',
      'Restarting attempt $_attemptCount of 2',
    );
    _cameraStabilizer.resetStabilityOnly();
    _meteringApplied = false;
    _stabilityRejectCount = 0;
    _livenessService.reset();
    _livenessService.resetCalibration();
    _liveEmbeddings.clear();
    _capturedVerificationFrames.clear();
    _capturedVerificationFramesStats.clear();
    _allFramesStats.clear();
    _validResults.clear();
    _validFrameCount = 0;
    _captureProgress = 0;
    _cameraFrozen = false;
    _lastCapturedFrameBytes = null;
    _isSubmitting = false;
    _lastProcessedFace = null;
    _consecutiveImageErrors = 0;
    _lastFrameTime = DateTime.now();
    _isProcessingFrame = false;

    // Re-randomize liveness challenge
    final double rPlan = math.Random().nextDouble();
    if (rPlan < 0.40) {
      _livenessPlan = 'blink_only';
    } else if (rPlan < 0.70) {
      _livenessPlan = 'blink_left';
    } else {
      _livenessPlan = 'blink_right';
    }
    _blinkDone = false;
    _turnDone = false;
    _turnStartTime = null;
    _challengeVerified = false;
    _challengeStartTime = null;

    // Reset local challenge timer duration to 3000ms for blink start
    _blinkCountdownController.duration = const Duration(milliseconds: 3000);
    _blinkCountdownController.reset();

    _steadyStartTime = null;
    _isFaceReady = false;
    _lastKnownBlinkCount = 0;
    _clearSmoothing();

    // Reset stopwatches
    _captureStopwatch.reset();
    _apiStopwatch.reset();
    _comparisonStopwatch.reset();
    _totalStopwatch.reset();

    if (mounted) {
      setState(() {
        _borderColor = AppStyles.primaryBlue;
        _errorMessage = null;
      });
    }

    // Resume the 60-second screen timer countdown (does not reset _secondsRemaining)
    _startCountdownTimer();

    // Restart camera stream safely and await completion
    debugPrint('[QR_FACE][RETRY] starting image stream');
    if (_cameraInitialized &&
        _cameraController != null &&
        _cameraController!.value.isInitialized) {
      try {
        if (!_cameraController!.value.isStreamingImages) {
          await _cameraController!.startImageStream(_onCameraFrame);
        }
        debugPrint('[QR_FACE][RETRY] image stream started');
      } catch (e) {
        debugPrint('[QR_FACE][RETRY] error starting image stream: $e');
      }
    }

    // Reset/confirm stabilizer is ready
    _cameraStabilizer.resetStabilityOnly();

    debugPrint('[QR_FACE][RETRY] entering positioning');
    _setPhase(_Phase.positioning);
  }

  void _startCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _isTerminal) {
        timer.cancel();
        return;
      }
      final remaining = _calculateRemainingSeconds();
      final sessionRemaining = _calculateSessionRemainingSeconds();
      setState(() {
        _secondsRemaining = remaining;
        _sessionSecondsRemaining = sessionRemaining;
      });
      if (remaining > 0) {
        _timerPulseController.forward().then((_) {
          if (mounted) _timerPulseController.reverse();
        });
      } else {
        timer.cancel();
        if (mounted && !_isTerminal && _phase != _Phase.done) {
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            '60-second face verification timer expired',
          );
          _navigateToTimeout(isTimeout: true);
        }
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  int _consecutiveImageErrors = 0;

  InputImage? _convertToInputImage(CameraImage image) {
    try {
      final camera = _cameraController!.description;
      final int sensorDegrees = camera.sensorOrientation;
      final InputImageRotation? rotation = InputImageRotationValue.fromRawValue(
        sensorDegrees,
      );
      if (rotation == null) return null;

      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) return null;
      if (image.planes.isEmpty) return null;

      final Uint8List bytes;
      if (image.planes.length >= 3) {
        final int w = image.width;
        final int h = image.height;
        final yPlane = image.planes[0];
        final uPlane = image.planes[1];
        final vPlane = image.planes[2];

        final int yRowStride = yPlane.bytesPerRow;
        final int uvRowStride = uPlane.bytesPerRow;
        final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

        final nv21 = Uint8List(w * h + (w * (h ~/ 2)));
        int pos = 0;

        for (int row = 0; row < h; row++) {
          final int srcOffset = row * yRowStride;
          for (int col = 0; col < w; col++) {
            nv21[pos++] = yPlane.bytes[srcOffset + col];
          }
        }

        final int uvHeight = h ~/ 2;
        final int uvWidth = w ~/ 2;
        for (int row = 0; row < uvHeight; row++) {
          final int srcOffset = row * uvRowStride;
          for (int col = 0; col < uvWidth; col++) {
            final int pixelOffset = srcOffset + col * uvPixelStride;
            nv21[pos++] = vPlane.bytes[pixelOffset];
            nv21[pos++] = uPlane.bytes[pixelOffset];
          }
        }

        bytes = nv21;
      } else {
        bytes = image.planes[0].bytes;
      }

      final metadata = InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      );

      _consecutiveImageErrors = 0;
      return InputImage.fromBytes(bytes: bytes, metadata: metadata);
    } catch (e) {
      _consecutiveImageErrors++;
      if (_consecutiveImageErrors > 30) {
        _setError('Camera stream error. Please restart.');
      }
      return null;
    }
  }

  double _calculateIoU(Rect a, Rect b) {
    final double left = math.max(a.left, b.left);
    final double top = math.max(a.top, b.top);
    final double right = math.min(a.right, b.right);
    final double bottom = math.min(a.bottom, b.bottom);

    if (right <= left || bottom <= top) return 0.0;

    final double intersectionArea = (right - left) * (bottom - top);
    final double areaA = a.width * a.height;
    final double areaB = b.width * b.height;
    final double unionArea = areaA + areaB - intersectionArea;

    if (unionArea <= 0.0) return 0.0;
    return intersectionArea / unionArea;
  }

  Face? _selectBiggestCenteredFace(List<Face> faces, CameraImage image) {
    if (faces.isEmpty) return null;

    final sorted = List<Face>.from(faces)
      ..sort((a, b) {
        final double areaA = a.boundingBox.width * a.boundingBox.height;
        final double areaB = b.boundingBox.width * b.boundingBox.height;
        return areaB.compareTo(areaA);
      });

    final Face biggest = sorted.first;
    final double biggestArea =
        biggest.boundingBox.width * biggest.boundingBox.height;

    final double centerX =
        biggest.boundingBox.left + biggest.boundingBox.width / 2;
    final double imageCenterX = image.width / 2.0;
    final double offsetX = (centerX - imageCenterX).abs() / image.width;

    if (offsetX > 0.30) return null;

    if (sorted.length > 1) {
      final double secondArea =
          sorted[1].boundingBox.width * sorted[1].boundingBox.height;
      if (secondArea > 0.50 * biggestArea) {
        if (offsetX > 0.20) {
          debugPrint(
            '[FACE_VER] Second face present (>50% area) and largest face offsetX (${offsetX.toStringAsFixed(3)}) > 0.20 — requiring main person centered',
          );
          return null;
        }
      }
    }

    return biggest;
  }

  // ─── Face positioning — smoothed centering + distance + hysteresis ────
  void _pushSmoothing(Face face) {
    _bufFaceWidth.add(face.boundingBox.width);
    _bufFaceHeight.add(face.boundingBox.height);
    _bufFaceCX.add(face.boundingBox.center.dx);
    _bufFaceCY.add(face.boundingBox.center.dy);
    _bufYaw.add(face.headEulerAngleY ?? 0);
    _bufPitch.add(face.headEulerAngleX ?? 0);
    while (_bufFaceWidth.length > _smoothingBufferSize) {
      _bufFaceWidth.removeAt(0);
      _bufFaceHeight.removeAt(0);
      _bufFaceCX.removeAt(0);
      _bufFaceCY.removeAt(0);
      _bufYaw.removeAt(0);
      _bufPitch.removeAt(0);
    }
  }

  double _bufAvg(List<double> buf) {
    if (buf.isEmpty) return 0;
    return buf.reduce((a, b) => a + b) / buf.length;
  }

  void _clearSmoothing() {
    _bufFaceWidth.clear();
    _bufFaceHeight.clear();
    _bufFaceCX.clear();
    _bufFaceCY.clear();
    _bufYaw.clear();
    _bufPitch.clear();
    _lastPosInstruction = null;
  }

  String? _getPositioningInstruction(
    Face face,
    CameraImage image, {
    bool strict = true,
  }) {
    if (_uiCircleSize == 0 || _uiAvailW == 0) return null;

    final int sensorOrientation =
        _cameraController!.description.sensorOrientation;
    final bool isRotated = sensorOrientation == 90 || sensorOrientation == 270;
    final double rotW = isRotated
        ? image.height.toDouble()
        : image.width.toDouble();
    final double rotH = isRotated
        ? image.width.toDouble()
        : image.height.toDouble();

    final double scale = _uiAvailW / rotW;

    final double circleCameraCX = rotW / 2;
    final double circleTop = _uiAvailH * 0.40 - _uiCircleSize / 2;
    final double circleCameraCY = rotH / 2 + circleTop / scale;

    final double circleCameraSize = _uiCircleSize / scale;

    final double smoothW = _bufAvg(_bufFaceWidth);
    final double smoothH = _bufAvg(_bufFaceHeight);
    final double smoothCX = _bufAvg(_bufFaceCX);
    final double smoothCY = _bufAvg(_bufFaceCY);

    final double smoothLeft = smoothCX - smoothW / 2;
    final double smoothRight = smoothCX + smoothW / 2;
    final double smoothTop = smoothCY - smoothH / 2;
    final double smoothBottom = smoothCY + smoothH / 2;

    final double circleRadius = circleCameraSize / 2;

    // Virtual crown (hairline) — extend upward by 30%
    final double virtualCrownTop = smoothTop - (smoothH * 0.30);

    final double circleTopBound = circleCameraCY - circleRadius;
    final double circleBottomBound = circleCameraCY + circleRadius;
    final double circleLeftBound = circleCameraCX - circleRadius;
    final double circleRightBound = circleCameraCX + circleRadius;

    if (virtualCrownTop < circleTopBound) {
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }
    if (smoothBottom > circleBottomBound) {
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }
    if (smoothLeft < circleLeftBound || smoothRight > circleRightBound) {
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }

    // Distance check with hysteresis
    final double faceWidthRatio = smoothW / circleCameraSize;
    final bool wasTooFar = _lastPosInstruction == 'Move closer to the camera';
    final bool wasTooClose = _lastPosInstruction == 'Move slightly backward';

    if (faceWidthRatio < 0.40 || (wasTooFar && faceWidthRatio < 0.45)) {
      _lastPosInstruction = 'Move closer to the camera';
      return 'Move closer to the camera';
    }

    final double backwardEnter = (_lastPosInstruction == null) ? 0.95 : 0.80;
    if (faceWidthRatio > backwardEnter ||
        (wasTooClose && faceWidthRatio > 0.75)) {
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }

    // Relaxed centering — 20/25% grace zone
    final double graceZoneX = circleRadius * 0.20;
    final double graceZoneY = circleRadius * 0.25;

    final double offX = (smoothCX - circleCameraCX).abs();
    if (offX > graceZoneX) {
      _lastPosInstruction = 'Move to the center of the circle';
      return 'Move to the center of the circle';
    }

    final double offY = (smoothCY - circleCameraCY).abs();
    if (offY > graceZoneY) {
      _lastPosInstruction = 'Move to the center of the circle';
      return 'Move to the center of the circle';
    }

    // All checks passed
    _lastPosInstruction = null;
    return null;
  }

  bool _isFaceAcceptable(Face face, CameraImage image) {
    if (_uiCircleSize > 0 && _uiAvailW > 0 && _bufFaceWidth.isNotEmpty) {
      final int sensorOrientation =
          _cameraController!.description.sensorOrientation;
      final bool isRotated =
          sensorOrientation == 90 || sensorOrientation == 270;
      final double rotW = isRotated
          ? image.height.toDouble()
          : image.width.toDouble();
      final double rotH = isRotated
          ? image.width.toDouble()
          : image.height.toDouble();
      final double scale = _uiAvailW / rotW;

      final double circleCameraCX = rotW / 2;
      final double circleTopUI = _uiAvailH * 0.40 - _uiCircleSize / 2;
      final double circleCameraCY = rotH / 2 + circleTopUI / scale;
      final double circleCameraSize = _uiCircleSize / scale;
      final double circleRadius = circleCameraSize / 2;

      final double circleTopBound = circleCameraCY - circleRadius;
      final double circleBottomBound = circleCameraCY + circleRadius;
      final double circleLeftBound = circleCameraCX - circleRadius;
      final double circleRightBound = circleCameraCX + circleRadius;

      final double smoothW = _bufAvg(_bufFaceWidth);
      final double smoothH = _bufAvg(_bufFaceHeight);
      final double smoothCX = _bufAvg(_bufFaceCX);
      final double smoothCY = _bufAvg(_bufFaceCY);
      final double smoothTop = smoothCY - smoothH / 2;
      final double smoothBottom = smoothCY + smoothH / 2;
      final double smoothLeft = smoothCX - smoothW / 2;
      final double smoothRight = smoothCX + smoothW / 2;

      final double virtualCrownTop = smoothTop - (smoothH * 0.30);

      if (virtualCrownTop < circleTopBound ||
          smoothBottom > circleBottomBound ||
          smoothLeft < circleLeftBound ||
          smoothRight > circleRightBound) {
        return false;
      }
    }

    final double widthRatio = face.boundingBox.width / image.width;
    if (widthRatio < 0.12 || widthRatio > 0.85) return false;

    final double centerX = face.boundingBox.left + face.boundingBox.width / 2;
    final double imageCenterX = image.width / 2;
    final double centerOffset = (centerX - imageCenterX).abs() / image.width;
    if (centerOffset > 0.25) return false;

    final double? pitch = face.headEulerAngleX;
    if (pitch != null && pitch.abs() > 35) return false;

    return true;
  }

  // Capture current camera frame as JPEG bytes
  Future<Uint8List?> _captureCurrentFrame() async {
    try {
      if (_lastCameraImage == null) return null;
      final camImg = _lastCameraImage!;

      if (camImg.format.group == ImageFormatGroup.jpeg) {
        return Uint8List.fromList(camImg.planes[0].bytes);
      }

      return _convertYuvToJpegSync(camImg);
    } catch (e) {
      return null;
    }
  }

  Uint8List? _convertYuvToJpegSync(CameraImage camImg) {
    try {
      final int width = camImg.width;
      final int height = camImg.height;
      final yPlane = camImg.planes[0];
      final uPlane = camImg.planes[1];
      final vPlane = camImg.planes[2];
      final int uvRowStride = uPlane.bytesPerRow;
      final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

      final image = img.Image(width: width, height: height);

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int yIndex = y * yPlane.bytesPerRow + x;
          final int uvIndex = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;

          if (yIndex >= yPlane.bytes.length) continue;
          if (uvIndex >= uPlane.bytes.length) continue;

          final int yVal = yPlane.bytes[yIndex];
          final int uVal = uPlane.bytes[uvIndex];
          final int vVal = vPlane.bytes[uvIndex];

          final int r = (yVal + 1.402 * (vVal - 128)).round().clamp(0, 255);
          final int g =
              (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128))
                  .round()
                  .clamp(0, 255);
          final int b = (yVal + 1.772 * (uVal - 128)).round().clamp(0, 255);

          image.setPixelRgb(x, y, r, g, b);
        }
      }

      return Uint8List.fromList(img.encodeJpg(image, quality: 80));
    } catch (e) {
      return null;
    }
  }

  void _setPhase(_Phase newPhase) {
    if (!mounted) return;
    setState(() {
      _phase = newPhase;
      switch (newPhase) {
        case _Phase.initializing:
          _instructionTitle = 'Setting up camera…';
          _instructionSubtitle = _subtitles[_instructionTitle] ?? '';
          _borderColor = AppStyles.primaryBlue;
          break;
        case _Phase.positioning:
          _instructionTitle = 'Fit your face in the circle';
          _instructionSubtitle = _subtitles[_instructionTitle] ?? '';
          _borderColor = AppStyles.primaryBlue;
          break;
        case _Phase.liveness:
          _instructionTitle = _getChallengeInstruction(ChallengeType.blink);
          _instructionSubtitle = _subtitles[_instructionTitle] ?? '';
          _borderColor = AppStyles.primaryBlue;
          break;
        case _Phase.capturing:
          _instructionTitle = 'Hold still…';
          _instructionSubtitle = 'Scanning your face silently';
          _borderColor = AppStyles.primaryBlue;
          break;
        case _Phase.processing:
          _instructionTitle = 'Verifying Identity';
          _instructionSubtitle = 'Comparing your live face securely…';
          _borderColor = AppStyles.primaryBlue;
          break;
        case _Phase.done:
          _instructionTitle = 'Verified!';
          _instructionSubtitle = _subtitles[_instructionTitle] ?? '';
          _borderColor = AppStyles.successGreen;
          break;
        case _Phase.error:
          _instructionTitle = 'Something went wrong';
          _instructionSubtitle = _subtitles[_instructionTitle] ?? '';
          _borderColor = AppStyles.errorRed;
          break;
      }
    });
  }

  void _updateInstruction(
    String title, {
    String? subtitle,
    bool animate = true,
  }) {
    if (!mounted) return;
    if (_instructionTitle == title &&
        (subtitle == null || _instructionSubtitle == subtitle)) {
      return;
    }

    _instructionDebounceTimer?.cancel();
    _instructionDebounceTimer = Timer(
      Duration(milliseconds: animate ? 100 : 0),
      () {
        if (!mounted) return;
        setState(() {
          _instructionTitle = title;
          _instructionSubtitle = subtitle ?? _subtitles[title] ?? '';
        });
        if (animate) {
          _textFadeController.forward(from: 0.0);
        }
      },
    );
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
      _phase = _Phase.error;
      _instructionTitle = 'Verification Failed';
      _instructionSubtitle = message;
      _borderColor = AppStyles.errorRed;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted && !_isTerminal && _phase != _Phase.done) {
        final remaining = _calculateRemainingSeconds();
        final sessionRemaining = _calculateSessionRemainingSeconds();
        setState(() {
          _secondsRemaining = remaining;
          _sessionSecondsRemaining = sessionRemaining;
        });
        if (remaining <= 0) {
          _countdownTimer?.cancel();
          FaceLogger.ver(
            _sessionId ?? 'QR_VER',
            '60-second face verification timer expired while in background',
          );
          _navigateToTimeout(isTimeout: true);
        } else {
          _revalidateSessionOnResume();
        }
      }
    }
  }

  Future<void> _revalidateSessionOnResume() async {
    if (_sessionId == null || !mounted || _isRevalidatingSession) return;
    _isRevalidatingSession = true;
    try {
      final isActive = await _isSessionActive();
      if (!isActive && mounted && !_isTerminal && _phase != _Phase.done) {
        FaceLogger.ver(
          _sessionId ?? 'QR_VER',
          'Teacher attendance session closed while app was backgrounded',
        );
        _navigateToTimeout(isTimeout: true);
      }
    } catch (e) {
      debugPrint('[QR_FACE_VER] Error revalidating session on resume: $e');
    } finally {
      _isRevalidatingSession = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _isTerminal = true;
    _countdownTimer?.cancel();
    _instructionDebounceTimer?.cancel();

    _pulseController.dispose();
    _textFadeController.dispose();
    _blinkCountdownController.dispose();
    _successBounceController.dispose();
    _particleController.dispose();
    _timerPulseController.dispose();
    _ringController.dispose();

    if (_cameraController != null) {
      final controllerToDispose = _cameraController;
      _cameraController = null;

      _cameraReleaseFuture = Future.microtask(() async {
        try {
          if (controllerToDispose != null &&
              controllerToDispose.value.isStreamingImages) {
            await controllerToDispose.stopImageStream();
          }
        } catch (e) {
          debugPrint('[DISPOSE] stopImageStream error: $e');
        }
        try {
          await controllerToDispose?.dispose();
        } catch (e) {
          debugPrint('[DISPOSE] dispose error: $e');
        }
      });
    }

    _mlService.faceDetector.close();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppStyles.backgroundLight,
        body: Stack(
          children: [
            // ── Seamless Full-Screen Ambient Background ────────────────────
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, _) => _FaceVerificationAmbientBackground(
                pulseValue: _pulseController.value,
              ),
            ),

            SafeArea(
              child: Column(
                children: [
                  // ── Top App Bar ──────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 8.0,
                    ),
                    child: Row(
                      children: const [
                        SizedBox(width: 48),
                        Spacer(),
                        Text(
                          'Face Verification',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1A202C),
                            letterSpacing: -0.3,
                          ),
                        ),
                        Spacer(),
                        SizedBox(width: 48),
                      ],
                    ),
                  ),

                  // ── Attendance Session Card ─────────────────────────
                  if (_subjectName.isNotEmpty || _periodInfo.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(36, 0, 36, 6.0),
                      child: Container(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width - 72,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8.5,
                        ),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Colors.white, Color(0xFFF8FAFC)],
                          ),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: const Color(
                              0xFF3B82F6,
                            ).withValues(alpha: 0.16),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF0F172A,
                              ).withValues(alpha: 0.05),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                            BoxShadow(
                              color: const Color(
                                0xFF3B82F6,
                              ).withValues(alpha: 0.04),
                              blurRadius: 8,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // ── LEFT: Period + Active pill group (top row) & Subject (below) ──
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Top-left row: "5th Period" pill + "Active" pill
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      // Period pill
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7.5,
                                          vertical: 2.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFF3B82F6,
                                          ).withValues(alpha: 0.09),
                                          borderRadius: BorderRadius.circular(
                                            7,
                                          ),
                                          border: Border.all(
                                            color: const Color(
                                              0xFF3B82F6,
                                            ).withValues(alpha: 0.24),
                                            width: 0.9,
                                          ),
                                        ),
                                        child: Text(
                                          _periodInfo.isNotEmpty
                                              ? _periodInfo
                                              : '5th Period',
                                          style: const TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF1D4ED8),
                                            letterSpacing: 0.2,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),

                                      const SizedBox(width: 5.5),

                                      // Green "Active" status pill with continuous subtle glow/pulse
                                      AnimatedBuilder(
                                        animation: _timerPulseAnim,
                                        builder: (context, _) {
                                          final double pulseVal =
                                              _timerPulseAnim.value;
                                          final double glowIntensity =
                                              ((pulseVal - 1.0) / 0.05).clamp(
                                                0.0,
                                                1.0,
                                              );
                                          return Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8.0,
                                              vertical: 2.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF10B981)
                                                  .withValues(
                                                    alpha:
                                                        0.11 +
                                                        0.05 * glowIntensity,
                                                  ),
                                              borderRadius:
                                                  BorderRadius.circular(7),
                                              border: Border.all(
                                                color: const Color(0xFF10B981)
                                                    .withValues(
                                                      alpha:
                                                          0.38 +
                                                          0.16 * glowIntensity,
                                                    ),
                                                width: 1.0,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: const Color(0xFF10B981)
                                                      .withValues(
                                                        alpha:
                                                            0.14 +
                                                            0.12 *
                                                                glowIntensity,
                                                      ),
                                                  blurRadius:
                                                      7.0 + 2.0 * glowIntensity,
                                                  spreadRadius: 0.2,
                                                ),
                                              ],
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.center,
                                              children: [
                                                Container(
                                                  width: 5.5,
                                                  height: 5.5,
                                                  decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: const Color(
                                                      0xFF059669,
                                                    ),
                                                    boxShadow: [
                                                      BoxShadow(
                                                        color:
                                                            const Color(
                                                              0xFF10B981,
                                                            ).withValues(
                                                              alpha:
                                                                  0.6 +
                                                                  0.3 *
                                                                      glowIntensity,
                                                            ),
                                                        blurRadius: 3,
                                                        spreadRadius: 0.5,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 4.5),
                                                const Text(
                                                  'Active',
                                                  style: TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.w700,
                                                    color: Color(0xFF047857),
                                                    letterSpacing: 0.2,
                                                    height: 1.0,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 5.5),

                                  // Subject name below top row
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      _subjectName.isNotEmpty
                                          ? _subjectName
                                          : 'Computer Networks',
                                      style: const TextStyle(
                                        fontSize: 15.0,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF0F172A),
                                        letterSpacing: -0.35,
                                        height: 1.15,
                                      ),
                                      maxLines: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 10.0),

                            // ── RIGHT: Elevated circular countdown timer (Attendance Session Timer) ──
                            AnimatedBuilder(
                              animation: Listenable.merge([
                                _ringProgress,
                                _timerPulseAnim,
                              ]),
                              builder: (context, _) {
                                final Color timerColor =
                                    _sessionSecondsRemaining <= 30
                                    ? AppStyles.errorRed
                                    : _sessionSecondsRemaining <= 60
                                    ? AppStyles.amberWarning
                                    : AppStyles.primaryBlue;
                                final double progress =
                                    (_sessionSecondsRemaining / 180.0).clamp(
                                      0.0,
                                      1.0,
                                    );
                                final String mm =
                                    (_sessionSecondsRemaining ~/ 60)
                                        .toString()
                                        .padLeft(2, '0');
                                final String ss =
                                    (_sessionSecondsRemaining % 60)
                                        .toString()
                                        .padLeft(2, '0');

                                return ScaleTransition(
                                  scale: _timerPulseAnim,
                                  child: Container(
                                    width: 50,
                                    height: 50,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.white,
                                      boxShadow: [
                                        BoxShadow(
                                          color: timerColor.withValues(
                                            alpha: 0.18,
                                          ),
                                          blurRadius: 10,
                                          offset: const Offset(0, 2),
                                          spreadRadius: 0.5,
                                        ),
                                        BoxShadow(
                                          color: const Color(
                                            0xFF0F172A,
                                          ).withValues(alpha: 0.04),
                                          blurRadius: 4,
                                          offset: const Offset(0, 1),
                                        ),
                                      ],
                                    ),
                                    child: CustomPaint(
                                      painter: _MiniRingPainter(
                                        progress: progress,
                                        color: timerColor,
                                      ),
                                      child: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.timer_outlined,
                                              size: 9.5,
                                              color: timerColor,
                                            ),
                                            const SizedBox(height: 1.0),
                                            Text(
                                              '$mm:$ss',
                                              style: const TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w800,
                                                color: Color(0xFF0F172A),
                                                letterSpacing: -0.25,
                                                height: 1.0,
                                                fontFeatures: [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                  // ── Camera Preview & Verification Content Stack ──────────
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final double availW = constraints.maxWidth;
                        final double availH = constraints.maxHeight;
                        final double circleSize = availW * 0.80;
                        final double circleTop = availH * 0.40 - circleSize / 2;
                        const double contentShift = 6.0;
                        final double verificationBaseTop =
                            circleTop - 110.0 + contentShift;

                        _uiCircleSize = circleSize;
                        _uiAvailW = availW;
                        _uiAvailH = availH;

                        double offsetX = 0;
                        double offsetY = 0;
                        if (_cameraInitialized && _bufFaceCX.isNotEmpty) {
                          final Size? previewSize =
                              _cameraController?.value.previewSize;
                          final double sensorW = previewSize?.height ?? 3.0;
                          if (sensorW > 0) {
                            final double scale = availW / sensorW;
                            final double faceUIX = _bufAvg(_bufFaceCX) * scale;
                            final double faceUIY = _bufAvg(_bufFaceCY) * scale;
                            final double circleUIX = availW / 2;
                            final double circleUIY =
                                verificationBaseTop + circleSize / 2;

                            offsetX = (faceUIX - circleUIX).clamp(-6.0, 6.0);
                            offsetY = (faceUIY - circleUIY).clamp(-6.0, 6.0);
                          }
                        }

                        return SizedBox(
                          width: availW,
                          height: availH,
                          child: Stack(
                            children: [
                              // Face Interactive Overlay Group
                              AnimatedPositioned(
                                duration: const Duration(milliseconds: 120),
                                curve: Curves.easeOut,
                                left: offsetX,
                                top: offsetY,
                                right: -offsetX,
                                bottom: -offsetY,
                                child: Stack(
                                  children: [
                                    // Circle clip for the camera preview
                                    Positioned(
                                      left: (availW - circleSize) / 2,
                                      top: verificationBaseTop,
                                      child: ClipOval(
                                        child: SizedBox(
                                          width: circleSize,
                                          height: circleSize,
                                          child: Stack(
                                            children: [
                                              // 1. Live Camera Preview (or Frozen Captured Final Frame)
                                              if (_cameraInitialized &&
                                                  _cameraController != null)
                                                OverflowBox(
                                                  maxWidth: availW,
                                                  maxHeight: availH,
                                                  child: Transform.translate(
                                                    offset: Offset(
                                                      0,
                                                      -circleTop,
                                                    ),
                                                    child: _buildCameraPreview(
                                                      availW,
                                                      circleTop,
                                                    ),
                                                  ),
                                                ),

                                              // 2. Warm-up loading overlay
                                              AnimatedSwitcher(
                                                duration: const Duration(
                                                  milliseconds: 350,
                                                ),
                                                switchInCurve: Curves.easeOut,
                                                switchOutCurve: Curves.easeIn,
                                                child: !_cameraPreviewReady
                                                    ? _buildWarmupLoader(
                                                        circleSize,
                                                      )
                                                    : const SizedBox.shrink(
                                                        key: ValueKey(
                                                          'camera_ready',
                                                        ),
                                                      ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),

                                    // Pulsing circle border + progress
                                    Positioned(
                                      left: (availW - circleSize) / 2,
                                      top: verificationBaseTop,
                                      child: ScaleTransition(
                                        scale:
                                            Tween<double>(
                                              begin: 1.0,
                                              end: 1.05,
                                            ).animate(
                                              CurvedAnimation(
                                                parent:
                                                    _successBounceController,
                                                curve: Curves.elasticOut,
                                              ),
                                            ),
                                        child: TweenAnimationBuilder<double>(
                                          tween: Tween<double>(
                                            begin: 0.0,
                                            end:
                                                _captureProgress /
                                                _framesPerPhase,
                                          ),
                                          duration: const Duration(
                                            milliseconds: 800,
                                          ),
                                          curve: Curves.elasticOut,
                                          builder:
                                              (
                                                context,
                                                animatedProgress,
                                                child,
                                              ) {
                                                double tilt = 0.0;
                                                if (animatedProgress > 0.4 &&
                                                    animatedProgress < 0.9) {
                                                  tilt =
                                                      math.sin(
                                                        (animatedProgress -
                                                                0.4) *
                                                            math.pi *
                                                            4,
                                                      ) *
                                                      0.03;
                                                }
                                                return Transform.rotate(
                                                  angle: tilt,
                                                  child: AnimatedBuilder(
                                                    animation: _pulseController,
                                                    builder: (context, _) {
                                                      return CustomPaint(
                                                        size: Size(
                                                          circleSize,
                                                          circleSize,
                                                        ),
                                                        painter: _BorderPainter(
                                                          pulseValue:
                                                              _pulseController
                                                                  .value,
                                                          baseColor:
                                                              _borderColor,
                                                          progress:
                                                              animatedProgress,
                                                          phase: _phase,
                                                          flowValue: 0.0,
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                );
                                              },
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Fill Light Overlay
                              Positioned.fill(
                                child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 600),
                                  curve: Curves.easeOut,
                                  opacity: _phase == _Phase.capturing
                                      ? 0.3
                                      : 0.0,
                                  child: CustomPaint(
                                    painter: _FillLightPainter(
                                      circleCenter: Offset(
                                        availW / 2,
                                        verificationBaseTop + circleSize / 2,
                                      ),
                                      circleRadius: circleSize / 2,
                                    ),
                                  ),
                                ),
                              ),

                              // Studio Flash on Capture
                              Positioned.fill(
                                child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 100),
                                  curve: Curves.easeOut,
                                  opacity: _showFlash ? 0.3 : 0.0,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: RadialGradient(
                                        center: FractionalOffset(
                                          0.5,
                                          (verificationBaseTop +
                                                  circleSize / 2) /
                                              availH,
                                        ),
                                        radius: 0.8,
                                        colors: [
                                          Colors.white,
                                          Colors.white.withValues(alpha: 0.0),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              // Confetti Particle Burst
                              Positioned(
                                left: (availW - circleSize) / 2,
                                top: verificationBaseTop,
                                child: AnimatedBuilder(
                                  animation: _particleController,
                                  builder: (context, _) => CustomPaint(
                                    size: Size(circleSize, circleSize),
                                    painter: _ParticleBurstPainter(
                                      _particleController.value,
                                    ),
                                  ),
                                ),
                              ),

                              // ── Dynamic Layout Column ──
                              Positioned(
                                top: verificationBaseTop + circleSize + 18,
                                left: math.max(
                                  (availW - circleSize) / 2 - 16,
                                  14.0,
                                ),
                                right: math.max(
                                  (availW - circleSize) / 2 - 16,
                                  14.0,
                                ),
                                child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 300),
                                  opacity:
                                      _cameraPreviewReady &&
                                          _phase != _Phase.initializing
                                      ? 1.0
                                      : 0.0,
                                  child: SingleChildScrollView(
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // 1. Countdown Timer Slot (Swaps between Challenge Countdown and 60s Session Ring)
                                        if (_phase != _Phase.initializing &&
                                            _phase != _Phase.processing &&
                                            _phase != _Phase.done)
                                          SizedBox(
                                            height: 52,
                                            child: Center(
                                              child: AnimatedSwitcher(
                                                duration: const Duration(
                                                  milliseconds: 300,
                                                ),
                                                switchInCurve:
                                                    Curves.easeOutCubic,
                                                switchOutCurve:
                                                    Curves.easeInCubic,
                                                child:
                                                    (_phase ==
                                                            _Phase.liveness &&
                                                        !_challengeVerified &&
                                                        !_blinkDone)
                                                    ? SizedBox(
                                                        key: const ValueKey(
                                                          'challenge_timer',
                                                        ),
                                                        width: 50,
                                                        height: 50,
                                                        child: AnimatedBuilder(
                                                          animation:
                                                              _blinkCountdownController,
                                                          builder: (context, child) {
                                                            final double
                                                            totalDurationSeconds =
                                                                _blinkCountdownController
                                                                    .duration
                                                                    ?.inMilliseconds
                                                                    .toDouble() ??
                                                                3000.0;
                                                            final double
                                                            remainingSec =
                                                                (totalDurationSeconds /
                                                                    1000.0) *
                                                                (1.0 -
                                                                    _blinkCountdownController
                                                                        .value);
                                                            final int
                                                            currentSec =
                                                                remainingSec
                                                                    .ceil();
                                                            const Color
                                                            warmOrange = Color(
                                                              0xFFF97316,
                                                            );

                                                            return Container(
                                                              width: 50,
                                                              height: 50,
                                                              decoration: BoxDecoration(
                                                                shape: BoxShape
                                                                    .circle,
                                                                color: Colors
                                                                    .white,
                                                                boxShadow: [
                                                                  BoxShadow(
                                                                    color: warmOrange
                                                                        .withValues(
                                                                          alpha:
                                                                              0.25,
                                                                        ),
                                                                    blurRadius:
                                                                        10,
                                                                    offset:
                                                                        const Offset(
                                                                          0,
                                                                          3,
                                                                        ),
                                                                  ),
                                                                ],
                                                              ),
                                                              child: CustomPaint(
                                                                painter: _MiniRingPainter(
                                                                  progress:
                                                                      1.0 -
                                                                      _blinkCountdownController
                                                                          .value,
                                                                  color:
                                                                      warmOrange,
                                                                ),
                                                                child: Center(
                                                                  child: AnimatedSwitcher(
                                                                    duration: const Duration(
                                                                      milliseconds:
                                                                          200,
                                                                    ),
                                                                    transitionBuilder:
                                                                        (
                                                                          child,
                                                                          animation,
                                                                        ) {
                                                                          return ScaleTransition(
                                                                            scale:
                                                                                animation,
                                                                            child: FadeTransition(
                                                                              opacity: animation,
                                                                              child: child,
                                                                            ),
                                                                          );
                                                                        },
                                                                    child: Text(
                                                                      '$currentSec',
                                                                      key:
                                                                          ValueKey<
                                                                            int
                                                                          >(
                                                                            currentSec,
                                                                          ),
                                                                      style: const TextStyle(
                                                                        fontSize:
                                                                            18,
                                                                        fontWeight:
                                                                            FontWeight.w800,
                                                                        color: Color(
                                                                          0xFF0F172A,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        ),
                                                      )
                                                    : AnimatedBuilder(
                                                        key: const ValueKey(
                                                          'session_ring',
                                                        ),
                                                        animation:
                                                            Listenable.merge([
                                                              _ringProgress,
                                                              _timerPulseAnim,
                                                            ]),
                                                        builder: (context, _) {
                                                          final Color
                                                          ringColor =
                                                              _secondsRemaining <=
                                                                  15
                                                              ? AppStyles
                                                                    .errorRed
                                                              : _secondsRemaining <=
                                                                    30
                                                              ? AppStyles
                                                                    .amberWarning
                                                              : AppStyles
                                                                    .primaryBlue;
                                                          final double
                                                          progress =
                                                              (_secondsRemaining /
                                                                      _totalSeconds
                                                                          .toDouble())
                                                                  .clamp(
                                                                    0.0,
                                                                    1.0,
                                                                  );
                                                          return ScaleTransition(
                                                            scale:
                                                                _timerPulseAnim,
                                                            child: Container(
                                                              width: 50,
                                                              height: 50,
                                                              decoration: BoxDecoration(
                                                                shape: BoxShape
                                                                    .circle,
                                                                color: Colors
                                                                    .white,
                                                                boxShadow: [
                                                                  BoxShadow(
                                                                    color: ringColor
                                                                        .withValues(
                                                                          alpha:
                                                                              0.15,
                                                                        ),
                                                                    blurRadius:
                                                                        10,
                                                                    offset:
                                                                        const Offset(
                                                                          0,
                                                                          3,
                                                                        ),
                                                                  ),
                                                                ],
                                                              ),
                                                              child: CustomPaint(
                                                                painter: _MiniRingPainter(
                                                                  progress:
                                                                      progress,
                                                                  color:
                                                                      ringColor,
                                                                ),
                                                                child: Center(
                                                                  child: AnimatedSwitcher(
                                                                    duration: const Duration(
                                                                      milliseconds:
                                                                          200,
                                                                    ),
                                                                    transitionBuilder:
                                                                        (
                                                                          child,
                                                                          animation,
                                                                        ) {
                                                                          return ScaleTransition(
                                                                            scale:
                                                                                animation,
                                                                            child: FadeTransition(
                                                                              opacity: animation,
                                                                              child: child,
                                                                            ),
                                                                          );
                                                                        },
                                                                    child: Text(
                                                                      '$_secondsRemaining',
                                                                      key:
                                                                          ValueKey<
                                                                            int
                                                                          >(
                                                                            _secondsRemaining,
                                                                          ),
                                                                      style: const TextStyle(
                                                                        fontSize:
                                                                            16,
                                                                        fontWeight:
                                                                            FontWeight.w800,
                                                                        color: Color(
                                                                          0xFF0F172A,
                                                                        ),
                                                                        letterSpacing:
                                                                            -0.3,
                                                                      ),
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
                                          ),

                                        const SizedBox(height: 6),

                                        // 2. Attempt Counter
                                        AnimatedOpacity(
                                          duration: const Duration(
                                            milliseconds: 300,
                                          ),
                                          opacity: _cameraPreviewReady
                                              ? 1.0
                                              : 0.0,
                                          child: AnimatedSwitcher(
                                            duration: const Duration(
                                              milliseconds: 250,
                                            ),
                                            switchInCurve: Curves.easeOutCubic,
                                            switchOutCurve: Curves.easeInCubic,
                                            transitionBuilder:
                                                (child, animation) {
                                                  return FadeTransition(
                                                    opacity: animation,
                                                    child: SlideTransition(
                                                      position: Tween<Offset>(
                                                        begin: const Offset(
                                                          0,
                                                          0.2,
                                                        ),
                                                        end: Offset.zero,
                                                      ).animate(animation),
                                                      child: child,
                                                    ),
                                                  );
                                                },
                                            child: Text(
                                              'Attempt $_attemptCount of 2',
                                              key: ValueKey<int>(_attemptCount),
                                              style: const TextStyle(
                                                fontSize: 13.0,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.35,
                                                color: Color(0xFF0F172A),
                                              ),
                                            ),
                                          ),
                                        ),

                                        const SizedBox(height: 8),

                                        // 3. Status Stepper Card
                                        if (_phase != _Phase.initializing &&
                                            _phase != _Phase.processing &&
                                            _phase != _Phase.done)
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                            child: BackdropFilter(
                                              filter: ImageFilter.blur(
                                                sigmaX: 12,
                                                sigmaY: 12,
                                              ),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 14,
                                                      vertical: 11,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.94),
                                                  borderRadius:
                                                      BorderRadius.circular(18),
                                                  border: Border.all(
                                                    color: const Color(
                                                      0xFF3B82F6,
                                                    ).withValues(alpha: 0.12),
                                                    width: 1.2,
                                                  ),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: const Color(
                                                        0xFF0F172A,
                                                      ).withValues(alpha: 0.04),
                                                      blurRadius: 18,
                                                      offset: const Offset(
                                                        0,
                                                        4,
                                                      ),
                                                    ),
                                                    BoxShadow(
                                                      color: AppStyles
                                                          .primaryBlue
                                                          .withValues(
                                                            alpha: 0.06,
                                                          ),
                                                      blurRadius: 10,
                                                      offset: const Offset(
                                                        0,
                                                        2,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                child: AnimatedBuilder(
                                                  animation: _pulseController,
                                                  builder: (context, _) {
                                                    final bool
                                                    isLivenessActive =
                                                        _phase ==
                                                            _Phase
                                                                .positioning ||
                                                        _phase ==
                                                            _Phase.liveness;
                                                    final bool
                                                    isScanningActive =
                                                        _phase ==
                                                        _Phase.capturing;

                                                    return Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceBetween,
                                                      children: [
                                                        _NeonChip(
                                                          label: 'Liveness',
                                                          isActive:
                                                              isLivenessActive,
                                                          isDone:
                                                              _challengeVerified,
                                                          pulseValue:
                                                              _pulseController
                                                                  .value,
                                                        ),
                                                        _ShimmerLine(
                                                          isDone:
                                                              _challengeVerified,
                                                          isActive:
                                                              isLivenessActive,
                                                          pulseController:
                                                              _pulseController,
                                                        ),
                                                        _NeonChip(
                                                          label: 'Scanning',
                                                          isActive:
                                                              isScanningActive,
                                                          isDone:
                                                              _liveEmbeddings
                                                                  .length >=
                                                              _framesPerPhase,
                                                          pulseValue:
                                                              _pulseController
                                                                  .value,
                                                        ),
                                                        _ShimmerLine(
                                                          isDone:
                                                              _liveEmbeddings
                                                                  .length >=
                                                              _framesPerPhase,
                                                          isActive:
                                                              isScanningActive,
                                                          pulseController:
                                                              _pulseController,
                                                        ),
                                                        _NeonChip(
                                                          label: 'Done',
                                                          isActive:
                                                              _phase ==
                                                              _Phase.done,
                                                          isDone:
                                                              _phase ==
                                                              _Phase.done,
                                                          pulseValue:
                                                              _pulseController
                                                                  .value,
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                ),
                                              ),
                                            ),
                                          ),

                                        const SizedBox(height: 10),

                                        // 4. Instruction / Verification Card
                                        AnimatedScale(
                                          scale: 1.0,
                                          duration: const Duration(
                                            milliseconds: 300,
                                          ),
                                          curve: Curves.easeOutCubic,
                                          child: SlideTransition(
                                            position:
                                                Tween<Offset>(
                                                  begin: const Offset(0, 0.05),
                                                  end: const Offset(0, 0),
                                                ).animate(
                                                  CurvedAnimation(
                                                    parent: _textFadeController,
                                                    curve: Curves.easeOutCubic,
                                                  ),
                                                ),
                                            child: FadeTransition(
                                              opacity: _textFadeController,
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(18),
                                                child: BackdropFilter(
                                                  filter: ImageFilter.blur(
                                                    sigmaX:
                                                        _phase ==
                                                            _Phase.processing
                                                        ? 16
                                                        : 0,
                                                    sigmaY:
                                                        _phase ==
                                                            _Phase.processing
                                                        ? 16
                                                        : 0,
                                                  ),
                                                  child: AnimatedSize(
                                                    duration: const Duration(
                                                      milliseconds: 300,
                                                    ),
                                                    curve: Curves.easeOutCubic,
                                                    alignment:
                                                        Alignment.topCenter,
                                                    child: AnimatedContainer(
                                                      duration: const Duration(
                                                        milliseconds: 300,
                                                      ),
                                                      curve:
                                                          Curves.easeOutCubic,
                                                      decoration: BoxDecoration(
                                                        gradient:
                                                            _phase ==
                                                                _Phase
                                                                    .processing
                                                            ? LinearGradient(
                                                                begin: Alignment
                                                                    .topCenter,
                                                                end: Alignment
                                                                    .bottomCenter,
                                                                colors: [
                                                                  Colors.white
                                                                      .withValues(
                                                                        alpha:
                                                                            0.94,
                                                                      ),
                                                                  const Color(
                                                                    0xFFF8FAFC,
                                                                  ).withValues(
                                                                    alpha: 0.88,
                                                                  ),
                                                                ],
                                                              )
                                                            : null,
                                                        color:
                                                            _phase !=
                                                                _Phase
                                                                    .processing
                                                            ? Colors.white
                                                                  .withValues(
                                                                    alpha: 0.95,
                                                                  )
                                                            : null,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              18,
                                                            ),
                                                        border: Border.all(
                                                          color:
                                                              _phase ==
                                                                  _Phase
                                                                      .processing
                                                              ? const Color(
                                                                  0xFF38BDF8,
                                                                ).withValues(
                                                                  alpha: 0.42,
                                                                )
                                                              : (_phase ==
                                                                        _Phase
                                                                            .error
                                                                    ? AppStyles
                                                                          .errorRed
                                                                          .withValues(
                                                                            alpha:
                                                                                0.3,
                                                                          )
                                                                    : const Color(
                                                                        0xFFE2E8F0,
                                                                      )),
                                                          width:
                                                              _phase ==
                                                                  _Phase
                                                                      .processing
                                                              ? 1.3
                                                              : 1.2,
                                                        ),
                                                        boxShadow:
                                                            _phase ==
                                                                _Phase
                                                                    .processing
                                                            ? [
                                                                BoxShadow(
                                                                  color:
                                                                      const Color(
                                                                        0xFF0F172A,
                                                                      ).withValues(
                                                                        alpha:
                                                                            0.09,
                                                                      ),
                                                                  blurRadius:
                                                                      28,
                                                                  offset:
                                                                      const Offset(
                                                                        0,
                                                                        10,
                                                                      ),
                                                                ),
                                                                BoxShadow(
                                                                  color:
                                                                      const Color(
                                                                        0xFF0284C7,
                                                                      ).withValues(
                                                                        alpha:
                                                                            0.11,
                                                                      ),
                                                                  blurRadius:
                                                                      18,
                                                                  offset:
                                                                      const Offset(
                                                                        0,
                                                                        3,
                                                                      ),
                                                                  spreadRadius:
                                                                      -2,
                                                                ),
                                                                BoxShadow(
                                                                  color:
                                                                      const Color(
                                                                        0xFF38BDF8,
                                                                      ).withValues(
                                                                        alpha:
                                                                            0.16,
                                                                      ),
                                                                  blurRadius:
                                                                      10,
                                                                  offset:
                                                                      const Offset(
                                                                        0,
                                                                        1,
                                                                      ),
                                                                ),
                                                              ]
                                                            : [
                                                                BoxShadow(
                                                                  color: Colors
                                                                      .black
                                                                      .withValues(
                                                                        alpha:
                                                                            0.05,
                                                                      ),
                                                                  blurRadius:
                                                                      14,
                                                                  offset:
                                                                      const Offset(
                                                                        0,
                                                                        4,
                                                                      ),
                                                                ),
                                                              ],
                                                      ),
                                                      padding:
                                                              EdgeInsets.symmetric(
                                                                horizontal: 18,
                                                                vertical:
                                                                    _phase ==
                                                                            _Phase
                                                                                .processing
                                                                    ? 14
                                                                    : (_instructionTitle == 'Move to the center of the circle' ||
                                                                            _instructionTitle.contains('center of the circle')
                                                                        ? 9
                                                                        : 12),
                                                              ),
                                                          child: Builder(
                                                            builder: (context) {
                                                              final bool isCenterInstruction =
                                                                  _instructionTitle ==
                                                                          'Move to the center of the circle' ||
                                                                      _instructionTitle
                                                                          .contains(
                                                                            'center of the circle',
                                                                          );

                                                              return Column(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                mainAxisAlignment:
                                                                    MainAxisAlignment
                                                                        .center,
                                                                children: [
                                                                  // Challenge progress indicator
                                                                  if (_livenessPlan !=
                                                                          'blink_only' &&
                                                                      (_phase ==
                                                                              _Phase
                                                                                  .positioning ||
                                                                          _phase ==
                                                                              _Phase
                                                                                  .liveness)) ...[
                                                                    Padding(
                                                                      padding:
                                                                          EdgeInsets.only(
                                                                            bottom:
                                                                                isCenterInstruction
                                                                                    ? 6.0
                                                                                    : 8.0,
                                                                          ),
                                                                      child:
                                                                          _MiniChallengeProgressIndicator(
                                                                            livenessPlan:
                                                                                _livenessPlan,
                                                                            blinkDone:
                                                                                _blinkDone,
                                                                            turnDone:
                                                                                _turnDone,
                                                                            phase:
                                                                                _phase,
                                                                          ),
                                                                    ),
                                                                  ],
                                                                  AnimatedSwitcher(
                                                                    duration:
                                                                        const Duration(
                                                                          milliseconds:
                                                                              280,
                                                                        ),
                                                                    switchInCurve:
                                                                        Curves
                                                                            .easeOutCubic,
                                                                    switchOutCurve:
                                                                        Curves
                                                                            .easeInCubic,
                                                                    transitionBuilder: (
                                                                      child,
                                                                      animation,
                                                                    ) {
                                                                      return FadeTransition(
                                                                        opacity:
                                                                            animation,
                                                                        child:
                                                                            SlideTransition(
                                                                              position: Tween<
                                                                                Offset
                                                                              >(
                                                                                begin: const Offset(
                                                                                  0,
                                                                                  0.12,
                                                                                ),
                                                                                end:
                                                                                    Offset.zero,
                                                                              ).animate(
                                                                                animation,
                                                                              ),
                                                                              child:
                                                                                  child,
                                                                            ),
                                                                      );
                                                                    },
                                                                    child: Column(
                                                                      key: ValueKey<
                                                                        String
                                                                      >(
                                                                        '${_instructionTitle}_$_instructionSubtitle',
                                                                      ),
                                                                      mainAxisSize:
                                                                          MainAxisSize
                                                                              .min,
                                                                      children: [
                                                                        Text(
                                                                          _instructionTitle,
                                                                          textAlign:
                                                                              TextAlign
                                                                                  .center,
                                                                          style: TextStyle(
                                                                            fontSize:
                                                                                isCenterInstruction
                                                                                    ? 15.0
                                                                                    : 18.0,
                                                                            fontWeight:
                                                                                FontWeight
                                                                                    .w700,
                                                                            letterSpacing:
                                                                                isCenterInstruction
                                                                                    ? -0.2
                                                                                    : -0.35,
                                                                            height:
                                                                                isCenterInstruction
                                                                                    ? 1.2
                                                                                    : 1.25,
                                                                            color:
                                                                                _phase ==
                                                                                        _Phase.error
                                                                                    ? AppStyles
                                                                                        .errorRed
                                                                                    : AppStyles
                                                                                        .primaryBlue,
                                                                          ),
                                                                        ),
                                                                        if (_instructionSubtitle
                                                                            .isNotEmpty) ...[
                                                                          SizedBox(
                                                                            height:
                                                                                isCenterInstruction
                                                                                    ? 3.0
                                                                                    : 5.0,
                                                                          ),
                                                                          Text(
                                                                            _instructionSubtitle,
                                                                            textAlign:
                                                                                TextAlign
                                                                                    .center,
                                                                            style:
                                                                                TextStyle(
                                                                                  fontSize:
                                                                                      isCenterInstruction
                                                                                          ? 12.0
                                                                                          : 13.5,
                                                                                  color: const Color(
                                                                                    0xFF334155,
                                                                                  ),
                                                                                  fontWeight:
                                                                                      FontWeight
                                                                                          .w500,
                                                                                  height:
                                                                                      isCenterInstruction
                                                                                          ? 1.25
                                                                                          : 1.40,
                                                                                ),
                                                                          ),
                                                                        ],
                                                                      ],
                                                                    ),
                                                                  ),
                                                                  if (_phase ==
                                                                      _Phase
                                                                          .processing) ...[
                                                                    const SizedBox(
                                                                      height: 10,
                                                                    ),
                                                                    const _BiometricVerificationWidget(),
                                                                  ],
                                                                  if (_phase ==
                                                                      _Phase
                                                                          .error) ...[
                                                                    const SizedBox(
                                                                      height: 12,
                                                                    ),
                                                                    TextButton(
                                                                      onPressed:
                                                                          _onRetry,
                                                                      child: const Text(
                                                                        'Try Again',
                                                                        style: TextStyle(
                                                                          color: AppStyles
                                                                              .primaryBlue,
                                                                          fontWeight:
                                                                              FontWeight
                                                                                  .w600,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ],
                                                              );
                                                            },
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview(double containerWidth, [double circleTop = 0.0]) {
    if (!_cameraInitialized || _cameraController == null) {
      return const SizedBox.shrink();
    }

    final Size? previewSize = _cameraController!.value.previewSize;
    final double sensorW = previewSize?.height ?? 3.0;
    final double sensorH = previewSize?.width ?? 4.0;
    final double previewAspect = sensorW / sensorH;

    return SizedBox(
      width: containerWidth,
      height: containerWidth / previewAspect,
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: sensorW,
          height: sensorH,
          child: _cameraFrozen && _lastCapturedFrameBytes != null
              ? RotatedBox(
                  quarterTurns: 3,
                  child: Image.memory(
                    _lastCapturedFrameBytes!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                )
              : CameraPreview(
                  _cameraController!,
                  key: ValueKey('preview_$_cameraGeneration'),
                ),
        ),
      ),
    );
  }

  Widget _buildWarmupLoader(double circleSize) {
    return Container(
      key: const ValueKey('warmup_loader'),
      width: circleSize,
      height: circleSize,
      color: const Color(0xFFF0F4FF),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 100,
              height: 100,
              child: AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      CustomPaint(
                        size: const Size(100, 100),
                        painter: _OrbitRingsPainter(
                          rotation1: _pulseController.value * 2 * math.pi,
                          rotation2: -_pulseController.value * 2 * math.pi,
                          color: AppStyles.primaryBlue,
                        ),
                      ),
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppStyles.primaryBlue,
                          boxShadow: [
                            BoxShadow(
                              color: AppStyles.primaryBlue.withValues(
                                alpha: 0.3,
                              ),
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.camera_alt_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Preparing Camera…',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppStyles.primaryBlue,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'Initializing secure verification...',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: Color(0xFF64748B),
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// VISUAL & PAINTER HELPER COMPONENTS
// ─────────────────────────────────────────────────────────────────────────────

// ─── _MiniChallengeProgressIndicator — Precision connected component ─────────
class _MiniChallengeProgressIndicator extends StatelessWidget {
  final String livenessPlan;
  final bool blinkDone;
  final bool turnDone;
  final _Phase phase;

  const _MiniChallengeProgressIndicator({
    required this.livenessPlan,
    required this.blinkDone,
    required this.turnDone,
    required this.phase,
  });

  @override
  Widget build(BuildContext context) {
    final bool isLeft = livenessPlan == 'blink_left';
    final String secondLabel = isLeft ? 'Turn Left' : 'Turn Right';
    final IconData secondIcon = isLeft
        ? Icons.turn_left_rounded
        : Icons.turn_right_rounded;

    final bool isStep1Active =
        (phase == _Phase.positioning || phase == _Phase.liveness) && !blinkDone;
    final bool isStep2Active = blinkDone && !turnDone;

    const double indicatorWidth = 160.0;
    const double nodeDiameter = 24.0;

    return SizedBox(
      width: indicatorWidth,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background connector track
          Positioned(
            left: nodeDiameter,
            right: nodeDiameter,
            top: 10,
            child: Container(
              height: 4.0,
              decoration: BoxDecoration(
                color: const Color(0xFFE2E8F0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Animated foreground connector fill
          Positioned(
            left: nodeDiameter,
            right: nodeDiameter,
            top: 10,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0.0, end: blinkDone ? 1.0 : 0.0),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                  builder: (context, fillFraction, _) {
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: constraints.maxWidth * fillFraction,
                        height: 4.0,
                        decoration: BoxDecoration(
                          color: AppStyles.successGreen,
                          borderRadius: BorderRadius.circular(2),
                          boxShadow: fillFraction > 0
                              ? [
                                  BoxShadow(
                                    color: AppStyles.successGreen.withValues(
                                      alpha: 0.4,
                                    ),
                                    blurRadius: 4,
                                    offset: const Offset(0, 1),
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),

          // Challenge Step Nodes Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _ChallengeStepNode(
                label: 'Blink',
                icon: Icons.remove_red_eye_rounded,
                isDone: blinkDone,
                isActive: isStep1Active,
              ),
              _ChallengeStepNode(
                label: secondLabel,
                icon: secondIcon,
                isDone: turnDone,
                isActive: isStep2Active,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChallengeStepNode extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isDone;
  final bool isActive;

  const _ChallengeStepNode({
    required this.label,
    required this.icon,
    required this.isDone,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final double scale = isDone ? 1.05 : (isActive ? 1.02 : 1.0);

    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              gradient: isDone
                  ? const LinearGradient(
                      colors: [AppStyles.successGreen, Color(0xFF059669)],
                    )
                  : isActive
                  ? const LinearGradient(
                      colors: [AppStyles.primaryBlue, Color(0xFF2563EB)],
                    )
                  : null,
              color: (!isDone && !isActive) ? const Color(0xFFF8FAFC) : null,
              shape: BoxShape.circle,
              border: Border.all(
                color: isDone
                    ? AppStyles.successGreen
                    : isActive
                    ? AppStyles.primaryBlue
                    : const Color(0xFFCBD5E1),
                width: 1.5,
              ),
              boxShadow: isDone
                  ? [
                      BoxShadow(
                        color: AppStyles.successGreen.withValues(alpha: 0.3),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : isActive
                  ? [
                      BoxShadow(
                        color: AppStyles.primaryBlue.withValues(alpha: 0.35),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: Icon(
                isDone ? Icons.check_rounded : icon,
                size: 13,
                color: (isDone || isActive)
                    ? Colors.white
                    : const Color(0xFF94A3B8),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: (isDone || isActive)
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: isDone
                  ? AppStyles.successGreen
                  : isActive
                  ? AppStyles.primaryBlue
                  : AppStyles.textGray.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── _NeonChip — Stepper Chip ────────────────────────────────────────────────
class _NeonChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final bool isDone;
  final double pulseValue;

  const _NeonChip({
    required this.label,
    required this.isActive,
    required this.isDone,
    required this.pulseValue,
  });

  @override
  Widget build(BuildContext context) {
    if (isDone) {
      return AnimatedScale(
        scale: 1.0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7.5),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF059669), Color(0xFF047857)],
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF059669).withValues(alpha: 0.24),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11.5,
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      );
    }

    if (isActive) {
      return AnimatedScale(
        scale: 1.02,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7.5),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF2563EB).withValues(alpha: 0.28),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11.5,
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7.5),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.0),
      ),
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11.5,
            color: Color(0xFF64748B),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

// ─── _BiometricVerificationWidget ─────────────────────────────────────────────
class _BiometricVerificationWidget extends StatefulWidget {
  const _BiometricVerificationWidget();

  @override
  State<_BiometricVerificationWidget> createState() =>
      _BiometricVerificationWidgetState();
}

class _BiometricVerificationWidgetState
    extends State<_BiometricVerificationWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _rotationController;
  int _messageIndex = 0;
  Timer? _messageTimer;
  late DateTime _startTime;

  static const List<String> _verificationMessages = [
    'Comparing facial landmarks…',
    'Analyzing live biometric data…',
    'Matching secure face profile…',
    'Please wait…',
  ];

  @override
  void initState() {
    super.initState();
    _startTime = DateTime.now();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();

    _messageTimer = Timer.periodic(const Duration(milliseconds: 1600), (timer) {
      if (mounted) {
        setState(() {
          _messageIndex = (_messageIndex + 1) % _verificationMessages.length;
        });
      }
    });
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _rotationController,
          builder: (context, child) {
            final double t = _rotationController.value;
            final double pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
            final double haloScale = 0.95 + 0.08 * pulse;

            final elapsedMs = DateTime.now()
                .difference(_startTime)
                .inMilliseconds;
            final double stageProgress = ((elapsedMs % 1600) / 1600.0).clamp(
              0.0,
              1.0,
            );

            // Smooth progressive confidence count-up (48.0% -> 99.8%)
            const baseByStage = [48.0, 74.2, 89.6, 97.4];
            const targetByStage = [74.2, 89.6, 97.4, 99.8];
            final currentStage = _messageIndex.clamp(0, 3);
            final base = baseByStage[currentStage];
            final target = targetByStage[currentStage];
            final curvedStage = Curves.easeOutCubic.transform(stageProgress);
            final double confidence = (base + (target - base) * curvedStage)
                .clamp(48.0, 99.8);

            return Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: Center(
                    child: Transform.scale(
                      scale: haloScale,
                      child: Container(
                        width: 154,
                        height: 56,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          gradient: RadialGradient(
                            colors: [
                              const Color(
                                0xFF0284C7,
                              ).withValues(alpha: 0.20 + 0.08 * pulse),
                              const Color(
                                0xFF38BDF8,
                              ).withValues(alpha: 0.10 + 0.05 * pulse),
                              const Color(
                                0xFF818CF8,
                              ).withValues(alpha: 0.04 + 0.02 * pulse),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.42, 0.72, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    ShaderMask(
                      shaderCallback: (Rect bounds) {
                        return const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFF0284C7),
                            Color(0xFF1D4ED8),
                            Color(0xFF0F172A),
                          ],
                          stops: [0.0, 0.58, 1.0],
                        ).createShader(bounds);
                      },
                      blendMode: BlendMode.srcIn,
                      child: Text(
                        confidence.toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.2,
                          color: Colors.white,
                          height: 1.0,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 2.5),
                    ShaderMask(
                      shaderCallback: (Rect bounds) {
                        return const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFF0284C7), Color(0xFF2563EB)],
                        ).createShader(bounds);
                      },
                      blendMode: BlendMode.srcIn,
                      child: const Text(
                        '%',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                          color: Colors.white,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.15),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            );
          },
          child: Text(
            _verificationMessages[_messageIndex],
            key: ValueKey<int>(_messageIndex),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF0284C7),
              letterSpacing: -0.1,
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── _ShimmerLine — Status Stepper Connector ─────────────────────────────────
class _ShimmerLine extends StatelessWidget {
  final bool isDone;
  final bool isActive;
  final AnimationController pulseController;

  const _ShimmerLine({
    required this.isDone,
    this.isActive = false,
    required this.pulseController,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AnimatedBuilder(
        animation: pulseController,
        builder: (context, _) {
          final double pulse = pulseController.value;

          return AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            height: isActive ? 3.5 : (isDone ? 3.2 : 2.5),
            margin: EdgeInsets.zero,
            decoration: BoxDecoration(
              color: isDone
                  ? null
                  : (!isActive ? const Color(0xFFE2E8F0) : null),
              gradient: isDone
                  ? const LinearGradient(
                      colors: [Color(0xFF059669), Color(0xFF10B981)],
                    )
                  : (isActive
                        ? LinearGradient(
                            begin: Alignment(-1.0 + 2.0 * pulse, 0.0),
                            end: Alignment(1.0 + 2.0 * pulse, 0.0),
                            colors: const [
                              Color(0xFF2563EB),
                              Color(0xFF60A5FA),
                              Color(0xFF93C5FD),
                              Color(0xFF2563EB),
                            ],
                            stops: const [0.0, 0.35, 0.7, 1.0],
                          )
                        : null),
              borderRadius: BorderRadius.circular(2.0),
              boxShadow: isDone
                  ? [
                      BoxShadow(
                        color: const Color(0xFF059669).withValues(alpha: 0.35),
                        blurRadius: 6,
                        offset: const Offset(0, 1),
                      ),
                      BoxShadow(
                        color: const Color(0xFF10B981).withValues(alpha: 0.20),
                        blurRadius: 3,
                        offset: Offset.zero,
                      ),
                    ]
                  : (isActive
                        ? [
                            BoxShadow(
                              color: const Color(
                                0xFF2563EB,
                              ).withValues(alpha: 0.35 + (0.30 * pulse)),
                              blurRadius: 8 + (4 * pulse),
                              offset: const Offset(0, 1.5),
                            ),
                            BoxShadow(
                              color: const Color(
                                0xFF60A5FA,
                              ).withValues(alpha: 0.25 + (0.20 * pulse)),
                              blurRadius: 4,
                              offset: Offset.zero,
                            ),
                          ]
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 2,
                              offset: const Offset(0, 0.5),
                            ),
                          ]),
            ),
          );
        },
      ),
    );
  }
}

// ─── _OrbitRingsPainter ──────────────────────────────────────────────────────
class _OrbitRingsPainter extends CustomPainter {
  final double rotation1;
  final double rotation2;
  final Color color;

  _OrbitRingsPainter({
    required this.rotation1,
    required this.rotation2,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final outerRect = Rect.fromCircle(center: center, radius: 42);
    final outerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [color, color.withValues(alpha: 0.1), color],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(outerRect);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation1);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawArc(outerRect, 0, math.pi * 0.7, false, outerPaint);
    canvas.drawArc(outerRect, math.pi, math.pi * 0.7, false, outerPaint);
    canvas.restore();

    final innerRect = Rect.fromCircle(center: center, radius: 34);
    final innerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0.8),
          color.withValues(alpha: 0.05),
          color.withValues(alpha: 0.8),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(innerRect);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation2);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawArc(innerRect, 0, math.pi * 0.4, false, innerPaint);
    canvas.drawArc(
      innerRect,
      math.pi * 2 / 3,
      math.pi * 0.4,
      false,
      innerPaint,
    );
    canvas.drawArc(
      innerRect,
      math.pi * 4 / 3,
      math.pi * 0.4,
      false,
      innerPaint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OrbitRingsPainter oldDelegate) {
    return oldDelegate.rotation1 != rotation1 ||
        oldDelegate.rotation2 != rotation2 ||
        oldDelegate.color != color;
  }
}

// ─── _FillLightPainter ────────────────────────────────────────────────────────
class _FillLightPainter extends CustomPainter {
  final Offset circleCenter;
  final double circleRadius;

  _FillLightPainter({required this.circleCenter, required this.circleRadius});

  @override
  void paint(Canvas canvas, Size size) {
    final Path backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final Path circlePath = Path()
      ..addOval(Rect.fromCircle(center: circleCenter, radius: circleRadius));
    final Path fillPath = Path.combine(
      PathOperation.difference,
      backgroundPath,
      circlePath,
    );

    final Paint paint = Paint()
      ..shader = RadialGradient(
        center: Alignment(
          (circleCenter.dx / size.width) * 2 - 1,
          (circleCenter.dy / size.height) * 2 - 1,
        ),
        radius: 1.2,
        colors: [
          Colors.white,
          const Color(0xFFE2F0FD),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.2, 0.6, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawPath(fillPath, paint);
  }

  @override
  bool shouldRepaint(covariant _FillLightPainter oldDelegate) {
    return oldDelegate.circleCenter != circleCenter ||
        oldDelegate.circleRadius != circleRadius;
  }
}

// ─── _BorderPainter ───────────────────────────────────────────────────────────
class _BorderPainter extends CustomPainter {
  final double pulseValue;
  final Color baseColor;
  final double progress;
  final _Phase phase;
  final double flowValue;

  _BorderPainter({
    required this.pulseValue,
    required this.baseColor,
    required this.progress,
    required this.phase,
    required this.flowValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = size.width / 2;
    final Offset center = Offset(radius, radius);
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    // 1. Multi-layered Ambient Breathing Radial Glow
    if (phase != _Phase.processing && phase != _Phase.done) {
      final double glowSpread = 8.0 + (16.0 * pulseValue);
      final double outerHaloRadius = radius + glowSpread;

      // Layer A: Wide diffused outer radial gradient aura
      final Paint outerGlowPaint = Paint()
        ..shader =
            RadialGradient(
              colors: [
                baseColor.withValues(alpha: 0.0),
                baseColor.withValues(alpha: 0.18 * (0.6 + 0.4 * pulseValue)),
                baseColor.withValues(alpha: 0.08 * (1.0 - pulseValue * 0.3)),
                baseColor.withValues(alpha: 0.0),
              ],
              stops: [
                math.max(0.0, (radius - 12.0) / outerHaloRadius),
                radius / outerHaloRadius,
                (radius + glowSpread * 0.6) / outerHaloRadius,
                1.0,
              ],
            ).createShader(
              Rect.fromCircle(center: center, radius: outerHaloRadius),
            );

      canvas.drawCircle(center, outerHaloRadius, outerGlowPaint);

      // Layer B: Mid-range soft blurred glow ring
      final midGlowPaint = Paint()
        ..color = baseColor.withValues(alpha: 0.22 + (0.28 * pulseValue))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10.0 + (6.0 * pulseValue)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          10.0 + (8.0 * pulseValue),
        );

      canvas.drawCircle(center, radius, midGlowPaint);

      // Layer C: Core energetic neon bloom
      final coreGlowPaint = Paint()
        ..color = baseColor.withValues(alpha: 0.40 + (0.35 * pulseValue))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.0
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          4.0 + (3.0 * pulseValue),
        );

      canvas.drawCircle(center, radius, coreGlowPaint);

      // Layer D: Subtle orbital accent sheen
      final accentGlowPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.35 * pulseValue)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);

      final glowAngle = pulseValue * 2 * math.pi;
      canvas.drawArc(rect, glowAngle, 0.5, false, accentGlowPaint);
    } else {
      // Subtle ambient shadow when processing or done
      final shadowPaint = Paint()
        ..color = baseColor.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(center, radius, shadowPaint);

      // Rich emerald aura when verified successfully
      if (phase == _Phase.done) {
        final successAuraPaint = Paint()
          ..color = baseColor.withValues(alpha: 0.42)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);
        canvas.drawCircle(center, radius, successAuraPaint);

        final successCorePaint = Paint()
          ..color = const Color(0xFF34D399).withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
        canvas.drawCircle(center, radius, successCorePaint);
      }
    }

    // 2. Base crisp circle border
    final paint = Paint()
      ..color = baseColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5;

    canvas.drawCircle(center, radius, paint);

    // 3. Progress ring (during capture)
    if (progress > 0) {
      const Color progressColor = Color(0xFF2ECC71);
      final progressGlow = Paint()
        ..color = progressColor.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12.0
        ..strokeCap = StrokeCap.butt
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);

      final progressPaint = Paint()
        ..color = progressColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8.0
        ..strokeCap = StrokeCap.butt;

      final sweepAngle = 2 * math.pi * progress;
      canvas.drawArc(rect, -math.pi / 2, sweepAngle, false, progressGlow);
      canvas.drawArc(rect, -math.pi / 2, sweepAngle, false, progressPaint);
    }

    // 4. Specular 3D highlight & subtle rim shadow for depth
    final Paint topHighlightPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    final Paint bottomShadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, -math.pi * 0.85, 1.57, false, topHighlightPaint);
    canvas.drawArc(rect, math.pi * 0.15, 1.57, false, bottomShadowPaint);
  }

  @override
  bool shouldRepaint(covariant _BorderPainter oldDelegate) {
    return oldDelegate.pulseValue != pulseValue ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.progress != progress ||
        oldDelegate.phase != phase ||
        oldDelegate.flowValue != flowValue;
  }
}

// ─── _ParticleBurstPainter ────────────────────────────────────────────────────
class _ParticleBurstPainter extends CustomPainter {
  final double progress;

  _ParticleBurstPainter(this.progress);

  static final List<_BurstParticle> _particles = _initParticles();

  static List<_BurstParticle> _initParticles() {
    final random = math.Random(777);
    final list = <_BurstParticle>[];
    const total = 46;
    for (int i = 0; i < total; i++) {
      final baseAngle = (i / total) * 2 * math.pi;
      final angleJitter = (random.nextDouble() - 0.5) * 0.25;
      final angle = baseAngle + angleJitter;

      // 0: streak, 1: glowing dot, 2: sparkle
      final int type = (i % 3 == 0) ? 0 : ((i % 3 == 1) ? 1 : 2);

      final double speed;
      final double size;
      final Color color;

      if (type == 0) {
        speed = 130.0 + random.nextDouble() * 95.0;
        size = 2.2 + random.nextDouble() * 1.4;
        color = (random.nextDouble() > 0.4)
            ? const Color(0xFF10B981)
            : (random.nextDouble() > 0.5
                  ? const Color(0xFF34D399)
                  : const Color(0xFF38BDF8));
      } else if (type == 1) {
        speed = 65.0 + random.nextDouble() * 70.0;
        size = 2.0 + random.nextDouble() * 1.8;
        color = (random.nextDouble() > 0.3)
            ? const Color(0xFF34D399)
            : const Color(0xFFFFFFFF);
      } else {
        speed = 30.0 + random.nextDouble() * 40.0;
        size = 1.2 + random.nextDouble() * 1.2;
        color = (random.nextDouble() > 0.4)
            ? const Color(0xFFFDE047)
            : const Color(0xFF38BDF8);
      }

      list.add(
        _BurstParticle(
          angle: angle,
          speed: speed,
          size: size,
          type: type,
          color: color,
          seed: random.nextDouble(),
        ),
      );
    }
    return list;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.0 || progress >= 1.0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.width / 2;

    const ringCutoff = 0.60;
    if (progress < ringCutoff) {
      final ringNorm = progress / ringCutoff;
      final ringCurved = Curves.easeOutCubic.transform(ringNorm);
      final ringRadius = baseRadius + 34.0 * ringCurved;
      final ringFade = (1.0 - ringCurved);

      final ringAuraPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0 * ringFade
        ..color = const Color(0xFF38BDF8).withValues(alpha: 0.28 * ringFade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);
      canvas.drawCircle(center, ringRadius, ringAuraPaint);

      final ringCorePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0 * ringFade
        ..color = const Color(0xFF10B981).withValues(alpha: 0.75 * ringFade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
      canvas.drawCircle(center, ringRadius, ringCorePaint);

      final ringLinePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * ringFade
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.85 * ringFade);
      canvas.drawCircle(center, ringRadius, ringLinePaint);
    }

    final curvedProgress = Curves.easeOutCubic.transform(progress);

    final double masterAlpha;
    if (progress < 0.12) {
      masterAlpha = (progress / 0.12).clamp(0.0, 1.0);
    } else {
      masterAlpha = ((1.0 - progress) / 0.88).clamp(0.0, 1.0);
    }

    for (final p in _particles) {
      final dir = Offset(math.cos(p.angle), math.sin(p.angle));
      final currentDist = baseRadius + p.speed * curvedProgress;
      final pPos = center + dir * currentDist;

      if (p.type == 0) {
        final streakLen = (9.0 + (p.speed * 0.08)) * (1.0 - progress * 0.35);
        final pTail = pPos - dir * streakLen;

        final streakPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = p.size
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.95 * masterAlpha),
              p.color.withValues(alpha: 0.70 * masterAlpha),
              p.color.withValues(alpha: 0.0),
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(Rect.fromPoints(pTail, pPos));

        canvas.drawLine(pTail, pPos, streakPaint);

        final headPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.white.withValues(alpha: 0.90 * masterAlpha);
        canvas.drawCircle(pPos, p.size * 0.7, headPaint);
      } else if (p.type == 1) {
        final haloPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = p.color.withValues(alpha: 0.35 * masterAlpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
        canvas.drawCircle(pPos, p.size * 2.2, haloPaint);

        final corePaint = Paint()
          ..style = PaintingStyle.fill
          ..color = Color.lerp(
            p.color,
            Colors.white,
            0.45,
          )!.withValues(alpha: 0.95 * masterAlpha);
        canvas.drawCircle(pPos, p.size, corePaint);
      } else {
        final twinkle =
            0.6 + 0.4 * math.sin(progress * 12 * math.pi + p.seed * 6.28);
        final sparkAlpha = (masterAlpha * twinkle).clamp(0.0, 1.0);

        final sparkHalo = Paint()
          ..style = PaintingStyle.fill
          ..color = p.color.withValues(alpha: 0.45 * sparkAlpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0);
        canvas.drawCircle(pPos, p.size * 1.8, sparkHalo);

        final sparkCore = Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.white.withValues(alpha: 0.95 * sparkAlpha);
        canvas.drawCircle(pPos, p.size * 0.8, sparkCore);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ParticleBurstPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class _BurstParticle {
  final double angle;
  final double speed;
  final double size;
  final int type;
  final Color color;
  final double seed;

  const _BurstParticle({
    required this.angle,
    required this.speed,
    required this.size,
    required this.type,
    required this.color,
    required this.seed,
  });
}

// ─── _MiniRingPainter — Countdown Ring ───────────────────────────────────────
class _MiniRingPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _MiniRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 6) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = AppStyles.primaryBlue.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi, false, trackPaint);

    if (progress > 0) {
      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);

      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        glowPaint,
      );

      final arcPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        arcPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MiniRingPainter old) =>
      old.progress != progress || old.color != color;
}

// ─── _FaceVerificationAmbientBackground ───────────────────────────────────────
class _FaceVerificationAmbientBackground extends StatelessWidget {
  final double pulseValue;

  const _FaceVerificationAmbientBackground({required this.pulseValue});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomPaint(
        painter: _FaceVerificationAmbientBackgroundPainter(
          pulseValue: pulseValue,
        ),
        size: Size.infinite,
      ),
    );
  }
}

// ─── _FaceVerificationAmbientBackgroundPainter ───────────────────────────────
class _FaceVerificationAmbientBackgroundPainter extends CustomPainter {
  final double pulseValue;

  _FaceVerificationAmbientBackgroundPainter({required this.pulseValue});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final double breathe = math.sin(pulseValue * math.pi * 2) * 0.04;

    // ── Layer 1: Base Biometric Gradient ──
    final bgRect = Rect.fromLTWH(0, 0, w, h);
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFFFFFFFF),
          Color(0xFFF3F8FE),
          Color(0xFFE5F1FC),
          Color(0xFFDAEAF9),
        ],
        stops: [0.0, 0.22, 0.65, 1.0],
      ).createShader(bgRect);
    canvas.drawRect(bgRect, bgPaint);

    // ── Layer 2: Ambient Radial Glow Fields ──
    final centerPos = Offset(w * 0.50, h * 0.28);
    final centerRadius = w * 0.62 + breathe * 20.0;
    final centerPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(
            0xFF38BDF8,
          ).withValues(alpha: (0.24 + breathe * 0.05).clamp(0.0, 1.0)),
          const Color(
            0xFF60A5FA,
          ).withValues(alpha: (0.13 + breathe * 0.03).clamp(0.0, 1.0)),
          const Color(
            0xFF3B82F6,
          ).withValues(alpha: (0.04 + breathe * 0.02).clamp(0.0, 1.0)),
          Colors.transparent,
        ],
        stops: const [0.0, 0.40, 0.72, 1.0],
      ).createShader(Rect.fromCircle(center: centerPos, radius: centerRadius));
    canvas.drawCircle(centerPos, centerRadius, centerPaint);

    final trCenter = Offset(w * 0.88, h * 0.10);
    final trRadius = w * 0.65;
    final trPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(
            0xFF38BDF8,
          ).withValues(alpha: (0.18 + breathe * 0.03).clamp(0.0, 1.0)),
          const Color(
            0xFF60A5FA,
          ).withValues(alpha: (0.08 + breathe * 0.02).clamp(0.0, 1.0)),
          Colors.transparent,
        ],
        stops: const [0.0, 0.50, 1.0],
      ).createShader(Rect.fromCircle(center: trCenter, radius: trRadius));
    canvas.drawCircle(trCenter, trRadius, trPaint);

    final blCenter = Offset(w * 0.12, h * 0.80);
    final blRadius = w * 0.70;
    final blPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(
            0xFF3B82F6,
          ).withValues(alpha: (0.16 + (0.04 - breathe) * 0.03).clamp(0.0, 1.0)),
          const Color(
            0xFF818CF8,
          ).withValues(alpha: (0.10 + (0.04 - breathe) * 0.02).clamp(0.0, 1.0)),
          Colors.transparent,
        ],
        stops: const [0.0, 0.52, 1.0],
      ).createShader(Rect.fromCircle(center: blCenter, radius: blRadius));
    canvas.drawCircle(blCenter, blRadius, blPaint);

    final brCenter = Offset(w * 0.86, h * 0.75);
    final brRadius = w * 0.52;
    final brPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(
            0xFF00B4D8,
          ).withValues(alpha: (0.11 + breathe * 0.025).clamp(0.0, 1.0)),
          Colors.transparent,
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: brCenter, radius: brRadius));
    canvas.drawCircle(brCenter, brRadius, brPaint);

    // ── Layer 3: Expanding Biometric Radiating Rings ──
    final ringBasePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < 3; i++) {
      final ringProgress = (pulseValue + i * 0.333) % 1.0;
      final easeProgress = Curves.easeOut.transform(ringProgress);
      final ringRadius = w * 0.30 + easeProgress * (w * 0.48);
      final ringAlpha = ((1.0 - easeProgress) * (0.16 + breathe * 0.04)).clamp(
        0.0,
        1.0,
      );

      if (ringAlpha > 0.01) {
        ringBasePaint
          ..strokeWidth = 1.2 * (1.0 - easeProgress * 0.3)
          ..color = const Color(0xFF38BDF8).withValues(alpha: ringAlpha);
        canvas.drawCircle(centerPos, ringRadius, ringBasePaint);
      }
    }

    // ── Layer 4: Subtle Biometric Wave Ribbons ──
    final wave1Paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(
        0xFF38BDF8,
      ).withValues(alpha: (0.12 + breathe * 0.04).clamp(0.0, 1.0));

    final wave1Path = Path();
    final y1 = h * 0.28 + breathe * 110.0;
    wave1Path.moveTo(0, y1);
    wave1Path.cubicTo(
      w * 0.30,
      y1 - 18.0 * math.cos(pulseValue * math.pi * 2),
      w * 0.70,
      y1 + 16.0 * math.sin(pulseValue * math.pi * 2),
      w,
      y1 - 8.0 * math.cos(pulseValue * math.pi * 2),
    );
    canvas.drawPath(wave1Path, wave1Paint);

    final wave2Paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(
        0xFF3B82F6,
      ).withValues(alpha: (0.10 + (0.04 - breathe) * 0.03).clamp(0.0, 1.0));

    final wave2Path = Path();
    final y2 = h * 0.62 - breathe * 90.0;
    wave2Path.moveTo(0, y2);
    wave2Path.cubicTo(
      w * 0.32,
      y2 + 16.0 * math.sin(pulseValue * math.pi * 2),
      w * 0.68,
      y2 - 14.0 * math.cos(pulseValue * math.pi * 2),
      w,
      y2 + 10.0 * math.sin(pulseValue * math.pi * 2),
    );
    canvas.drawPath(wave2Path, wave2Paint);

    final wave3Paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = const Color(
        0xFF818CF8,
      ).withValues(alpha: (0.08 + breathe * 0.02).clamp(0.0, 1.0));

    final wave3Path = Path();
    final y3 = h * 0.78 + breathe * 70.0;
    wave3Path.moveTo(0, y3);
    wave3Path.cubicTo(
      w * 0.28,
      y3 - 12.0 * math.sin(pulseValue * math.pi * 2),
      w * 0.72,
      y3 + 14.0 * math.cos(pulseValue * math.pi * 2),
      w,
      y3 - 6.0 * math.sin(pulseValue * math.pi * 2),
    );
    canvas.drawPath(wave3Path, wave3Paint);

    // ── Layer 5: Subtle Floating Biometric Particles ──
    final particlePaint = Paint()..style = PaintingStyle.fill;
    final particleHaloPaint = Paint()..style = PaintingStyle.fill;

    final particles = [
      Offset(w * 0.15, h * 0.20),
      Offset(w * 0.84, h * 0.24),
      Offset(w * 0.12, h * 0.44),
      Offset(w * 0.88, h * 0.48),
      Offset(w * 0.22, h * 0.68),
      Offset(w * 0.78, h * 0.72),
      Offset(w * 0.45, h * 0.86),
    ];

    for (int i = 0; i < particles.length; i++) {
      final base = particles[i];
      final driftX = 6.0 * math.sin(pulseValue * 2 * math.pi + i * 1.1);
      final driftY =
          -14.0 * (((pulseValue + i * 0.14) % 1.0) - 0.5) + breathe * 40.0;
      final pos = Offset(base.dx + driftX, base.dy + driftY);

      final alpha = (0.14 + 0.08 * math.sin(pulseValue * 2 * math.pi + i * 0.9))
          .clamp(0.0, 1.0);

      particleHaloPaint.color = const Color(
        0xFF38BDF8,
      ).withValues(alpha: alpha * 0.35);
      canvas.drawCircle(pos, 4.0, particleHaloPaint);

      particlePaint.color = const Color(0xFF38BDF8).withValues(alpha: alpha);
      canvas.drawCircle(pos, 1.6, particlePaint);
    }
  }

  @override
  bool shouldRepaint(
    covariant _FaceVerificationAmbientBackgroundPainter oldDelegate,
  ) => oldDelegate.pulseValue != pulseValue;
}
