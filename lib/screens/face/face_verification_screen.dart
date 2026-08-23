// lib/screens/face/face_verification_screen.dart
//
// Face verification screen — captures 5 front frames after liveness check,
// generates embeddings and compares against stored profile.

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
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/face_ml_service.dart';
import '../../services/face_landmark_service.dart';
import '../../utils/app_styles.dart';
import '../../utils/auth_flow_state.dart';
import '../../utils/camera_stabilizer.dart';

// ─── Verification phases ──────────────────────────────────────────────────────
enum _Phase {
  initializing,
  positioning, // face centering + steady check
  liveness, // blink challenge
  capturing, // capturing 5 front frames
  processing, // running embeddings + comparing
  done,
  error,
}

enum _LocationPhase { checking, verified, docking, docked, failed }

enum _LocationErrorType {
  disabled,
  permissionDenied,
  outsideArea,
  mockDetected,
  gpsTimeout,
  networkError,
}

class _LocationErrorInfo {
  final IconData icon;
  final String title;
  final String description;
  final String? subtext;
  final String primaryButtonText;
  final IconData primaryButtonIcon;
  final List<Color> gradientColors;
  final Color glowColor;
  final Color shadowColor;

  const _LocationErrorInfo({
    required this.icon,
    required this.title,
    required this.description,
    this.subtext,
    required this.primaryButtonText,
    required this.primaryButtonIcon,
    required this.gradientColors,
    required this.glowColor,
    required this.shadowColor,
  });
}

class FaceVerificationScreen extends StatefulWidget {
  const FaceVerificationScreen({super.key});

  @override
  State<FaceVerificationScreen> createState() => _FaceVerificationScreenState();
}

class _FaceVerificationScreenState extends State<FaceVerificationScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // ─── Session ID & Timings ────────────────────────────────────────────────
  late final String _sessionId;
  final Stopwatch _captureStopwatch = Stopwatch();
  final Stopwatch _apiStopwatch = Stopwatch();
  final Stopwatch _comparisonStopwatch = Stopwatch();
  final Stopwatch _totalStopwatch = Stopwatch();
  final List<Map<String, double>> _allFramesStats = [];

  // ─── Animation controllers ──────────────────────────────────────────────
  late AnimationController _pulseController;
  late AnimationController _textFadeController;
  late AnimationController _blinkCountdownController;
  late AnimationController _successBounceController;
  late AnimationController _particleController;

  // ─── Location & Docking animation state ──────────────────────────────────
  _LocationPhase _locationPhase = _LocationPhase.checking;
  _LocationErrorType? _locationErrorType;
  late AnimationController _locationAnimController;
  late AnimationController _locationSuccessController;
  late AnimationController _locationDockController;
  bool _locationVerified = false;
  bool get isLocationVerified => _locationVerified;

  // ─── Subtitle progressive state ──────────────────────────────────────────
  int _locationSubtitleStep = 0;
  Timer? _locationSubtitleTimer3s;
  Timer? _locationSubtitleTimer6s;
  Timer? _locationSubtitleTimer10s;

  void _startLocationSubtitleTimers() {
    _stopLocationSubtitleTimers();
    _locationSubtitleStep = 0;

    _locationSubtitleTimer3s = Timer(const Duration(seconds: 3), () {
      if (mounted && _locationPhase == _LocationPhase.checking) {
        setState(() {
          _locationSubtitleStep = 1;
        });
      }
    });

    _locationSubtitleTimer6s = Timer(const Duration(seconds: 6), () {
      if (mounted && _locationPhase == _LocationPhase.checking) {
        setState(() {
          _locationSubtitleStep = 2;
        });
      }
    });

    _locationSubtitleTimer10s = Timer(const Duration(seconds: 10), () {
      if (mounted && _locationPhase == _LocationPhase.checking) {
        setState(() {
          _locationSubtitleStep = 3;
        });
      }
    });
  }

  void _stopLocationSubtitleTimers() {
    _locationSubtitleTimer3s?.cancel();
    _locationSubtitleTimer6s?.cancel();
    _locationSubtitleTimer10s?.cancel();
    _locationSubtitleTimer3s = null;
    _locationSubtitleTimer6s = null;
    _locationSubtitleTimer10s = null;
  }

  String _getLocationSubtitleText() {
    if (_locationPhase == _LocationPhase.verified ||
        _locationPhase == _LocationPhase.docking) {
      return 'Preparing secure face verification…';
    }
    switch (_locationSubtitleStep) {
      case 1:
        return "We're securely checking whether you're inside the campus attendance area.";
      case 2:
        return "This is taking a little longer than expected.\n\nPlease make sure GPS is enabled and your internet connection is available.";
      case 3:
        return "Still verifying your location...\n\nPlease keep this screen open while we complete the security check.";
      case 0:
      default:
        return "Please wait while we verify your attendance area.";
    }
  }

  // ─── Timer ring ─────────────────────────────────────────────────────────
  late AnimationController _timerPulseController;
  late AnimationController _ringController;
  late Animation<double> _ringProgress;
  static const int _totalSeconds = 60;
  int _secondsRemaining = _totalSeconds;
  Timer? _countdownTimer;

  // ─── Camera ─────────────────────────────────────────────────────────────
  CameraController? _cameraController;
  bool _cameraInitialized = false;
  bool _cameraPreviewReady = false;

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
  // Stores raw JPEG bytes during capture phase for batch processing
  final List<Uint8List> _capturedVerificationFrames = [];
  final List<Map<String, double>> _capturedVerificationFramesStats = [];
  late CameraStabilizer _cameraStabilizer;
  Face? _lastProcessedFace;
  int _nextCaptureInterval = 300;
  static const int _framesPerPhase = 5;

  // New state variables for valid frame counting, camera freeze, and processing overlays
  final List<BatchEmbeddingResult> _validResults = [];
  int _validFrameCount = 0;
  bool _cameraFrozen = false;
  Uint8List? _lastCapturedFrameBytes;
  bool _isSubmitting = false;
  bool _meteringApplied = false;
  int _stabilityRejectCount = 0;

  String _livenessPlan = 'blink_only';
  bool _blinkDone = false;
  bool _turnDone = false;
  DateTime? _turnStartTime;

  List<List<double>>? _storedTemplates;
  double _verificationThreshold = 0.68;

  final int _attemptCount = 1;

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

  DateTime _lastExposureAdjustTime = DateTime.fromMillisecondsSinceEpoch(0);

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
    "Calibrating…": "Look straight at the camera and hold still",
    "Blink to verify": "Blink naturally to confirm you are present",
    "Blink 2-3 times": "Blink naturally 2 to 3 times",
    "Capturing 1/5": "Hold still, scanning your face",
    "Capturing 2/5": "Hold still, scanning your face",
    "Capturing 3/5": "Hold still, scanning your face",
    "Capturing 4/5": "Hold still, scanning your face",
    "Capturing 5/5": "Almost done",
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

  @override
  void initState() {
    super.initState();

    // ── Animation setup ────────────────────────────────────────────────────
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _textFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..forward();

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

    _locationAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _locationSuccessController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _locationDockController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );

    // Timer pulse every second
    _timerPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
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

    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _verifyLocation();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_locationPhase == _LocationPhase.failed) {
        _recoverLocationOnResume();
      }
    }
  }

  Future<void> _recoverLocationOnResume() async {
    if (!mounted || _locationPhase != _LocationPhase.failed) return;
    try {
      final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (serviceEnabled) {
        final LocationPermission permission =
            await Geolocator.checkPermission();
        if (permission != LocationPermission.denied &&
            permission != LocationPermission.deniedForever) {
          _verifyLocation();
        } else if (_locationErrorType == _LocationErrorType.disabled) {
          _verifyLocation();
        }
      }
    } catch (_) {}
  }

  Future<void> _verifyLocation() async {
    // Read mode from route arguments
    final String? mode = ModalRoute.of(context)?.settings.arguments as String?;
    final bool isPasswordReset = mode == 'password_reset';

    if (isPasswordReset) {
      // Skip location check for password reset — student can be anywhere
      setState(() {
        _locationVerified = true;
        _locationPhase = _LocationPhase.docked;
        _locationDockController.value = 1.0;
      });
      await _initializeCamera();
      return;
    }

    setState(() {
      _locationPhase = _LocationPhase.checking;
      _locationErrorType = null;
    });

    if (!_locationAnimController.isAnimating) {
      _locationAnimController.repeat();
    }

    final DateTime locStartTime = DateTime.now();
    _startLocationSubtitleTimers();

    final String locationResult = await _checkGeofence();
    if (!mounted) return;

    _stopLocationSubtitleTimers();

    // Minimum animation visibility: 700-900ms (we use 800ms)
    final int elapsedMs = DateTime.now()
        .difference(locStartTime)
        .inMilliseconds;
    const int minAnimationDurationMs = 800;
    if (elapsedMs < minAnimationDurationMs && locationResult == 'ok') {
      await Future.delayed(
        Duration(milliseconds: minAnimationDurationMs - elapsedMs),
      );
      if (!mounted) return;
    }

    if (locationResult != 'ok') {
      _LocationErrorType errorType;
      switch (locationResult) {
        case 'off':
          errorType = _LocationErrorType.disabled;
          break;
        case 'permission_denied':
          errorType = _LocationErrorType.permissionDenied;
          break;
        case 'mock':
          errorType = _LocationErrorType.mockDetected;
          break;
        case 'outside':
          errorType = _LocationErrorType.outsideArea;
          break;
        case 'timeout':
          errorType = _LocationErrorType.gpsTimeout;
          break;
        case 'network':
        case 'server':
        default:
          errorType = _LocationErrorType.networkError;
          break;
      }

      setState(() {
        _locationVerified = false;
        _locationPhase = _LocationPhase.failed;
        _locationErrorType = errorType;
      });
      return;
    }

    // Location verified successfully!
    setState(() {
      _locationVerified = true;
      _locationPhase = _LocationPhase.verified;
    });
    _locationSuccessController.forward(from: 0.0);

    // Brief hold (~600ms) to display green check scale bounce & success text
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    setState(() {
      _locationPhase = _LocationPhase.docking;
    });

    // Begin docking transition & camera initialization in parallel
    final dockingFuture = _locationDockController.forward();
    final cameraInitFuture = _initializeCamera();

    await Future.wait([dockingFuture, cameraInitFuture]);

    if (mounted) {
      setState(() {
        _locationPhase = _LocationPhase.docked;
      });
    }
  }

  Future<void> _handleLocationErrorAction(_LocationErrorType type) async {
    switch (type) {
      case _LocationErrorType.disabled:
        await Geolocator.openLocationSettings();
        if (mounted) {
          _verifyLocation();
        }
        break;
      case _LocationErrorType.permissionDenied:
        final LocationPermission current = await Geolocator.checkPermission();
        if (current == LocationPermission.deniedForever) {
          await Geolocator.openAppSettings();
        } else {
          final requested = await Geolocator.requestPermission();
          if (requested == LocationPermission.deniedForever) {
            await Geolocator.openAppSettings();
          }
        }
        if (mounted) {
          _verifyLocation();
        }
        break;
      case _LocationErrorType.outsideArea:
      case _LocationErrorType.mockDetected:
      case _LocationErrorType.gpsTimeout:
      case _LocationErrorType.networkError:
        _verifyLocation();
        break;
    }
  }

  _LocationErrorInfo _getLocationErrorInfo(_LocationErrorType type) {
    switch (type) {
      case _LocationErrorType.disabled:
        return const _LocationErrorInfo(
          icon: Icons.location_disabled_rounded,
          title: 'Location is turned off',
          description:
              "We couldn't verify your attendance because your device location is turned off.",
          subtext:
              'Enable your device location to continue secure attendance verification.',
          primaryButtonText: 'Enable Location',
          primaryButtonIcon: Icons.location_on_rounded,
          gradientColors: [Color(0xFFEF4444), Color(0xFFF43F5E)],
          glowColor: Color(0xFFEF4444),
          shadowColor: Color(0xFFDC2626),
        );
      case _LocationErrorType.permissionDenied:
        return const _LocationErrorInfo(
          icon: Icons.location_off_rounded,
          title: 'Location permission required',
          description:
              'Attendance verification requires access to your device location.',
          subtext:
              'Grant location permission to continue secure attendance verification.',
          primaryButtonText: 'Grant Permission',
          primaryButtonIcon: Icons.lock_open_rounded,
          gradientColors: [Color(0xFFF59E0B), Color(0xFFEA580C)],
          glowColor: Color(0xFFF59E0B),
          shadowColor: Color(0xFFD97706),
        );
      case _LocationErrorType.outsideArea:
        return const _LocationErrorInfo(
          icon: Icons.place_rounded,
          title: "You're outside the attendance area",
          description:
              'Move inside the approved campus attendance area before verifying your attendance.',
          subtext:
              'Move inside the campus boundary to continue secure verification.',
          primaryButtonText: 'Retry',
          primaryButtonIcon: Icons.refresh_rounded,
          gradientColors: [Color(0xFFF97316), Color(0xFFEA580C)],
          glowColor: Color(0xFFF97316),
          shadowColor: Color(0xFFEA580C),
        );
      case _LocationErrorType.mockDetected:
        return const _LocationErrorInfo(
          icon: Icons.gpp_bad_rounded,
          title: 'Mock location detected',
          description:
              'Please disable mock location before continuing attendance verification.',
          subtext:
              'Disable mock location providers to continue secure verification.',
          primaryButtonText: 'Retry',
          primaryButtonIcon: Icons.refresh_rounded,
          gradientColors: [Color(0xFFDC2626), Color(0xFF991B1B)],
          glowColor: Color(0xFFDC2626),
          shadowColor: Color(0xFF991B1B),
        );
      case _LocationErrorType.gpsTimeout:
        return const _LocationErrorInfo(
          icon: Icons.gps_not_fixed_rounded,
          title: 'Unable to determine your location',
          description:
              'Please ensure GPS and your internet connection are available, then try again.',
          subtext: 'Ensure GPS has a clear signal and try again.',
          primaryButtonText: 'Retry',
          primaryButtonIcon: Icons.refresh_rounded,
          gradientColors: [Color(0xFFF97316), Color(0xFFD97706)],
          glowColor: Color(0xFFF97316),
          shadowColor: Color(0xFFD97706),
        );
      case _LocationErrorType.networkError:
        return const _LocationErrorInfo(
          icon: Icons.cloud_off_rounded,
          title: 'Connection problem',
          description:
              "We couldn't complete location verification.\nPlease check your internet connection and try again.",
          subtext: 'Please check your internet connection and try again.',
          primaryButtonText: 'Retry',
          primaryButtonIcon: Icons.refresh_rounded,
          gradientColors: [Color(0xFF64748B), Color(0xFF475569)],
          glowColor: Color(0xFF64748B),
          shadowColor: Color(0xFF475569),
        );
    }
  }

  Future<String> _checkGeofence() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return 'off';

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return 'permission_denied';
      }
      if (permission == LocationPermission.deniedForever) {
        return 'permission_denied';
      }

      // Fetch geofence settings from Supabase
      dynamic geoData;
      try {
        geoData = await Supabase.instance.client
            .from('geofence_settings')
            .select('latitude, longitude, radius_meters')
            .order('updated_at', ascending: false)
            .limit(1)
            .maybeSingle();
      } catch (e) {
        debugPrint('[GEOFENCE] Supabase fetch error: $e');
        return 'network';
      }

      debugPrint('[GEOFENCE] Raw geofence data from Supabase: $geoData');

      if (geoData == null) {
        debugPrint(
          '[GEOFENCE] No geofence settings found in Supabase — returning network/server error',
        );
        return 'network';
      }

      final double campusLat = (geoData['latitude'] as num).toDouble();
      final double campusLng = (geoData['longitude'] as num).toDouble();
      final double campusRadius = (geoData['radius_meters'] as num).toDouble();

      debugPrint(
        '[GEOFENCE] Campus: lat=$campusLat lng=$campusLng radius=${campusRadius}m',
      );

      // Fast-path: Check last known position if recent, accurate, and not mocked
      Position? position;
      try {
        final lastPosition = await Geolocator.getLastKnownPosition();
        if (lastPosition != null && !lastPosition.isMocked) {
          final int ageSeconds = DateTime.now()
              .difference(lastPosition.timestamp)
              .inSeconds
              .abs();
          if (ageSeconds <= 60 && lastPosition.accuracy <= 35) {
            debugPrint(
              '[GEOFENCE] Using recent, accurate last known position (age: ${ageSeconds}s, acc: ${lastPosition.accuracy}m)',
            );
            position = lastPosition;
          }
        }
      } catch (e) {
        debugPrint('[GEOFENCE] getLastKnownPosition fallback: $e');
      }

      // If no valid last known position, request high-accuracy position with timeout
      if (position == null) {
        try {
          position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 10),
            ),
          );
        } on TimeoutException {
          debugPrint('[GEOFENCE] Position request timed out');
          return 'timeout';
        } catch (e) {
          debugPrint('[GEOFENCE] getCurrentPosition error: $e');
          bool stillEnabled = await Geolocator.isLocationServiceEnabled();
          if (!stillEnabled) return 'off';
          return 'timeout';
        }
      }

      // Reject mock/spoofed locations
      if (position.isMocked) {
        debugPrint('[GEOFENCE] Mock location detected — rejecting');
        return 'mock';
      }

      final double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        campusLat,
        campusLng,
      );

      debugPrint(
        '[GEOFENCE] Distance from campus: ${distance.toStringAsFixed(1)}m, radius: ${campusRadius}m',
      );
      return distance <= campusRadius ? 'ok' : 'outside';
    } on TimeoutException {
      debugPrint('[GEOFENCE] Global timeout');
      return 'timeout';
    } catch (e) {
      debugPrint('[GEOFENCE] Error: $e');
      try {
        bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) return 'off';
        LocationPermission perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          return 'permission_denied';
        }
      } catch (_) {}
      return 'network';
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CAMERA INITIALIZATION
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _initializeCamera() async {
    try {
      _sessionId = FaceLandmarkService.newVerSessionId();
      final cameras = await availableCameras();
      final frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _cameraController!.initialize();

      _cameraStabilizer = CameraStabilizer(
        controller: _cameraController!,
        sessionId: _sessionId,
        logPrefix: 'FACE_VER',
      );
      await _cameraStabilizer.stabilize();

      // Set to device minimum zoom for widest field of view
      try {
        final minZoom = await _cameraController!.getMinZoomLevel();
        await _cameraController!.setZoomLevel(minZoom);
      } catch (_) {
        // Zoom not supported on this device — continue anyway
      }

      if (!mounted) return;
      setState(() {
        _cameraInitialized = true;
      });

      // Initialize ML services
      await _landmarkService.initialize();

      // Load stored embeddings
      await _loadEmbeddings();
      if (_storedTemplates == null || _storedTemplates!.isEmpty) {
        return; // error already set
      }

      // Start camera stream for face detection
      await _cameraController!.startImageStream(_onCameraFrame);

      _livenessService.logPrefix = 'FACE_VER';
      _livenessService.sessionId = _sessionId;

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
      debugPrint('[FACE_VER] Selected liveness plan: $_livenessPlan');

      _setPhase(_Phase.positioning);

      if (mounted) setState(() => _cameraPreviewReady = true);

      _ringController.forward();
      _startCountdownTimer();
    } catch (e) {
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
      final InputImage? inputImage = _convertToInputImage(cameraImage);
      if (inputImage == null) {
        _isProcessingFrame = false;
        return;
      }

      final List<Face> faces = await _mlService.faceDetector.processImage(
        inputImage,
      );

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
            _blinkCountdownController.stop();
            _blinkCountdownController.reset();
          }
          _updateInstruction('Fit your face in the circle', animate: false);
        }
        _isProcessingFrame = false;
        return;
      }

      // Pick the biggest face (filters background students in classroom)
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
              '[FACE_CAMERA] [FACE_VER][$_sessionId] Face tracking ID changed: ${_lastProcessedFace!.trackingId} -> ${face.trackingId}',
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
              '[FACE_CAMERA] [FACE_VER][$_sessionId] Face tracking lost via IoU (IoU: ${iou.toStringAsFixed(2)})',
            );
          }
        }
        if (!isSame) {
          debugPrint(
            '[FACE_CAMERA] [FACE_VER][$_sessionId] Face tracking lost — resetting captured frames and buffer',
          );
          _clearSmoothing();
          _capturedVerificationFrames.clear();
          _capturedVerificationFramesStats.clear();
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

      // ── Positioning gate (positioning + liveness before blink verified) ──
      if ((_phase == _Phase.positioning || _phase == _Phase.liveness) &&
          !_challengeVerified) {
        final bool strict = !_isFaceReady;
        final String? posInstruction = _getPositioningInstruction(
          face,
          cameraImage,
          strict: strict,
        );

        if (posInstruction != null) {
          if (_isFaceReady) {
            _isFaceReady = false;
            _livenessService.resetCalibration();
            _challengeStartTime = null;
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
            // Blink verified — transition to capturing
            await Future.delayed(const Duration(milliseconds: 500));
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
    if (_livenessPlan != 'blink_only' && _blinkDone && !_turnDone) {
      _turnStartTime ??= DateTime.now();
      final int elapsed = DateTime.now()
          .difference(_turnStartTime!)
          .inMilliseconds;
      const int turnTimeout = 5000;

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
        FaceLogger.ver(_sessionId, 'Turn challenge VERIFIED ✓');
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
      FaceLogger.ver(_sessionId, 'Blink challenge VERIFIED ✓');
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
        _sessionId,
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
      FaceLogger.ver(_sessionId, 'Processing Started');

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
        FaceLogger.ver(_sessionId, 'API FAILED');
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
            _sessionId,
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
            _sessionId,
            'Frame #${i + 1}: maxScore=${frameMaxScore.toStringAsFixed(4)} ($bestPose)',
          );

          if (framesAboveThresholdCount >= 2) {
            FaceLogger.ver(
              _sessionId,
              'Early exit triggered: 2 frames above threshold reached at frame #${i + 1}',
            );
            break;
          }
        } else {
          debugPrint('[FACE_VER] Frame rejected by backend.');
          FaceLogger.ver(
            _sessionId,
            'Frame #${i + 1}: backend quality reject (${res.rejectionReason ?? "null"})',
          );
        }
      }

      // 🚨 Handle Spoofing Attempt
      if (spoofDetected) {
        FaceLogger.ver(
          _sessionId,
          'Verification aborted due to Anti-Spoofing failure.',
        );
        setState(() => _borderColor = AppStyles.errorRed);
        _updateInstruction(
          'Liveness check failed',
          subtitle: 'Please present a real face',
        );

        await Future.delayed(const Duration(seconds: 2));
        if (mounted) _onRetry(); // Restart the camera and try again
        return;
      }

      FaceLogger.ver(_sessionId, 'Processing Finished');

      _validFrameCount = processedNonNullCount;
      FaceLogger.ver(
        _sessionId,
        'Valid Count: $_validFrameCount/$_framesPerPhase',
      );

      if (_validFrameCount < 3 && framesAboveThresholdCount < 2) {
        FaceLogger.ver(
          _sessionId,
          'Backend rejected frames due to quality. Failing gracefully to avoid user loop.',
        );
        _setError(
          'Image quality was too low. Please ensure good lighting and hold the phone steady, then try again.',
        );
        return;
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

      FaceLogger.ver(_sessionId, 'Per-Frame Multi-Template Decision:');
      FaceLogger.ver(
        _sessionId,
        '  FramesAboveThreshold=$framesAboveThresholdCount/${_liveEmbeddings.length}',
      );
      FaceLogger.ver(
        _sessionId,
        '  bestFrameScore = ${overallBestFrameScore.toStringAsFixed(4)}',
      );
      FaceLogger.ver(
        _sessionId,
        '  fusedScore = ${fusedScore.toStringAsFixed(4)}',
      );
      FaceLogger.ver(_sessionId, '  finalScore = ${score.toStringAsFixed(4)}');
      FaceLogger.ver(
        _sessionId,
        '  threshold = ${_verificationThreshold.toStringAsFixed(4)}',
      );
      FaceLogger.ver(_sessionId, '  livenessPassed = $livenessPassed');
      FaceLogger.ver(
        _sessionId,
        '  final decision = ${isMatch ? "PASS" : "FAIL"}',
      );

      final double avgQuality = 80.0;
      final double avgLocalBrightness = _allFramesStats.isEmpty
          ? 0.0
          : _allFramesStats
                    .map((s) => s['brightness'] ?? 0.0)
                    .reduce((a, b) => a + b) /
                _allFramesStats.length;
      final double avgLocalYaw = _capturedVerificationFramesStats.isEmpty
          ? 0.0
          : _capturedVerificationFramesStats
                    .map((s) => s['yaw'] ?? 0.0)
                    .reduce((a, b) => a + b) /
                _capturedVerificationFramesStats.length;
      final double avgLocalPitch = _capturedVerificationFramesStats.isEmpty
          ? 0.0
          : _capturedVerificationFramesStats
                    .map((s) => s['pitch'] ?? 0.0)
                    .reduce((a, b) => a + b) /
                _capturedVerificationFramesStats.length;

      final prefs = await SharedPreferences.getInstance();
      final user = Supabase.instance.client.auth.currentUser;
      final double regYaw = user != null
          ? prefs.getDouble('reg_yaw_${user.id}') ?? 0.0
          : 0.0;
      final double regPitch = user != null
          ? prefs.getDouble('reg_pitch_${user.id}') ?? 0.0
          : 0.0;
      final double regBrightness = user != null
          ? prefs.getDouble('reg_brightness_${user.id}') ?? 120.0
          : 120.0;

      String likelyCause = 'Unknown';
      if (!isMatch) {
        if (!livenessPassed) {
          likelyCause = 'Liveness Failed (Spoof Detected)';
        } else {
          final yawDiff = (regYaw - avgLocalYaw).abs();
          final pitchDiff = (regPitch - avgLocalPitch).abs();
          final brightnessDiff = (regBrightness - avgLocalBrightness).abs();

          if (yawDiff > 10.0 || pitchDiff > 10.0) {
            likelyCause = 'Pose Difference';
          } else if (brightnessDiff > 45.0) {
            likelyCause = 'Lighting Difference';
          } else if (avgQuality < 65.0) {
            likelyCause = 'Poor Quality Frames';
          } else {
            likelyCause = 'Low Similarity';
          }
        }
      }

      debugPrint('[FACE_VER][$_sessionId]');
      debugPrint('Backend Score=${score.toStringAsFixed(4)}');
      debugPrint('Fused Score=${fusedScore.toStringAsFixed(4)}');
      debugPrint('Threshold=${_verificationThreshold.toStringAsFixed(4)}');
      debugPrint('LivenessPassed=$livenessPassed');
      debugPrint('Decision=${isMatch ? "PASS" : "FAIL"}');

      debugPrint('[FACE_VER][$_sessionId] =========================');
      debugPrint('[FACE_VER][$_sessionId] FACE VERIFICATION SUMMARY');
      debugPrint('[FACE_VER][$_sessionId] =========================');
      debugPrint('[FACE_VER][$_sessionId] Registration Yaw=${regYaw.round()}');
      debugPrint(
        '[FACE_VER][$_sessionId] Verification Yaw=${avgLocalYaw.round()}',
      );
      debugPrint('[FACE_VER][$_sessionId] ');
      debugPrint(
        '[FACE_VER][$_sessionId] Registration Pitch=${regPitch.round()}',
      );
      debugPrint(
        '[FACE_VER][$_sessionId] Verification Pitch=${avgLocalPitch.round()}',
      );
      debugPrint('[FACE_VER][$_sessionId] ');
      debugPrint(
        '[FACE_VER][$_sessionId] Registration Brightness=${regBrightness.round()}',
      );
      debugPrint(
        '[FACE_VER][$_sessionId] Verification Brightness=${avgLocalBrightness.round()}',
      );
      debugPrint('[FACE_VER][$_sessionId] ');
      debugPrint(
        '[FACE_VER][$_sessionId] Backend Score=${score.toStringAsFixed(4)}',
      );
      debugPrint(
        '[FACE_VER][$_sessionId] Fused Score=${fusedScore.toStringAsFixed(4)}',
      );
      debugPrint(
        '[FACE_VER][$_sessionId] Threshold=${_verificationThreshold.toStringAsFixed(4)}',
      );
      debugPrint('[FACE_VER][$_sessionId] Liveness Passed=$livenessPassed');
      debugPrint('[FACE_VER][$_sessionId] ');
      debugPrint('[FACE_VER][$_sessionId] Likely Cause:');
      debugPrint('[FACE_VER][$_sessionId] $likelyCause');
      debugPrint('[FACE_VER][$_sessionId] =========================');

      FaceLogger.ver(
        _sessionId,
        'Backend Decision | Score: ${score.toStringAsFixed(4)} | FusedScore: ${fusedScore.toStringAsFixed(4)} | LivenessPassed: $livenessPassed | Match: $isMatch | LiveFrames: ${_liveEmbeddings.length}',
      );

      if (isMatch) {
        setState(() => _borderColor = AppStyles.successGreen);

        setState(() => _showFlash = true);
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) setState(() => _showFlash = false);
        });

        _particleController.forward(from: 0.0);

        _setPhase(_Phase.done);
        _updateInstruction('Verified!', subtitle: 'Face matched successfully');

        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;

        _countdownTimer?.cancel();

        final String? mode =
            ModalRoute.of(context)?.settings.arguments as String?;

        if (mode != 'password_reset' && mode != 'face_reset') {
          try {
            final user = Supabase.instance.client.auth.currentUser;
            if (user != null) {
              final todayStr = DateTime.now().toIso8601String().split('T')[0];
              await Supabase.instance.client.from('college_attendance').upsert({
                'student_id': user.id,
                'date': todayStr,
                'marked_at': DateTime.now().toUtc().toIso8601String(),
                'face_verified': true,
                'status': 'present',
              }, onConflict: 'student_id,date');
              FaceLogger.ver(_sessionId, 'College attendance saved');
            }
          } catch (e) {
            FaceLogger.ver(_sessionId, 'Failed to save college attendance: $e');
          }
        }

        if (!mounted) return;

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
      } else {
        FaceLogger.ver(_sessionId, 'Verification failed. Face did not match.');
        setState(() => _borderColor = AppStyles.errorRed);
        _updateInstruction(
          'Verification Failed',
          subtitle: 'Face did not match',
        );

        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) {
          Navigator.of(context).pushReplacementNamed('/attendance_failed');
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

  // ─────────────────────────────────────────────────────────────────────────
  // HELPERS — copied exactly from registration
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

      _consecutiveImageErrors = 0;

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.width,
        ),
      );
    } catch (_) {
      _consecutiveImageErrors++;
      if (_consecutiveImageErrors > 20) {
        _cameraController?.stopImageStream();
      }
      return null;
    }
  }

  double _calculateIoU(Rect rect1, Rect rect2) {
    final double intersectionX1 = math.max(rect1.left, rect2.left);
    final double intersectionY1 = math.max(rect1.top, rect2.top);
    final double intersectionX2 = math.min(rect1.right, rect2.right);
    final double intersectionY2 = math.min(rect1.bottom, rect2.bottom);

    final double intersectionWidth = math.max(
      0.0,
      intersectionX2 - intersectionX1,
    );
    final double intersectionHeight = math.max(
      0.0,
      intersectionY2 - intersectionY1,
    );
    final double intersectionArea = intersectionWidth * intersectionHeight;

    final double rect1Area = rect1.width * rect1.height;
    final double rect2Area = rect2.width * rect2.height;
    final double unionArea = rect1Area + rect2Area - intersectionArea;

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

  // ─── UI state updates ───────────────────────────────────────────────────

  void _setPhase(_Phase newPhase) {
    if (!mounted) return;
    if (_phase == newPhase) return;

    if (newPhase != _Phase.error &&
        newPhase != _Phase.positioning &&
        newPhase != _Phase.liveness) {
      HapticFeedback.mediumImpact();
      _successBounceController.forward(from: 0.0);
    }
    if (newPhase == _Phase.done) {
      _particleController.forward(from: 0.0);
    }

    setState(() {
      _phase = newPhase;
    });

    if (newPhase == _Phase.positioning || newPhase == _Phase.liveness) {
      if (newPhase == _Phase.positioning) {
        _challengeVerified = false;
        _challengeStartTime = null;
        _turnStartTime = null;
        _blinkDone = false;
        _turnDone = false;
        _livenessService.reset();
        _steadyStartTime = null;
        _isFaceReady = false;
        _clearSmoothing();
      }
    }

    switch (newPhase) {
      case _Phase.positioning:
        _blinkCountdownController.reset();
        _updateInstruction(
          'Fit your face in the circle',
          subtitle: 'Make sure your full face is visible',
        );
        break;
      case _Phase.liveness:
        _blinkCountdownController.reset();
        _updateInstruction(
          'Calibrating…',
          subtitle: 'Look straight at the camera and hold still',
        );
        break;
      case _Phase.capturing:
        _updateInstruction(
          'Hold still…',
          subtitle: 'Scanning your face silently',
        );
        break;
      case _Phase.processing:
        _updateInstruction(
          'Verifying Identity',
          subtitle: 'Comparing your live face securely…',
        );
        break;
      case _Phase.done:
        _updateInstruction('Verified!', subtitle: 'Face matched successfully');
        break;
      case _Phase.error:
        break;
      default:
        break;
    }
  }

  void _updateInstruction(
    String title, {
    String? subtitle,
    bool animate = true,
  }) {
    if (!mounted) return;

    if (_instructionTitle == title) {
      _instructionDebounceTimer?.cancel();
      return;
    }

    _instructionDebounceTimer?.cancel();
    _instructionDebounceTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      if (_instructionTitle == title) return;

      if (animate) {
        _textFadeController.reverse().then((_) {
          if (!mounted) return;
          setState(() {
            _instructionTitle = title;
            _instructionSubtitle = subtitle ?? (_subtitles[title] ?? '');

            final lower = title.toLowerCase();
            if (lower.contains('move closer') ||
                lower.contains('move left') ||
                lower.contains('move right') ||
                lower.contains('move slightly up') ||
                lower.contains('move slightly down') ||
                lower.contains('move to the center') ||
                lower.contains('move slightly backward') ||
                lower.contains('too bright') ||
                lower.contains('too dark')) {
              _borderColor = Colors.orangeAccent;
            } else if (_phase != _Phase.error &&
                _borderColor != AppStyles.successGreen) {
              _borderColor = AppStyles.primaryBlue;
            }
          });
          _textFadeController.forward();
          if (_phase == _Phase.liveness) {
            _blinkCountdownController.forward(from: 0.0);
          }
        });
      } else {
        setState(() {
          _instructionTitle = title;
          _instructionSubtitle = subtitle ?? (_subtitles[title] ?? '');

          final lower = title.toLowerCase();
          if (lower.contains('move closer') ||
              lower.contains('move left') ||
              lower.contains('move right') ||
              lower.contains('move slightly up') ||
              lower.contains('move slightly down') ||
              lower.contains('move to the center') ||
              lower.contains('move slightly backward') ||
              lower.contains('too bright') ||
              lower.contains('too dark')) {
            _borderColor = Colors.orangeAccent;
          } else if (_phase != _Phase.error &&
              _borderColor != AppStyles.successGreen) {
            _borderColor = AppStyles.primaryBlue;
          }
        });
      }
    });
  }

  void _startCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 1) {
        setState(() => _secondsRemaining--);
        _timerPulseController.forward().then((_) {
          if (mounted) _timerPulseController.reverse();
        });
      } else {
        setState(() => _secondsRemaining = 0);
        timer.cancel();
        // Timer expired → navigate to failed
        if (mounted && _phase != _Phase.done) {
          Navigator.of(context).pushReplacementNamed('/attendance_failed');
        }
      }
    });
  }

  String _userFriendlyError(String technicalError) {
    if (technicalError.contains('Camera') ||
        technicalError.contains('camera')) {
      return 'Camera could not start. Please try again.';
    }
    if (technicalError.contains('timeout') ||
        technicalError.contains('Timeout')) {
      return 'Processing timed out. Please try again.';
    }
    if (technicalError.contains('network') ||
        technicalError.contains('Socket') ||
        technicalError.contains('http') ||
        technicalError.contains('Http')) {
      return 'Network issue. Please try again.';
    }
    return 'Something went wrong. Please try again.';
  }

  void _setError(String message) {
    if (!mounted) return;
    debugPrint('[CAPTURE] ERROR: $message');
    final friendly = _userFriendlyError(message);
    setState(() {
      _phase = _Phase.error;
      _errorMessage = friendly;
      _borderColor = AppStyles.errorRed;
      _instructionTitle = 'Something went wrong';
      _instructionSubtitle = friendly;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DISPOSE
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void dispose() {
    debugPrint('[CAPTURE] Disposed');
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _textFadeController.dispose();
    _blinkCountdownController.dispose();
    _successBounceController.dispose();
    _particleController.dispose();
    _locationAnimController.dispose();
    _locationSuccessController.dispose();
    _locationDockController.dispose();

    _timerPulseController.dispose();
    _ringController.dispose();
    _countdownTimer?.cancel();
    _instructionDebounceTimer?.cancel();
    _stopLocationSubtitleTimers();

    if (_cameraController != null && _cameraInitialized) {
      try {
        _cameraController!.stopImageStream();
      } catch (_) {}
      _cameraController!.dispose();
    }

    _mlService.faceDetector.close();
    super.dispose();
  }

  // ─── Leave Confirmation Dialog State & Handlers ───────────────────────────
  bool _isLeaveDialogShowing = false;

  Future<void> _showLeaveConfirmationDialog() async {
    if (_isLeaveDialogShowing || !mounted) return;
    _isLeaveDialogShowing = true;

    final shouldLeave = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss Leave Dialog',
      barrierColor: Colors.black.withValues(alpha: 0.54),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (dialogContext, anim1, anim2) {
        return _buildLeaveConfirmationDialog(dialogContext);
      },
      transitionBuilder: (dialogContext, anim1, anim2, child) {
        final curvedValue = Curves.easeOutCubic.transform(anim1.value);
        return BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: 4.0 * anim1.value,
            sigmaY: 4.0 * anim1.value,
          ),
          child: Opacity(
            opacity: anim1.value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.94 + (0.06 * curvedValue),
              child: child,
            ),
          ),
        );
      },
    );

    _isLeaveDialogShowing = false;

    if (shouldLeave == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  Widget _buildLeaveConfirmationDialog(BuildContext dialogContext) {
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      shadowColor: Colors.black.withValues(alpha: 0.2),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: const Color(0xFFE2E8F0).withValues(alpha: 0.9),
          width: 1,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Warning / Exit Icon Badge
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFFFEDD5),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFEA580C).withValues(alpha: 0.12),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFEA580C),
                    size: 30,
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // Title
              const Text(
                'Leave verification?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),

              // Description
              const Text(
                "Your attendance isn't marked yet.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF475569),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 4),

              // Supporting text
              const Text(
                "Leave now and you'll be marked absent.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFF94A3B8),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 24),

              // Action Buttons: Leave / Continue
              Row(
                children: [
                  // Secondary Action: Leave
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF64748B),
                        side: const BorderSide(
                          color: Color(0xFFCBD5E1),
                          width: 1.2,
                        ),
                        backgroundColor: const Color(0xFFF8FAFC),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Leave',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Primary Action: Continue
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppStyles.primaryBlue,
                        foregroundColor: Colors.white,
                        elevation: 2,
                        shadowColor: AppStyles.primaryBlue.withValues(alpha: 0.35),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      child: const Text(
                        'Continue',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showLeaveConfirmationDialog();
      },
      child: Scaffold(
        backgroundColor: AppStyles.backgroundLight,
        body: Stack(
          children: [
            SafeArea(
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _locationAnimController,
                  _locationSuccessController,
                  _locationDockController,
                ]),
                builder: (context, child) {
              final double dockProgress = CurvedAnimation(
                parent: _locationDockController,
                curve: Curves.easeInOutCubic,
              ).value;

              return Stack(
                children: [
                  // ── PART 1 & 2: Centered Location Checking / Verified / Error Hero View ──
                  if (dockProgress < 1.0)
                    Positioned.fill(
                      child: Opacity(
                        opacity: (1.0 - dockProgress).clamp(0.0, 1.0),
                        child: Transform.scale(
                          scale: 1.0 - (dockProgress * 0.12),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 350),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) {
                              return FadeTransition(
                                opacity: animation,
                                child: ScaleTransition(
                                  scale: Tween<double>(
                                    begin: 0.95,
                                    end: 1.0,
                                  ).animate(animation),
                                  child: child,
                                ),
                              );
                            },
                            child:
                                _locationPhase == _LocationPhase.failed &&
                                    _locationErrorType != null
                                ? KeyedSubtree(
                                    key: ValueKey<String>(
                                      'error_${_locationErrorType!.name}',
                                    ),
                                    child: _buildLocationErrorState(
                                      _locationErrorType!,
                                    ),
                                  )
                                : KeyedSubtree(
                                    key: const ValueKey<String>(
                                      'location_checking_view',
                                    ),
                                    child: _buildLocationCheckingView(),
                                  ),
                          ),
                        ),
                      ),
                    ),

                  // ── PART 3 & 5: Face Verification Main Content Layout ──────
                  if (dockProgress > 0.0)
                    Positioned.fill(
                      child: Opacity(
                        opacity: dockProgress.clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(0, (1.0 - dockProgress) * 36.0),
                          child: Column(
                            children: [
                              // Top App Bar
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0,
                                  vertical: 12.0,
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

                              // Camera Preview & Verification Content Stack
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final double availW = constraints.maxWidth;
                                    final double availH = constraints.maxHeight;
                                    final double circleSize = availW * 0.80;
                                    final double circleTop =
                                        availH * 0.40 - circleSize / 2;
                                    const double contentUpwardShift = 12.0;
                                    final double verificationBaseTop =
                                        circleTop - 100 - contentUpwardShift;

                                    _uiCircleSize = circleSize;
                                    _uiAvailW = availW;
                                    _uiAvailH = availH;

                                    double offsetX = 0;
                                    double offsetY = 0;
                                    if (_cameraInitialized &&
                                        _bufFaceCX.isNotEmpty) {
                                      final Size? previewSize =
                                          _cameraController?.value.previewSize;
                                      final double sensorW =
                                          previewSize?.height ?? 3.0;
                                      if (sensorW > 0) {
                                        final double scale = availW / sensorW;
                                        final double faceUIX =
                                            _bufAvg(_bufFaceCX) * scale;
                                        final double faceUIY =
                                            _bufAvg(_bufFaceCY) * scale;
                                        final double circleUIX = availW / 2;
                                        final double circleUIY =
                                            verificationBaseTop +
                                            circleSize / 2;

                                        offsetX = (faceUIX - circleUIX).clamp(
                                          -6.0,
                                          6.0,
                                        );
                                        offsetY = (faceUIY - circleUIY).clamp(
                                          -6.0,
                                          6.0,
                                        );
                                      }
                                    }

                                    return SizedBox(
                                      width: availW,
                                      height: availH,
                                      child: Stack(
                                        children: [
                                          // Background: Soft Layered Ambient Background with Breathing Bloom & Floating Light Particles
                                          Positioned.fill(
                                            child: _FaceVerificationAmbientBackground(
                                              pulseValue: _pulseController.value,
                                            ),
                                          ),

                                          // Face Interactive Overlay Group
                                          AnimatedPositioned(
                                            duration: const Duration(
                                              milliseconds: 120,
                                            ),
                                            curve: Curves.easeOut,
                                            left: offsetX,
                                            top: offsetY,
                                            right: -offsetX,
                                            bottom: -offsetY,
                                            child: Stack(
                                              children: [
                                                // Circle clip for the camera preview
                                                Positioned(
                                                  left:
                                                      (availW - circleSize) / 2,
                                                  top: verificationBaseTop,
                                                  child: ClipOval(
                                                    child: SizedBox(
                                                      width: circleSize,
                                                      height: circleSize,
                                                      child: Stack(
                                                        children: [
                                                          // 1. Live Camera Preview (or Frozen Captured Final Frame)
                                                          if (_cameraInitialized &&
                                                              _cameraController !=
                                                                  null)
                                                            OverflowBox(
                                                              maxWidth: availW,
                                                              maxHeight: availH,
                                                              child: Transform.translate(
                                                                offset: Offset(
                                                                  0,
                                                                  -circleTop,
                                                                ),
                                                                child:
                                                                    _buildCameraPreview(
                                                                      availW,
                                                                      circleTop,
                                                                    ),
                                                              ),
                                                            ),

                                                          // 2. Warm-up loading overlay: Perfectly centered in circle, smooth fadeout, never reappears
                                                          AnimatedSwitcher(
                                                            duration:
                                                                const Duration(
                                                                  milliseconds:
                                                                      350,
                                                                ),
                                                            switchInCurve:
                                                                Curves.easeOut,
                                                            switchOutCurve:
                                                                Curves.easeIn,
                                                            child:
                                                                !_cameraPreviewReady
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
                                                  left:
                                                      (availW - circleSize) / 2,
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
                                                            curve: Curves
                                                                .elasticOut,
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
                                                            if (animatedProgress >
                                                                    0.4 &&
                                                                animatedProgress <
                                                                    0.9) {
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
                                                                animation:
                                                                    _pulseController,
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
                                                                      phase:
                                                                          _phase,
                                                                      flowValue:
                                                                          0.0,
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
                                              duration: const Duration(
                                                milliseconds: 600,
                                              ),
                                              curve: Curves.easeOut,
                                              opacity:
                                                  _phase == _Phase.capturing
                                                  ? 0.3
                                                  : 0.0,
                                              child: CustomPaint(
                                                painter: _FillLightPainter(
                                                  circleCenter: Offset(
                                                    availW / 2,
                                                    verificationBaseTop +
                                                        circleSize / 2,
                                                  ),
                                                  circleRadius: circleSize / 2,
                                                ),
                                              ),
                                            ),
                                          ),

                                          // Studio Flash on Capture
                                          Positioned.fill(
                                            child: AnimatedOpacity(
                                              duration: const Duration(
                                                milliseconds: 100,
                                              ),
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
                                                      Colors.white.withValues(
                                                        alpha: 0.0,
                                                      ),
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
                                              builder: (context, _) =>
                                                  CustomPaint(
                                                    size: Size(
                                                      circleSize,
                                                      circleSize,
                                                    ),
                                                    painter:
                                                        _ParticleBurstPainter(
                                                          _particleController
                                                              .value,
                                                        ),
                                                  ),
                                            ),
                                          ),

                                          // ── Dynamic Layout Column (Aligned with Face Circle Grid) ──
                                          Positioned(
                                            top:
                                                verificationBaseTop +
                                                circleSize +
                                                28,
                                            left: math.max(
                                              (availW - circleSize) / 2 - 16,
                                              14.0,
                                            ),
                                            right: math.max(
                                              (availW - circleSize) / 2 - 16,
                                              14.0,
                                            ),
                                            child: AnimatedOpacity(
                                              duration: const Duration(
                                                milliseconds: 300,
                                              ),
                                              opacity:
                                                  _cameraPreviewReady &&
                                                      _phase !=
                                                          _Phase.initializing
                                                  ? 1.0
                                                  : 0.0,
                                              child: SingleChildScrollView(
                                                physics:
                                                    const NeverScrollableScrollPhysics(),
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    // 1. Main / Blink Countdown Timer (Floating naturally below circle with breathing space)
                                                    if (_phase !=
                                                            _Phase
                                                                .initializing &&
                                                        _phase !=
                                                            _Phase.processing &&
                                                        _phase != _Phase.done)
                                                      SizedBox(
                                                        height: 56,
                                                        child: Center(
                                                          child: AnimatedSwitcher(
                                                            duration:
                                                                const Duration(
                                                                  milliseconds:
                                                                      300,
                                                                ),
                                                            switchInCurve: Curves
                                                                .easeOutCubic,
                                                            switchOutCurve:
                                                                Curves
                                                                    .easeInCubic,
                                                            child:
                                                                (_phase ==
                                                                        _Phase
                                                                            .liveness &&
                                                                    (_instructionTitle.contains(
                                                                          'Blink',
                                                                        ) ||
                                                                        _instructionSubtitle.contains(
                                                                          'Blink',
                                                                        )) &&
                                                                    !_challengeVerified)
                                                                ? SizedBox(
                                                                    key: const ValueKey(
                                                                      'blink',
                                                                    ),
                                                                    width: 50,
                                                                    height: 50,
                                                                    child: AnimatedBuilder(
                                                                      animation:
                                                                          _blinkCountdownController,
                                                                      builder:
                                                                          (
                                                                            context,
                                                                            child,
                                                                          ) {
                                                                            final double
                                                                            remaining =
                                                                                3.0 *
                                                                                (1.0 -
                                                                                    _blinkCountdownController.value);
                                                                            final int
                                                                            currentSec =
                                                                                remaining.ceil();
                                                                            const Color
                                                                            warmOrange = Color(
                                                                              0xFFF97316,
                                                                            );
                                                                            return Container(
                                                                              width: 50,
                                                                              height: 50,
                                                                              decoration: BoxDecoration(
                                                                                shape: BoxShape.circle,
                                                                                color: Colors.white,
                                                                                boxShadow: [
                                                                                  BoxShadow(
                                                                                    color: warmOrange.withValues(
                                                                                      alpha: 0.25,
                                                                                    ),
                                                                                    blurRadius: 10,
                                                                                    offset: const Offset(
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
                                                                                      _blinkCountdownController.value,
                                                                                  color: warmOrange,
                                                                                ),
                                                                                child: Center(
                                                                                  child: AnimatedSwitcher(
                                                                                    duration: const Duration(
                                                                                      milliseconds: 200,
                                                                                    ),
                                                                                    transitionBuilder:
                                                                                        (
                                                                                          Widget child,
                                                                                          Animation<
                                                                                            double
                                                                                          >
                                                                                          animation,
                                                                                        ) {
                                                                                          return ScaleTransition(
                                                                                            scale: animation,
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
                                                                                        fontSize: 18,
                                                                                        fontWeight: FontWeight.w800,
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
                                                                      'ring',
                                                                    ),
                                                                    animation:
                                                                        _ringProgress,
                                                                    builder: (context, _) {
                                                                      final Color
                                                                      ringColor =
                                                                          _secondsRemaining <=
                                                                              5
                                                                          ? AppStyles.errorRed
                                                                          : AppStyles.primaryBlue;
                                                                      return Container(
                                                                        width:
                                                                            50,
                                                                        height:
                                                                            50,
                                                                        decoration: BoxDecoration(
                                                                          shape:
                                                                              BoxShape.circle,
                                                                          color:
                                                                              Colors.white,
                                                                          boxShadow: [
                                                                            BoxShadow(
                                                                              color: ringColor.withValues(
                                                                                alpha: 0.15,
                                                                              ),
                                                                              blurRadius: 10,
                                                                              offset: const Offset(
                                                                                0,
                                                                                3,
                                                                              ),
                                                                            ),
                                                                          ],
                                                                        ),
                                                                        child: CustomPaint(
                                                                          painter: _MiniRingPainter(
                                                                            progress:
                                                                                _ringProgress.value,
                                                                            color:
                                                                                ringColor,
                                                                          ),
                                                                          child: Center(
                                                                            child: AnimatedSwitcher(
                                                                              duration: const Duration(
                                                                                milliseconds: 200,
                                                                              ),
                                                                              transitionBuilder:
                                                                                  (
                                                                                    child,
                                                                                    animation,
                                                                                  ) {
                                                                                    return ScaleTransition(
                                                                                      scale: animation,
                                                                                      child: FadeTransition(
                                                                                        opacity: animation,
                                                                                        child: child,
                                                                                      ),
                                                                                    );
                                                                                  },
                                                                              child: Text(
                                                                                '${_secondsRemaining}s',
                                                                                key:
                                                                                    ValueKey<
                                                                                      int
                                                                                    >(
                                                                                      _secondsRemaining,
                                                                                    ),
                                                                                style: const TextStyle(
                                                                                  fontSize: 13,
                                                                                  fontWeight: FontWeight.w800,
                                                                                  color: Color(
                                                                                    0xFF0F172A,
                                                                                  ), // Dark Navy
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

                                                    const SizedBox(height: 8),

                                                    // 2. Attempt Counter (Polished styling + smooth fade & slide up animation)
                                                    AnimatedOpacity(
                                                      duration: const Duration(
                                                        milliseconds: 300,
                                                      ),
                                                      opacity:
                                                          _cameraPreviewReady
                                                          ? 1.0
                                                          : 0.0,
                                                      child: AnimatedSwitcher(
                                                        duration:
                                                            const Duration(
                                                              milliseconds: 250,
                                                            ),
                                                        switchInCurve:
                                                            Curves.easeOutCubic,
                                                        switchOutCurve:
                                                            Curves.easeInCubic,
                                                        transitionBuilder: (child, animation) {
                                                          return FadeTransition(
                                                            opacity: animation,
                                                            child: SlideTransition(
                                                              position:
                                                                  Tween<Offset>(
                                                                    begin:
                                                                        const Offset(
                                                                          0,
                                                                          0.2,
                                                                        ),
                                                                    end: Offset
                                                                        .zero,
                                                                  ).animate(
                                                                    animation,
                                                                  ),
                                                              child: child,
                                                            ),
                                                          );
                                                        },
                                                        child: Text(
                                                          'Attempt $_attemptCount of 2',
                                                          key: ValueKey<int>(
                                                            _attemptCount,
                                                          ),
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 13.0,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w800,
                                                                letterSpacing:
                                                                    0.35,
                                                                color: Color(
                                                                  0xFF0F172A,
                                                                ),
                                                              ),
                                                        ),
                                                      ),
                                                    ),

                                                    const SizedBox(height: 12),

                                                    // 3. Status Stepper Card
                                                    if (_phase !=
                                                            _Phase
                                                                .initializing &&
                                                        _phase !=
                                                            _Phase.processing &&
                                                        _phase != _Phase.done)
                                                      ClipRRect(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              18,
                                                            ),
                                                        child: BackdropFilter(
                                                          filter:
                                                              ImageFilter.blur(
                                                                sigmaX: 12,
                                                                sigmaY: 12,
                                                              ),
                                                          child: Container(
                                                            padding:
                                                                const EdgeInsets.symmetric(
                                                                  horizontal:
                                                                      16,
                                                                  vertical: 14,
                                                                ),
                                                            decoration: BoxDecoration(
                                                              color: Colors
                                                                  .white
                                                                  .withValues(
                                                                    alpha: 0.94,
                                                                  ),
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    18,
                                                                  ),
                                                              border: Border.all(
                                                                color: const Color(
                                                                  0xFF3B82F6,
                                                                ).withValues(
                                                                  alpha: 0.12,
                                                                ),
                                                                width: 1.2,
                                                              ),
                                                              boxShadow: [
                                                                BoxShadow(
                                                                  color: const Color(
                                                                    0xFF0F172A,
                                                                  ).withValues(
                                                                    alpha: 0.04,
                                                                  ),
                                                                  blurRadius:
                                                                      18,
                                                                  offset:
                                                                      const Offset(
                                                                        0,
                                                                        4,
                                                                      ),
                                                                ),
                                                                BoxShadow(
                                                                  color: AppStyles
                                                                      .primaryBlue
                                                                      .withValues(
                                                                        alpha:
                                                                            0.06,
                                                                      ),
                                                                  blurRadius:
                                                                      10,
                                                                  offset:
                                                                      const Offset(
                                                                        0,
                                                                        2,
                                                                      ),
                                                                ),
                                                              ],
                                                            ),
                                                            child: AnimatedBuilder(
                                                              animation:
                                                                  _pulseController,
                                                              builder: (context, _) {
                                                                final bool
                                                                isLivenessActive =
                                                                    _phase ==
                                                                        _Phase
                                                                            .positioning ||
                                                                    _phase ==
                                                                        _Phase
                                                                            .liveness;
                                                                final bool
                                                                isScanningActive =
                                                                    _phase ==
                                                                    _Phase
                                                                        .capturing;

                                                                return Row(
                                                                  mainAxisAlignment:
                                                                      MainAxisAlignment
                                                                          .spaceBetween,
                                                                  children: [
                                                                    _NeonChip(
                                                                      label:
                                                                          'Liveness',
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
                                                                      label:
                                                                          'Scanning',
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
                                                                      label:
                                                                          'Done',
                                                                      isActive:
                                                                          _phase ==
                                                                          _Phase
                                                                              .done,
                                                                      isDone:
                                                                          _phase ==
                                                                          _Phase
                                                                              .done,
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

                                                    const SizedBox(
                                                      height: 16,
                                                    ), // 16px vertical rhythm gap between Status Card & Instruction Card
                                                    // 4. Instruction / Verification Card (Smooth Entrance & State Animations)
                                                    AnimatedScale(
                                                      scale:
                                                          _phase ==
                                                              _Phase.processing
                                                          ? 1.0
                                                          : 1.0,
                                                      duration: const Duration(
                                                        milliseconds: 300,
                                                      ),
                                                      curve:
                                                          Curves.easeOutCubic,
                                                      child: SlideTransition(
                                                        position:
                                                            Tween<Offset>(
                                                              begin:
                                                                  const Offset(
                                                                    0,
                                                                    0.05,
                                                                  ),
                                                              end: const Offset(
                                                                0,
                                                                0,
                                                              ),
                                                            ).animate(
                                                              CurvedAnimation(
                                                                parent:
                                                                    _textFadeController,
                                                                curve: Curves
                                                                    .easeOutCubic,
                                                              ),
                                                            ),
                                                        child: FadeTransition(
                                                          opacity:
                                                              _textFadeController,
                                                          child: ClipRRect(
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  18,
                                                                ),
                                                            child: BackdropFilter(
                                                              filter: ImageFilter.blur(
                                                                sigmaX: _phase == _Phase.processing ? 16 : 0,
                                                                sigmaY: _phase == _Phase.processing ? 16 : 0,
                                                              ),
                                                              child: AnimatedSize(
                                                                duration:
                                                                    const Duration(
                                                                      milliseconds:
                                                                          300,
                                                                    ),
                                                                curve: Curves
                                                                    .easeOutCubic,
                                                                alignment: Alignment
                                                                    .topCenter,
                                                                child: AnimatedContainer(
                                                                duration:
                                                                    const Duration(
                                                                      milliseconds:
                                                                          300,
                                                                    ),
                                                                curve: Curves
                                                                    .easeOutCubic,
                                                                decoration: BoxDecoration(
                                                                  gradient: _phase == _Phase.processing
                                                                      ? LinearGradient(
                                                                          begin: Alignment.topCenter,
                                                                          end: Alignment.bottomCenter,
                                                                          colors: [
                                                                            Colors.white.withValues(alpha: 0.94),
                                                                            const Color(0xFFF8FAFC).withValues(alpha: 0.88),
                                                                          ],
                                                                        )
                                                                      : null,
                                                                  color: _phase != _Phase.processing
                                                                      ? Colors.white.withValues(alpha: 0.95)
                                                                      : null,
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        18,
                                                                      ),
                                                                  border: Border.all(
                                                                    color: _phase == _Phase.processing
                                                                        ? const Color(0xFF38BDF8).withValues(alpha: 0.42)
                                                                        : (_phase == _Phase.error
                                                                            ? AppStyles.errorRed.withValues(alpha: 0.3)
                                                                            : const Color(0xFFE2E8F0)),
                                                                    width: _phase == _Phase.processing ? 1.3 : 1.2,
                                                                  ),
                                                                  boxShadow: _phase == _Phase.processing
                                                                      ? [
                                                                          BoxShadow(
                                                                            color: const Color(0xFF0F172A).withValues(alpha: 0.09),
                                                                            blurRadius: 28,
                                                                            offset: const Offset(0, 10),
                                                                          ),
                                                                          BoxShadow(
                                                                            color: const Color(0xFF0284C7).withValues(alpha: 0.11),
                                                                            blurRadius: 18,
                                                                            offset: const Offset(0, 3),
                                                                            spreadRadius: -2,
                                                                          ),
                                                                          BoxShadow(
                                                                            color: const Color(0xFF38BDF8).withValues(alpha: 0.16),
                                                                            blurRadius: 10,
                                                                            offset: const Offset(0, 1),
                                                                          ),
                                                                        ]
                                                                      : [
                                                                          BoxShadow(
                                                                            color: Colors.black.withValues(alpha: 0.05),
                                                                            blurRadius: 14,
                                                                            offset: const Offset(0, 4),
                                                                          ),
                                                                        ],
                                                                ),
                                                                padding: EdgeInsets.symmetric(
                                                                  horizontal: 20,
                                                                  vertical:
                                                                      _phase ==
                                                                          _Phase
                                                                              .processing
                                                                      ? 16
                                                                      : 14,
                                                                ),
                                                                child: Column(
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
                                                                              _Phase.positioning ||
                                                                          _phase ==
                                                                              _Phase.liveness)) ...[
                                                                    Padding(
                                                                      padding: const EdgeInsets.only(
                                                                        bottom:
                                                                            8.0,
                                                                      ),
                                                                      child: _MiniChallengeProgressIndicator(
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
                                                                    duration: const Duration(
                                                                      milliseconds:
                                                                          280,
                                                                    ),
                                                                    switchInCurve:
                                                                        Curves
                                                                            .easeOutCubic,
                                                                    switchOutCurve:
                                                                        Curves
                                                                            .easeInCubic,
                                                                    transitionBuilder:
                                                                        (
                                                                          child,
                                                                          animation,
                                                                        ) {
                                                                          return FadeTransition(
                                                                            opacity:
                                                                                animation,
                                                                            child: SlideTransition(
                                                                              position:
                                                                                  Tween<
                                                                                        Offset
                                                                                      >(
                                                                                        begin: const Offset(
                                                                                          0,
                                                                                          0.12,
                                                                                        ),
                                                                                        end: Offset.zero,
                                                                                      )
                                                                                      .animate(
                                                                                        animation,
                                                                                      ),
                                                                              child: child,
                                                                            ),
                                                                          );
                                                                        },
                                                                    child: Column(
                                                                      key:
                                                                          ValueKey<
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
                                                                              TextAlign.center,
                                                                          style: TextStyle(
                                                                            fontSize:
                                                                                18.0,
                                                                            fontWeight:
                                                                                FontWeight.w700,
                                                                            letterSpacing:
                                                                                -0.35,
                                                                            height:
                                                                                1.25,
                                                                            color:
                                                                                _phase ==
                                                                                    _Phase.error
                                                                                ? AppStyles.errorRed
                                                                                : AppStyles.primaryBlue,
                                                                          ),
                                                                        ),
                                                                        if (_instructionSubtitle
                                                                            .isNotEmpty) ...[
                                                                          const SizedBox(
                                                                            height:
                                                                                5.0,
                                                                          ),
                                                                          Text(
                                                                            _instructionSubtitle,
                                                                            textAlign:
                                                                                TextAlign.center,
                                                                            style: const TextStyle(
                                                                              fontSize:
                                                                                  13.5,
                                                                              color:
                                                                                  Color(0xFF334155),
                                                                              fontWeight:
                                                                                  FontWeight.w500,
                                                                              height:
                                                                                  1.40,
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
                                                                      height:
                                                                          10,
                                                                    ),
                                                                    const _BiometricVerificationWidget(),
                                                                  ],
                                                                    if (_phase ==
                                                                        _Phase
                                                                            .error) ...[
                                                                      const SizedBox(
                                                                        height:
                                                                            12,
                                                                      ),
                                                                      TextButton(
                                                                        onPressed:
                                                                            _onRetry,
                                                                        child: const Text(
                                                                          'Try Again',
                                                                          style: TextStyle(
                                                                            color:
                                                                                AppStyles.primaryBlue,
                                                                            fontWeight:
                                                                                FontWeight.w600,
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ],
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
                      ),
                    ),
                ],
              );
            },
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
              : CameraPreview(_cameraController!),
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

  void _onRetry() {
    debugPrint(
      '[CAPTURE] Started | screen=verification target=$_framesPerPhase',
    );
    _cameraStabilizer.resetStabilityOnly();
    _meteringApplied = false;
    _stabilityRejectCount = 0;
    _livenessService.resetCalibration();
    _liveEmbeddings.clear();
    _capturedVerificationFrames.clear();
    _validResults.clear();
    _validFrameCount = 0;
    _cameraFrozen = false;
    _lastCapturedFrameBytes = null;
    _isSubmitting = false;

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
    _blinkCountdownController.reset();
    _steadyStartTime = null;
    _isFaceReady = false;
    _lastKnownBlinkCount = 0;
    _clearSmoothing();

    setState(() {
      _borderColor = AppStyles.primaryBlue;
      _errorMessage = null;
      _secondsRemaining = 60; // Reset the countdown timer
    });

    // Restart countdown timer
    _startCountdownTimer();

    // Restart camera stream if needed
    if (_cameraInitialized && _cameraController != null) {
      try {
        _cameraController!.stopImageStream().then((_) {
          if (mounted) {
            _cameraController!.startImageStream(_onCameraFrame);
          }
        });
      } catch (_) {
        try {
          _cameraController!.startImageStream(_onCameraFrame);
        } catch (_) {}
      }
    }

    _setPhase(_Phase.positioning);
  }

  // ─── Location Checking & Error UI Builders ─────────────────────────────────
  Widget _buildLocationCheckingView() {
    final bool isVerified =
        _locationPhase == _LocationPhase.verified ||
        _locationPhase == _LocationPhase.docking;
    final double animVal = _locationAnimController.value;
    final double floatOffset = isVerified
        ? 0.0
        : math.sin(animVal * 2 * math.pi) * 3.5;
    final double breathe = isVerified
        ? 0.0
        : math.sin(animVal * 2 * math.pi) * 0.03;

    final Color themePrimary = isVerified
        ? AppStyles.successGreen
        : const Color(0xFF3B82F6);
    final Color themeSecondary = isVerified
        ? const Color(0xFF059669)
        : const Color(0xFF1D4ED8);
    final Color glowColor = isVerified
        ? AppStyles.successGreen
        : const Color(0xFF3B82F6);
    final Color shadowColor = isVerified
        ? const Color(0xFF059669)
        : const Color(0xFF2563EB);

    return Stack(
      children: [
        // ── Full-Screen Premium Background: Soft Layered Azure / Sage Gradient ──
        Positioned.fill(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeInOutCubic,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isVerified
                    ? const [
                        Color(0xFFFFFFFF),
                        Color(0xFFF7FDF9),
                        Color(0xFFEEFBF2),
                        Color(0xFFD1FADF),
                      ]
                    : const [
                        Color(0xFFFFFFFF),
                        Color(0xFFF8FAFC),
                        Color(0xFFEFF6FF),
                        Color(0xFFDBEAFE),
                      ],
                stops: const [0.0, 0.3, 0.65, 1.0],
              ),
            ),
          ),
        ),

        // ── Subtle Floating Ambient Light Blob 1 (Top-Left Azure Glow) ──
        Positioned.fill(
          child: Transform.scale(
            scale: 1.0 + breathe * 0.8,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeInOutCubic,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.6, -0.4),
                  radius: 0.70,
                  colors: [
                    glowColor.withValues(
                      alpha: isVerified ? 0.10 : (0.09 + breathe * 0.02),
                    ),
                    glowColor.withValues(alpha: 0.02),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
        ),

        // ── Subtle Floating Ambient Light Blob 2 (Top-Right Sky Glow) ──
        Positioned.fill(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeInOutCubic,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.65, -0.15),
                radius: 0.60,
                colors: [
                  glowColor.withValues(
                    alpha: isVerified ? 0.08 : (0.07 + breathe * 0.02),
                  ),
                  Colors.transparent,
                ],
                stops: const [0.0, 1.0],
              ),
            ),
          ),
        ),

        // ── Central Ambient Radial Light Bloom Behind Illustration ──
        Positioned.fill(
          child: Transform.scale(
            scale: 1.0 + breathe * 0.8,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeInOutCubic,
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.0, -0.28),
                  radius: 0.85,
                  colors: [
                    glowColor.withValues(
                      alpha: isVerified ? 0.15 : (0.13 + breathe * 0.03),
                    ),
                    glowColor.withValues(alpha: 0.04),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
        ),

        // ── Content Area: Vertically Centered with Generous Spacing ──
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 1. Hero Animation Section (Bespoke Geofence Radar & Coordinate Validation Illustration)
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        // Soft Ambient Radial Glow Backdrop with Breathing
                        Transform.scale(
                          scale: 1.0 + breathe * 1.5,
                          child: Container(
                            width: 230,
                            height: 230,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  glowColor.withValues(
                                    alpha: isVerified ? 0.25 : 0.22,
                                  ),
                                  glowColor.withValues(
                                    alpha: isVerified ? 0.07 : 0.06,
                                  ),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.45, 1.0],
                              ),
                            ),
                          ),
                        ),

                        // Floating Ambient Particles
                        RepaintBoundary(
                          child: CustomPaint(
                            size: const Size(210, 210),
                            painter: _LocationParticlesPainter(
                              animVal,
                              color: glowColor.withValues(alpha: 0.8),
                            ),
                          ),
                        ),

                        // Geofence Coordinate Radar Sweep & Perimeter Grid
                        RepaintBoundary(
                          child: CustomPaint(
                            size: const Size(200, 200),
                            painter: _GeofenceRadarPainter(
                              animationValue: animVal,
                              color: glowColor,
                              isVerified: isVerified,
                            ),
                          ),
                        ),

                        // Expanding Dual Ripple Rings
                        RepaintBoundary(
                          child: CustomPaint(
                            size: const Size(180, 180),
                            painter: _RippleRingsPainter(
                              animVal,
                              color: glowColor,
                            ),
                          ),
                        ),

                        // Rotating Orbital Rings
                        RepaintBoundary(
                          child: CustomPaint(
                            size: const Size(140, 140),
                            painter: _LocationOrbitRingsPainter(
                              rotation1: animVal * 2 * math.pi,
                              rotation2: -animVal * 2 * math.pi,
                              color: glowColor,
                              isVerified: isVerified,
                            ),
                          ),
                        ),

                        // Progress Ring
                        RepaintBoundary(
                          child: CustomPaint(
                            size: const Size(134, 134),
                            painter: _LocationProgressRingPainter(
                              animationValue: animVal,
                              isVerified: isVerified,
                            ),
                          ),
                        ),

                        // Hero Badge Container with Breathing, Float, Scale Bounce & Multi-Layer Shadows
                        Transform.translate(
                          offset: Offset(0, floatOffset),
                          child: Transform.scale(
                            scale: 1.0 + breathe,
                            child: ScaleTransition(
                              scale: Tween<double>(begin: 1.0, end: 1.15)
                                  .animate(
                                    CurvedAnimation(
                                      parent: _locationSuccessController,
                                      curve: Curves.elasticOut,
                                    ),
                                  ),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 400),
                                curve: Curves.easeOutCubic,
                                width: 96,
                                height: 96,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [themePrimary, themeSecondary],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: shadowColor.withValues(
                                        alpha: isVerified ? 0.42 : 0.38,
                                      ),
                                      blurRadius: 28,
                                      spreadRadius: 2,
                                      offset: const Offset(0, 10),
                                    ),
                                    BoxShadow(
                                      color: shadowColor.withValues(
                                        alpha: isVerified ? 0.22 : 0.20,
                                      ),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 350),
                                    switchInCurve: Curves.easeOutBack,
                                    switchOutCurve: Curves.easeInBack,
                                    transitionBuilder: (child, animation) {
                                      return ScaleTransition(
                                        scale: animation,
                                        child: FadeTransition(
                                          opacity: animation,
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: SizedBox(
                                      key: ValueKey<bool>(isVerified),
                                      width: 96,
                                      height: 96,
                                      child: CustomPaint(
                                        painter: _GeofenceBadgePainter(
                                          animationValue: animVal,
                                          isVerified: isVerified,
                                          primaryColor: themePrimary,
                                        ),
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

                    const SizedBox(height: 32),

                    // 2. Primary Heading Text
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        isVerified
                            ? 'Location Verified'
                            : 'Checking your location...',
                        key: ValueKey<bool>(isVerified),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // 3. Subtitle System with Smooth Transitions & Visual Hierarchy
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      switchInCurve: Curves.easeInOut,
                      switchOutCurve: Curves.easeInOut,
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0.0, 0.08),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        );
                      },
                      child: Text(
                        _getLocationSubtitleText(),
                        key: ValueKey<String>(_getLocationSubtitleText()),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14.5,
                          color: isVerified
                              ? const Color(0xFF059669)
                              : const Color(0xFF475569),
                          fontWeight: isVerified
                              ? FontWeight.w600
                              : FontWeight.w500,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLocationErrorState(_LocationErrorType errorType) {
    final info = _getLocationErrorInfo(errorType);
    final double animVal = _locationAnimController.value;
    final double floatOffset = math.sin(animVal * 2 * math.pi) * 3.5;
    final double breathe = math.sin(animVal * 2 * math.pi) * 0.03;

    return Stack(
      children: [
        // ── Full-Screen Premium Background: Soft White → Light Coral Gradient ──
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFFFFFFF),
                  Color(0xFFFFF9F8),
                  Color(0xFFFFF0EE),
                  Color(0xFFFDECE9),
                ],
                stops: [0.0, 0.3, 0.7, 1.0],
              ),
            ),
          ),
        ),

        // Subtle ambient radial glow with breathing animation
        Positioned.fill(
          child: Transform.scale(
            scale: 1.0 + breathe * 0.8,
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.0, -0.28),
                  radius: 0.75,
                  colors: [
                    info.glowColor.withValues(alpha: 0.10 + breathe * 0.03),
                    info.glowColor.withValues(alpha: 0.03),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
        ),

        // ── Content Area: Vertically Centered with Generous Spacing ──
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 1. Hero Animation (Part of the page, centered)
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        // Soft Radial Background Glow with Gentle Breathing
                        Transform.scale(
                          scale: 1.0 + breathe * 1.5,
                          child: Container(
                            width: 220,
                            height: 220,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  info.glowColor.withValues(alpha: 0.20),
                                  info.glowColor.withValues(alpha: 0.05),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.45, 1.0],
                              ),
                            ),
                          ),
                        ),

                        // Floating Ambient Particles
                        RepaintBoundary(
                          child: CustomPaint(
                            size: const Size(200, 200),
                            painter: _LocationParticlesPainter(
                              animVal,
                              color: info.glowColor.withValues(alpha: 0.8),
                            ),
                          ),
                        ),

                        // Dual Ripple Rings
                        RepaintBoundary(
                          child: CustomPaint(
                            size: const Size(180, 180),
                            painter: _RippleRingsPainter(
                              animVal,
                              color: info.glowColor,
                            ),
                          ),
                        ),

                        // Hero Icon Container with Layered Shadows & Soft Scale
                        Transform.translate(
                          offset: Offset(0, floatOffset),
                          child: Transform.scale(
                            scale: 1.0 + breathe,
                            child: Container(
                              width: 96,
                              height: 96,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: info.gradientColors,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: info.shadowColor.withValues(
                                      alpha: 0.38,
                                    ),
                                    blurRadius: 28,
                                    spreadRadius: 2,
                                    offset: const Offset(0, 10),
                                  ),
                                  BoxShadow(
                                    color: info.shadowColor.withValues(
                                      alpha: 0.20,
                                    ),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Icon(
                                  info.icon,
                                  color: Colors.white,
                                  size: 44,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 32),

                    // 2. Heading / Title
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        info.title,
                        key: ValueKey<String>(info.title),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // 3. Explanation Message
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        info.description,
                        key: ValueKey<String>(info.description),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 14.5,
                          color: Color(0xFF475569),
                          fontWeight: FontWeight.w500,
                          height: 1.5,
                        ),
                      ),
                    ),

                    if (info.subtext != null) ...[
                      const SizedBox(height: 10),
                      // 4. Supporting Instruction Subtext
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          info.subtext!,
                          key: ValueKey<String>(info.subtext!),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF94A3B8),
                            fontWeight: FontWeight.w400,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 36),

                    // 5. Vertically Stacked Action Buttons
                    // Primary Action Button
                    Container(
                      width: double.infinity,
                      height: 54,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: info.gradientColors,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: info.shadowColor.withValues(alpha: 0.35),
                            blurRadius: 18,
                            offset: const Offset(0, 7),
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _handleLocationErrorAction(errorType),
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  info.primaryButtonIcon,
                                  color: Colors.white,
                                  size: 21,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  info.primaryButtonText,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Secondary Back Button
                    Container(
                      width: double.infinity,
                      height: 50,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFFE2E8F0),
                          width: 1.3,
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => Navigator.of(context).pop(),
                          child: const Center(
                            child: Text(
                              'Back',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF64748B),
                                letterSpacing: -0.2,
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
        ),
      ],
    );
  }
}

// ─── _MiniChallengeProgressIndicator — Precision connected component ─────
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
          // Background connector track — starts at node 1 edge (24px) & ends at node 2 edge (24px)
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

          // Animated foreground connector fill — smooth left-to-right easeOutCubic capsule fill with glow
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

// ─── _NeonChip — Premium Stepper Chip (Fintech / Biometric Identity) ──────
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

            final elapsedMs =
                DateTime.now().difference(_startTime).inMilliseconds;
            final double stageProgress =
                ((elapsedMs % 1600) / 1600.0).clamp(0.0, 1.0);

            // Smooth progressive confidence count-up (48.0% -> 99.8%)
            const baseByStage = [48.0, 74.2, 89.6, 97.4];
            const targetByStage = [74.2, 89.6, 97.4, 99.8];
            final currentStage = _messageIndex.clamp(0, 3);
            final base = baseByStage[currentStage];
            final target = targetByStage[currentStage];
            final curvedStage = Curves.easeOutCubic.transform(stageProgress);
            final double confidence =
                (base + (target - base) * curvedStage).clamp(48.0, 99.8);

            return Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // Enhanced ambient breathing radial glow behind the percentage text (Positioned.fill so it does not inflate Stack height)
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
                              const Color(0xFF0284C7).withValues(
                                alpha: 0.20 + 0.08 * pulse,
                              ),
                              const Color(0xFF38BDF8).withValues(
                                alpha: 0.10 + 0.05 * pulse,
                              ),
                              const Color(0xFF818CF8).withValues(
                                alpha: 0.04 + 0.02 * pulse,
                              ),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.42, 0.72, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Hero Large Confidence Percentage Display with Rich Gradient Styling
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
                            Color(0xFF0284C7), // Vibrant Sky 600
                            Color(0xFF1D4ED8), // Cobalt Blue 700
                            Color(0xFF0F172A), // Deep Slate 900
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
                          colors: [
                            Color(0xFF0284C7),
                            Color(0xFF2563EB),
                          ],
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
                            color: const Color(0xFF2563EB).withValues(
                              alpha: 0.35 + (0.30 * pulse),
                            ),
                            blurRadius: 8 + (4 * pulse),
                            offset: const Offset(0, 1.5),
                          ),
                          BoxShadow(
                            color: const Color(0xFF60A5FA).withValues(
                              alpha: 0.25 + (0.20 * pulse),
                            ),
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

// ─── _PulsingCameraLoader ─────────────────────────────────────────────────────
class _PulsingCameraLoader extends StatefulWidget {
  @override
  State<_PulsingCameraLoader> createState() => _PulsingCameraLoaderState();
}

class _PulsingCameraLoaderState extends State<_PulsingCameraLoader>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _rotateController;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _scale = Tween<double>(begin: 0.90, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _opacity = Tween<double>(begin: 0.6, end: 0.95).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _rotateController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF0F4FF),
      child: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_pulseController, _rotateController]),
          builder: (context, child) {
            return SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size(120, 120),
                    painter: _OrbitRingsPainter(
                      rotation1: _rotateController.value * 2 * math.pi,
                      rotation2: -_rotateController.value * 2 * math.pi,
                      color: const Color(0xFF1A73E8),
                    ),
                  ),
                  ScaleTransition(
                    scale: _scale,
                    child: FadeTransition(
                      opacity: _opacity,
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF1A73E8),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF1A73E8,
                              ).withValues(alpha: 0.3),
                              blurRadius: 8,
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
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

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

    // 1. Multi-layered Ambient Breathing Radial Glow (Face ID-style soft pulse)
    if (phase != _Phase.processing && phase != _Phase.done) {
      final double glowSpread = 8.0 + (16.0 * pulseValue);
      final double outerHaloRadius = radius + glowSpread;

      // Layer A: Wide diffused outer radial gradient aura
      final Paint outerGlowPaint = Paint()
        ..shader = RadialGradient(
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
        ).createShader(Rect.fromCircle(center: center, radius: outerHaloRadius));

      canvas.drawCircle(center, outerHaloRadius, outerGlowPaint);

      // Layer B: Mid-range soft blurred glow ring
      final midGlowPaint = Paint()
        ..color = baseColor.withValues(alpha: 0.22 + (0.28 * pulseValue))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10.0 + (6.0 * pulseValue)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10.0 + (8.0 * pulseValue));

      canvas.drawCircle(center, radius, midGlowPaint);

      // Layer C: Core energetic neon bloom
      final coreGlowPaint = Paint()
        ..color = baseColor.withValues(alpha: 0.40 + (0.35 * pulseValue))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.0
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4.0 + (3.0 * pulseValue));

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

  // Pre-configured deterministic particle dataset for optimal runtime performance
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
        // High-velocity streak
        speed = 130.0 + random.nextDouble() * 95.0;
        size = 2.2 + random.nextDouble() * 1.4;
        color = (random.nextDouble() > 0.4)
            ? const Color(0xFF10B981)
            : (random.nextDouble() > 0.5
                ? const Color(0xFF34D399)
                : const Color(0xFF38BDF8));
      } else if (type == 1) {
        // Medium-velocity glowing dot
        speed = 65.0 + random.nextDouble() * 70.0;
        size = 2.0 + random.nextDouble() * 1.8;
        color = (random.nextDouble() > 0.3)
            ? const Color(0xFF34D399)
            : const Color(0xFFFFFFFF);
      } else {
        // Micro-sparkle
        speed = 30.0 + random.nextDouble() * 40.0;
        size = 1.2 + random.nextDouble() * 1.2;
        color = (random.nextDouble() > 0.4)
            ? const Color(0xFFFDE047)
            : const Color(0xFF38BDF8);
      }

      list.add(_BurstParticle(
        angle: angle,
        speed: speed,
        size: size,
        type: type,
        color: color,
        seed: random.nextDouble(),
      ));
    }
    return list;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.0 || progress >= 1.0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.width / 2;

    // ── Layer 1: Expanding Ring Glow Pulse (Success Shockwave) ──
    // Expands smoothly from face circle border over first 60% of animation
    const ringCutoff = 0.60;
    if (progress < ringCutoff) {
      final ringNorm = progress / ringCutoff;
      final ringCurved = Curves.easeOutCubic.transform(ringNorm);
      final ringRadius = baseRadius + 34.0 * ringCurved;
      final ringFade = (1.0 - ringCurved);

      // Outer soft aura wave
      final ringAuraPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0 * ringFade
        ..color = const Color(0xFF38BDF8).withValues(alpha: 0.28 * ringFade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);
      canvas.drawCircle(center, ringRadius, ringAuraPaint);

      // Core energetic emerald shockwave
      final ringCorePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0 * ringFade
        ..color = const Color(0xFF10B981).withValues(alpha: 0.75 * ringFade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
      canvas.drawCircle(center, ringRadius, ringCorePaint);

      // Crisp inner bright line
      final ringLinePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * ringFade
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.85 * ringFade);
      canvas.drawCircle(center, ringRadius, ringLinePaint);
    }

    // ── Layer 2: Designed Radial Particle Burst ──
    final curvedProgress = Curves.easeOutCubic.transform(progress);

    // Dynamic alpha curve: rapid peak at 120-150ms then smooth graceful fadeout
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
        // High-velocity streak trail
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

        // Bright leading core spark
        final headPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.white.withValues(alpha: 0.90 * masterAlpha);
        canvas.drawCircle(pPos, p.size * 0.7, headPaint);
      } else if (p.type == 1) {
        // Radial glowing dot particle
        final haloPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = p.color.withValues(alpha: 0.35 * masterAlpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
        canvas.drawCircle(pPos, p.size * 2.2, haloPaint);

        // Inner solid core
        final corePaint = Paint()
          ..style = PaintingStyle.fill
          ..color = Color.lerp(p.color, Colors.white, 0.45)!
              .withValues(alpha: 0.95 * masterAlpha);
        canvas.drawCircle(pPos, p.size, corePaint);
      } else {
        // Micro-sparkle with twinkle
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

// ─── _MiniRingPainter — Premium Biometric Countdown Ring ─────────────────
class _MiniRingPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _MiniRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 6) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Track background ring
    final trackPaint = Paint()
      ..color = AppStyles.primaryBlue.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi, false, trackPaint);

    if (progress > 0) {
      // Soft glow shadow behind active ring
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

      // Primary gradient active ring stroke
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

// ─── _LocationProgressRingPainter ─────────────────────────────────────────────
class _LocationProgressRingPainter extends CustomPainter {
  final double animationValue;
  final bool isVerified;

  _LocationProgressRingPainter({
    required this.animationValue,
    required this.isVerified,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = (isVerified ? AppStyles.successGreen : const Color(0xFF3B82F6))
          .withValues(alpha: 0.12);
    canvas.drawCircle(center, radius, trackPaint);

    if (isVerified) {
      final verifiedPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.8
        ..color = AppStyles.successGreen;
      canvas.drawCircle(center, radius, verifiedPaint);
    } else {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(animationValue * 2 * math.pi);
      canvas.translate(-center.dx, -center.dy);

      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [
            const Color(0xFF3B82F6),
            const Color(0xFF60A5FA).withValues(alpha: 0.6),
            const Color(0xFF3B82F6).withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 0.75],
        ).createShader(rect);

      canvas.drawArc(rect, 0, math.pi * 1.5, false, arcPaint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _LocationProgressRingPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.isVerified != isVerified;
  }
}

// ─── _LocationOrbitRingsPainter ───────────────────────────────────────────────
class _LocationOrbitRingsPainter extends CustomPainter {
  final double rotation1;
  final double rotation2;
  final Color color;
  final bool isVerified;

  _LocationOrbitRingsPainter({
    required this.rotation1,
    required this.rotation2,
    required this.color,
    required this.isVerified,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Outer orbital ring (radius 62)
    final outerRect = Rect.fromCircle(center: center, radius: 62);
    final outerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: isVerified ? 0.4 : 0.6),
          color.withValues(alpha: 0.05),
          color.withValues(alpha: isVerified ? 0.4 : 0.6),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(outerRect);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation1);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawArc(outerRect, 0, math.pi * 0.7, false, outerPaint);
    canvas.drawArc(outerRect, math.pi, math.pi * 0.7, false, outerPaint);
    canvas.restore();

    // Inner orbital ring (radius 54)
    final innerRect = Rect.fromCircle(center: center, radius: 54);
    final innerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: isVerified ? 0.35 : 0.5),
          color.withValues(alpha: 0.05),
          color.withValues(alpha: isVerified ? 0.35 : 0.5),
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
  bool shouldRepaint(covariant _LocationOrbitRingsPainter oldDelegate) {
    return oldDelegate.rotation1 != rotation1 ||
        oldDelegate.rotation2 != rotation2 ||
        oldDelegate.color != color ||
        oldDelegate.isVerified != isVerified;
  }
}

// ─── _RippleRingsPainter ──────────────────────────────────────────────────────
class _RippleRingsPainter extends CustomPainter {
  final double animationValue;
  final Color color;

  _RippleRingsPainter(
    this.animationValue, {
    this.color = const Color(0xFF3B82F6),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = 48.0;

    for (int i = 0; i < 2; i++) {
      final progress = (animationValue + i * 0.5) % 1.0;
      final curvedProgress = Curves.easeOutQuad.transform(progress);
      final radius = baseRadius + (curvedProgress * 38.0);
      final opacity = (1.0 - curvedProgress).clamp(0.0, 1.0);

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withValues(alpha: opacity * 0.35);

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RippleRingsPainter oldDelegate) => true;
}

// ─── _LocationParticlesPainter ────────────────────────────────────────────────
class _LocationParticlesPainter extends CustomPainter {
  final double animationValue;
  final Color color;

  _LocationParticlesPainter(
    this.animationValue, {
    this.color = const Color(0xFF60A5FA),
  });

  static const List<_ParticleData> _particles = [
    _ParticleData(angle: 0.4, distance: 75, radius: 2.2, phase: 0.0),
    _ParticleData(angle: 1.6, distance: 82, radius: 1.8, phase: 0.3),
    _ParticleData(angle: 2.7, distance: 70, radius: 2.5, phase: 0.6),
    _ParticleData(angle: 3.8, distance: 80, radius: 1.6, phase: 0.2),
    _ParticleData(angle: 4.9, distance: 74, radius: 2.0, phase: 0.8),
    _ParticleData(angle: 5.8, distance: 85, radius: 2.4, phase: 0.5),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    for (final p in _particles) {
      final t = (animationValue + p.phase) % 1.0;
      final floatDist = p.distance + math.sin(t * 2 * math.pi) * 6.0;
      final floatAngle = p.angle + math.cos(t * 2 * math.pi) * 0.15;
      final opacity = (0.25 + 0.45 * (0.5 + 0.5 * math.sin(t * 2 * math.pi)))
          .clamp(0.0, 1.0);

      final x = center.dx + floatDist * math.cos(floatAngle);
      final y = center.dy + floatDist * math.sin(floatAngle);

      final paint = Paint()
        ..color = color.withValues(alpha: opacity * 0.6)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(x, y), p.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LocationParticlesPainter oldDelegate) => true;
}

class _ParticleData {
  final double angle;
  final double distance;
  final double radius;
  final double phase;

  const _ParticleData({
    required this.angle,
    required this.distance,
    required this.radius,
    required this.phase,
  });
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
    // Clean, crisp light biometric gradient transition from pure white at top to soft pale azure at bottom
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
    // 2A. Center Biometric Glow (behind camera/face area)
    final centerPos = Offset(w * 0.50, h * 0.28);
    final centerRadius = w * 0.62 + breathe * 20.0;
    final centerPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF38BDF8).withValues(
            alpha: (0.24 + breathe * 0.05).clamp(0.0, 1.0),
          ),
          const Color(0xFF60A5FA).withValues(
            alpha: (0.13 + breathe * 0.03).clamp(0.0, 1.0),
          ),
          const Color(0xFF3B82F6).withValues(
            alpha: (0.04 + breathe * 0.02).clamp(0.0, 1.0),
          ),
          Colors.transparent,
        ],
        stops: const [0.0, 0.40, 0.72, 1.0],
      ).createShader(Rect.fromCircle(center: centerPos, radius: centerRadius));
    canvas.drawCircle(centerPos, centerRadius, centerPaint);

    // 2B. Top-Right Soft Cyan Ambient Glow Field
    final trCenter = Offset(w * 0.88, h * 0.10);
    final trRadius = w * 0.65;
    final trPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF38BDF8).withValues(
            alpha: (0.18 + breathe * 0.03).clamp(0.0, 1.0),
          ),
          const Color(0xFF60A5FA).withValues(
            alpha: (0.08 + breathe * 0.02).clamp(0.0, 1.0),
          ),
          Colors.transparent,
        ],
        stops: const [0.0, 0.50, 1.0],
      ).createShader(Rect.fromCircle(center: trCenter, radius: trRadius));
    canvas.drawCircle(trCenter, trRadius, trPaint);

    // 2C. Lower-Left Deep Blue/Indigo Ambient Glow Field
    final blCenter = Offset(w * 0.12, h * 0.80);
    final blRadius = w * 0.70;
    final blPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF3B82F6).withValues(
            alpha: (0.16 + (0.04 - breathe) * 0.03).clamp(0.0, 1.0),
          ),
          const Color(0xFF818CF8).withValues(
            alpha: (0.10 + (0.04 - breathe) * 0.02).clamp(0.0, 1.0),
          ),
          Colors.transparent,
        ],
        stops: const [0.0, 0.52, 1.0],
      ).createShader(Rect.fromCircle(center: blCenter, radius: blRadius));
    canvas.drawCircle(blCenter, blRadius, blPaint);

    // 2D. Lower-Right Soft Azure Glow Field
    final brCenter = Offset(w * 0.86, h * 0.75);
    final brRadius = w * 0.52;
    final brPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF00B4D8).withValues(
            alpha: (0.11 + breathe * 0.025).clamp(0.0, 1.0),
          ),
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
      final ringAlpha = ((1.0 - easeProgress) * (0.16 + breathe * 0.04))
          .clamp(0.0, 1.0);

      if (ringAlpha > 0.01) {
        ringBasePaint
          ..strokeWidth = 1.2 * (1.0 - easeProgress * 0.3)
          ..color = const Color(0xFF38BDF8).withValues(alpha: ringAlpha);
        canvas.drawCircle(centerPos, ringRadius, ringBasePaint);
      }
    }

    // ── Layer 4: Subtle Biometric Wave Ribbons ──
    // Wave 1: Upper-middle flowing ribbon
    final wave1Paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF38BDF8).withValues(
        alpha: (0.12 + breathe * 0.04).clamp(0.0, 1.0),
      );

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

    // Wave 2: Lower-middle flowing ribbon
    final wave2Paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF3B82F6).withValues(
        alpha: (0.10 + (0.04 - breathe) * 0.03).clamp(0.0, 1.0),
      );

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

    // Wave 3: Bottom counter-wave
    final wave3Paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = const Color(0xFF818CF8).withValues(
        alpha: (0.08 + breathe * 0.02).clamp(0.0, 1.0),
      );

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

      // Faint outer aura
      particleHaloPaint.color = const Color(0xFF38BDF8).withValues(
        alpha: alpha * 0.35,
      );
      canvas.drawCircle(pos, 4.0, particleHaloPaint);

      // Core particle
      particlePaint.color = const Color(0xFF38BDF8).withValues(alpha: alpha);
      canvas.drawCircle(pos, 1.6, particlePaint);
    }
  }

  @override
  bool shouldRepaint(
    covariant _FaceVerificationAmbientBackgroundPainter oldDelegate,
  ) =>
      oldDelegate.pulseValue != pulseValue;
}

// ─── _GeofenceRadarPainter ────────────────────────────────────────────────────
class _GeofenceRadarPainter extends CustomPainter {
  final double animationValue;
  final Color color;
  final bool isVerified;

  _GeofenceRadarPainter({
    required this.animationValue,
    required this.color,
    required this.isVerified,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Concentric Geofence Zone Boundary Rings
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color.withValues(alpha: isVerified ? 0.22 : 0.14);

    // Inner Safety Zone & Mid Geofence Zone Circles
    canvas.drawCircle(center, maxRadius * 0.50, ringPaint);
    canvas.drawCircle(center, maxRadius * 0.70, ringPaint);

    // Outer Geofence Zone Boundary (Fine Dashed Ring)
    final dashPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color.withValues(alpha: isVerified ? 0.32 : 0.20);

    const int dashCount = 32;
    const double dashAngle = (2 * math.pi) / dashCount;
    for (int i = 0; i < dashCount; i++) {
      final startAngle = i * dashAngle;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: maxRadius * 0.90),
        startAngle,
        dashAngle * 0.50,
        false,
        dashPaint,
      );
    }

    // Coordinate Telemetry Tick Marks (Cardinal & Ordinal: N, NE, E, SE, S, SW, W, NW)
    final tickPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: isVerified ? 0.45 : 0.30);

    for (int i = 0; i < 8; i++) {
      final angle = i * (math.pi / 4);
      final isMajor = i % 2 == 0;
      final r1 = maxRadius * (isMajor ? 0.82 : 0.85);
      final r2 = maxRadius * (isMajor ? 0.94 : 0.90);
      final p1 = Offset(
        center.dx + r1 * math.cos(angle),
        center.dy + r1 * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + r2 * math.cos(angle),
        center.dy + r2 * math.sin(angle),
      );
      canvas.drawLine(p1, p2, tickPaint);
    }

    // Rotating Radar Sweep Beam (Scanning GPS Coordinates)
    if (!isVerified) {
      final sweepAngle = animationValue * 2 * math.pi;
      final sweepRadius = maxRadius * 0.90;
      final sweepRect = Rect.fromCircle(center: center, radius: sweepRadius);

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(sweepAngle);
      canvas.translate(-center.dx, -center.dy);

      final radarPaint = Paint()
        ..style = PaintingStyle.fill
        ..shader = SweepGradient(
          center: Alignment.center,
          startAngle: 0.0,
          endAngle: math.pi * 0.5,
          colors: [
            color.withValues(alpha: 0.20),
            color.withValues(alpha: 0.07),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(sweepRect);

      canvas.drawArc(sweepRect, 0.0, math.pi * 0.5, true, radarPaint);

      // Radar leading edge scan line with soft glow
      final leadLinePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            color.withValues(alpha: 0.15),
            color.withValues(alpha: 0.85),
          ],
        ).createShader(Rect.fromLTWH(center.dx, center.dy, sweepRadius, 2));

      canvas.drawLine(
        center,
        Offset(center.dx + sweepRadius, center.dy),
        leadLinePaint,
      );
      canvas.restore();

      // Satellite / Coordinate Nodes
      final nodePaint = Paint()..style = PaintingStyle.fill;
      final satCoords = [
        Offset(
          center.dx + maxRadius * 0.52 * math.cos(1.2),
          center.dy + maxRadius * 0.52 * math.sin(1.2),
        ),
        Offset(
          center.dx + maxRadius * 0.72 * math.cos(3.6),
          center.dy + maxRadius * 0.72 * math.sin(3.6),
        ),
        Offset(
          center.dx + maxRadius * 0.60 * math.cos(5.2),
          center.dy + maxRadius * 0.60 * math.sin(5.2),
        ),
      ];

      for (int i = 0; i < satCoords.length; i++) {
        final nodePos = satCoords[i];
        final nodeDistAngle =
            (math.atan2(nodePos.dy - center.dy, nodePos.dx - center.dx) +
                2 * math.pi) %
            (2 * math.pi);
        final angleDiff =
            ((sweepAngle - nodeDistAngle) % (2 * math.pi) + 2 * math.pi) %
            (2 * math.pi);
        final isPinged = angleDiff < 0.8;
        final pingAlpha =
            isPinged ? (1.0 - (angleDiff / 0.8)).clamp(0.0, 1.0) : 0.0;

        // Node core
        nodePaint.color = color.withValues(alpha: 0.4 + pingAlpha * 0.5);
        canvas.drawCircle(nodePos, 2.4, nodePaint);

        // Ping ripple
        if (pingAlpha > 0.05) {
          final pingPaint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = color.withValues(alpha: pingAlpha * 0.45);
          canvas.drawCircle(nodePos, 2.4 + (1.0 - pingAlpha) * 8.0, pingPaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GeofenceRadarPainter oldDelegate) => true;
}

// ─── _GeofenceBadgePainter ────────────────────────────────────────────────────
class _GeofenceBadgePainter extends CustomPainter {
  final double animationValue;
  final bool isVerified;
  final Color primaryColor;

  _GeofenceBadgePainter({
    required this.animationValue,
    required this.isVerified,
    required this.primaryColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    if (isVerified) {
      // Verified State: Shield with bold Checkmark & radiant success bloom
      final checkPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final path = Path()
        ..moveTo(center.dx - 12, center.dy + 1)
        ..lineTo(center.dx - 3, center.dy + 10)
        ..lineTo(center.dx + 13, center.dy - 8);

      canvas.drawPath(path, checkPaint);

      // Subtle outer checkmark glow
      final glowPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);

      canvas.drawPath(path, glowPaint);
    } else {
      // Checking State: Modern Attendance Zone Security Shield & GPS Target Reticle
      final shieldPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      // Draw modern streamlined attendance security shield
      final shieldTop = center.dy - 17;
      final shieldBottom = center.dy + 14;
      const shieldHalfW = 15.0;

      final shieldPath = Path()
        ..moveTo(center.dx - shieldHalfW, shieldTop)
        ..lineTo(center.dx + shieldHalfW, shieldTop)
        ..lineTo(center.dx + shieldHalfW, shieldTop + 14)
        ..quadraticBezierTo(
          center.dx + shieldHalfW * 0.85,
          shieldBottom - 4,
          center.dx,
          shieldBottom,
        )
        ..quadraticBezierTo(
          center.dx - shieldHalfW * 0.85,
          shieldBottom - 4,
          center.dx - shieldHalfW,
          shieldTop + 14,
        )
        ..close();

      canvas.drawPath(shieldPath, shieldPaint);

      // Central precision target core (concentric validation circle)
      final coreCenter = Offset(center.dx, center.dy - 2);
      final coreFillPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;

      canvas.drawCircle(coreCenter, 5.0, coreFillPaint);

      final coreInnerPaint = Paint()
        ..color = primaryColor
        ..style = PaintingStyle.fill;

      canvas.drawCircle(coreCenter, 2.8, coreInnerPaint);

      // Micro crosshair ticks on core
      final tickPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(coreCenter.dx - 8.5, coreCenter.dy),
        Offset(coreCenter.dx - 5.5, coreCenter.dy),
        tickPaint,
      );
      canvas.drawLine(
        Offset(coreCenter.dx + 5.5, coreCenter.dy),
        Offset(coreCenter.dx + 8.5, coreCenter.dy),
        tickPaint,
      );
      canvas.drawLine(
        Offset(coreCenter.dx, coreCenter.dy - 8.5),
        Offset(coreCenter.dx, coreCenter.dy - 5.5),
        tickPaint,
      );
      canvas.drawLine(
        Offset(coreCenter.dx, coreCenter.dy + 5.5),
        Offset(coreCenter.dx, coreCenter.dy + 8.5),
        tickPaint,
      );

      // Perspective Elliptical Geofence Ground Target Wave
      final waveProgress = (animationValue * 1.5) % 1.0;
      final wavePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withValues(alpha: (1.0 - waveProgress) * 0.6);

      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(center.dx, shieldBottom + 4),
          width: 22 + waveProgress * 20,
          height: 7 + waveProgress * 6,
        ),
        wavePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GeofenceBadgePainter oldDelegate) =>
      oldDelegate.animationValue != animationValue ||
      oldDelegate.isVerified != isVerified ||
      oldDelegate.primaryColor != primaryColor;
}
