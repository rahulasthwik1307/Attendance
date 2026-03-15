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

class FaceVerificationScreen extends StatefulWidget {
  const FaceVerificationScreen({super.key});

  @override
  State<FaceVerificationScreen> createState() => _FaceVerificationScreenState();
}

class _FaceVerificationScreenState extends State<FaceVerificationScreen>
    with TickerProviderStateMixin {
  // ─── Animation controllers ──────────────────────────────────────────────
  late AnimationController _pulseController;
  late AnimationController _textFadeController;
  late AnimationController _blinkCountdownController;
  late AnimationController _successBounceController;
  late AnimationController _particleController;
  late AnimationController _scanLineController;

  // ─── Location card ──────────────────────────────────────────────────────
  late AnimationController _locationCardController;
  late Animation<double> _locationFade;
  bool _locationVerified = false;

  // ─── Timer ring ─────────────────────────────────────────────────────────
  late AnimationController _timerPulseController;
  late Animation<double> _timerPulseAnim;
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
  static const int _framesPerPhase = 5;

  List<double>? _embeddingA;
  List<double>? _embeddingB;
  List<double>? _embeddingC;

  int _attemptCount = 1;

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

  // ─────────────────────────────────────────────────────────────────────────
  // DYNAMIC THRESHOLD — adjusts threshold based on score consistency
  // If scores are very consistent (low variance), we can use a slightly
  // lower threshold since the quality is good.
  // ─────────────────────────────────────────────────────────────────────────
  double _calculateDynamicThreshold(List<double> scores) {
    if (scores.isEmpty) return 0.75;

    // Calculate mean
    double mean = scores.reduce((a, b) => a + b) / scores.length;

    // Calculate variance (how spread out the scores are)
    double variance =
        scores.map((s) => (s - mean) * (s - mean)).reduce((a, b) => a + b) /
        scores.length;

    // Low variance means scores are very consistent (good quality)
    // High variance means scores are jumping around (poor quality)
    if (variance < 0.01) {
      return 0.75; // Consistent scores = good lighting/pose
    } else if (variance < 0.05) {
      return 0.75; // Moderately consistent
    } else {
      return 0.75; // Default threshold for inconsistent scores
    }
  }

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
    "Processing…": "Comparing your face",
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

    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _locationCardController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _locationFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _locationCardController, curve: Curves.easeOut),
    );

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

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _locationCardController.forward();

      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      // Real location check
      final bool locationOk = await _checkGeofence();
      if (!mounted) return;

      if (!locationOk) {
        setState(() {
          _locationVerified = false;
        });
        // Show error and go back after 2 seconds
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You must be on campus to mark attendance.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
        await Future.delayed(const Duration(seconds: 3));
        if (mounted) Navigator.of(context).pop();
        return;
      }

      setState(() {
        _locationVerified = true;
      });
      await Future.delayed(const Duration(milliseconds: 1000));
      if (!mounted) return;
      await _locationCardController.reverse();

      // Auto-start camera immediately after location check passes
      await _initializeCamera();
    });
  }

  // ── CHANGE THESE COORDINATES BEFORE EXECUTION ──
  // Currently set to test location — replace with college coordinates tomorrow
  static const double _campusLat = 17.409904;
  static const double _campusLng = 78.590623;
  static const double _campusRadiusMeters = 200.0;

  Future<bool> _checkGeofence() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return false;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return false;
      }
      if (permission == LocationPermission.deniedForever) return false;

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        _campusLat,
        _campusLng,
      );

      debugPrint(
        '[GEOFENCE] Distance from campus: ${distance.toStringAsFixed(1)}m',
      );
      return distance <= _campusRadiusMeters;
    } catch (e) {
      debugPrint('[GEOFENCE] Error: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CAMERA INITIALIZATION
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _initializeCamera() async {
    try {
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
      if (_embeddingA == null || _embeddingB == null || _embeddingC == null) {
        return; // error already set
      }

      // Start camera stream for face detection
      await _cameraController!.startImageStream(_onCameraFrame);

      _setPhase(_Phase.positioning);

      if (mounted) setState(() => _cameraPreviewReady = true);

      _ringController.forward();
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
        final embAJson = prefs.getString('emb_a');
        final embBJson = prefs.getString('emb_b');
        final embCJson = prefs.getString('emb_c');
        if (embAJson != null && embBJson != null && embCJson != null) {
          _embeddingA = (jsonDecode(embAJson) as List)
              .map((e) => (e as num).toDouble())
              .toList();
          _embeddingB = (jsonDecode(embBJson) as List)
              .map((e) => (e as num).toDouble())
              .toList();
          _embeddingC = (jsonDecode(embCJson) as List)
              .map((e) => (e as num).toDouble())
              .toList();
          debugPrint('[FACE_VER] Embeddings A, B, C loaded from cache');
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
          .select('embedding_a, embedding_b, embedding_c')
          .eq('id', user.id)
          .maybeSingle();

      if (data == null ||
          data['embedding_a'] == null ||
          data['embedding_b'] == null ||
          data['embedding_c'] == null) {
        _setError('Could not load face profile. Please try again.');
        return;
      }

      _embeddingA = (data['embedding_a'] as List)
          .map((e) => (e as num).toDouble())
          .toList();
      _embeddingB = (data['embedding_b'] as List)
          .map((e) => (e as num).toDouble())
          .toList();
      _embeddingC = (data['embedding_c'] as List)
          .map((e) => (e as num).toDouble())
          .toList();

      // Clear any previous user's cached embeddings first
      await prefs.remove('emb_a');
      await prefs.remove('emb_b');
      await prefs.remove('emb_c');
      await prefs.remove('emb_student_id');
      await prefs.remove('emb_cached_at');
      // Cache for next time
      await prefs.setString('emb_a', jsonEncode(_embeddingA));
      await prefs.setString('emb_b', jsonEncode(_embeddingB));
      await prefs.setString('emb_c', jsonEncode(_embeddingC));
      await prefs.setString('emb_student_id', user.id);
      await prefs.setInt('emb_cached_at', now);
      debugPrint(
        '[FACE_VER] Embeddings A, B, C loaded from Supabase and cached',
      );
    } catch (e) {
      _setError('Could not load face profile. Please try again.');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CAMERA FRAME PROCESSING — rate-limited to 10fps
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _onCameraFrame(CameraImage cameraImage) async {
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

      final Face? face = _selectBiggestCenteredFace(faces, cameraImage);
      if (face == null) {
        _updateInstruction('Fit your face in the circle', animate: false);
        _isProcessingFrame = false;
        return;
      }

      _pushSmoothing(face);

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
          if (mounted && !_challengeVerified) {
            setState(() => _borderColor = AppStyles.primaryBlue);
          }
        }
        break;
      default:
        break;
    }

    if (detected) {
      _challengeVerified = true;
      _livenessService.reset();
      _challengeStartTime = null;
      _blinkCountdownController.stop();

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
    if (_liveEmbeddings.length >= _framesPerPhase) return;

    final now = DateTime.now();
    if (now.difference(_lastCaptureTime).inMilliseconds < 600) return;

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

    // Grab frame
    final Uint8List? jpegBytes = await _captureCurrentFrame();
    if (jpegBytes == null) return;

    // Generate embedding
    final emb = await _landmarkService.generateEmbedding(
      jpegBytes: jpegBytes,
      face: face,
    );
    if (emb != null) {
      _liveEmbeddings.add(emb);

      // Update progress only when embedding succeeded
      setState(() {
        _captureProgress++;
        _borderColor = AppStyles.successGreen;
      });
      HapticFeedback.lightImpact();

      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted && _phase == _Phase.capturing) {
          setState(() => _borderColor = AppStyles.primaryBlue);
        }
      });
    } else {
      _updateInstruction(
        'Improve lighting',
        subtitle: 'Move away from bright windows or dark areas',
        animate: false,
      );
    }

    _lastCaptureTime = DateTime.now();

    // Check if done
    if (_liveEmbeddings.length >= _framesPerPhase) {
      try {
        await _cameraController?.stopImageStream();
      } catch (_) {}

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

    _updateInstruction('Processing…', subtitle: 'Comparing your face');

    try {
      // Calculate dynamic threshold based on front scores
      final List<double> frontScores = _liveEmbeddings
          .map((e) => _landmarkService.cosineSimilarity(e, _embeddingA!))
          .toList();
      final double dynamicThreshold = _calculateDynamicThreshold(frontScores);

      final result = _landmarkService.verifyFace(
        liveEmbeddings: _liveEmbeddings,
        storedEmbeddingA: _embeddingA!,
        storedEmbeddingB: _embeddingB!,
        storedEmbeddingC: _embeddingC!,
        threshold: 0.75,
      );

      debugPrint(
        '[FACE_VER] Score: ${result.score.toStringAsFixed(4)} | Match: ${result.isMatch} | Message: ${result.message} | LiveFrames: ${_liveEmbeddings.length} | EmbALen: ${_embeddingA?.length} | EmbBLen: ${_embeddingB?.length} | EmbCLen: ${_embeddingC?.length} | DynThreshold: ${dynamicThreshold.toStringAsFixed(4)}',
      );

      if (result.isMatch) {
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
        if (!mounted) return;

        _countdownTimer?.cancel();

        // Save college attendance record
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
            debugPrint('[FACE_VER] College attendance saved');
          }
        } catch (e) {
          debugPrint('[FACE_VER] Failed to save college attendance: $e');
        }

        if (!mounted) return;

        final String? mode =
            ModalRoute.of(context)?.settings.arguments as String?;
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
        // ── Failure ──
        setState(() => _borderColor = AppStyles.errorRed);
        _updateInstruction(
          'Verification Failed',
          subtitle: 'Face did not match',
        );

        if (_attemptCount < 3) {
          await Future.delayed(const Duration(milliseconds: 1200));
          if (!mounted) return;

          _attemptCount++;
          _liveEmbeddings.clear();
          _livenessService.resetCalibration();
          _clearSmoothing();
          _challengeVerified = false;
          _captureProgress = 0;
          _challengeStartTime = null;
          _blinkCountdownController.reset();
          _steadyStartTime = null;
          _isFaceReady = false;
          _lastKnownBlinkCount = 0;

          setState(() => _borderColor = AppStyles.primaryBlue);

          // Restart camera stream
          try {
            await _cameraController!.startImageStream(_onCameraFrame);
          } catch (_) {}

          _setPhase(_Phase.positioning);
        } else {
          // 3 attempts exhausted
          await Future.delayed(const Duration(milliseconds: 600));
          if (mounted) {
            Navigator.of(context).pushReplacementNamed('/attendance_failed');
          }
        }
      }
    } catch (e) {
      _setError('Verification failed: ${e.toString()}');
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

  Face? _selectBiggestCenteredFace(List<Face> faces, CameraImage image) {
    if (faces.isEmpty) return null;

    final sorted = List<Face>.from(faces)
      ..sort((a, b) {
        final double areaA = a.boundingBox.width * a.boundingBox.height;
        final double areaB = b.boundingBox.width * b.boundingBox.height;
        return areaB.compareTo(areaA);
      });

    final Face biggest = sorted.first;

    final double centerX =
        biggest.boundingBox.left + biggest.boundingBox.width / 2;
    final double imageCenterX = image.width / 2.0;
    final double offsetX = (centerX - imageCenterX).abs() / image.width;

    if (offsetX > 0.30) return null;

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
        _updateInstruction('Processing…', subtitle: 'Comparing your face');
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
                lower.contains('move slightly backward')) {
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
              lower.contains('move slightly backward')) {
            _borderColor = Colors.orangeAccent;
          } else if (_phase != _Phase.error &&
              _borderColor != AppStyles.successGreen) {
            _borderColor = AppStyles.primaryBlue;
          }
        });
      }
    });
  }

  void _setError(String message) {
    if (!mounted) return;
    debugPrint('[FACE_VER] ERROR: $message');
    setState(() {
      _phase = _Phase.error;
      _errorMessage = message;
      _borderColor = AppStyles.errorRed;
      _instructionTitle = 'Something went wrong';
      _instructionSubtitle = 'Please try again';
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DISPOSE
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _pulseController.dispose();
    _textFadeController.dispose();
    _blinkCountdownController.dispose();
    _successBounceController.dispose();
    _particleController.dispose();
    _scanLineController.dispose();
    _locationCardController.dispose();
    _timerPulseController.dispose();
    _ringController.dispose();
    _countdownTimer?.cancel();
    _instructionDebounceTimer?.cancel();

    if (_cameraController != null && _cameraInitialized) {
      try {
        _cameraController!.stopImageStream();
      } catch (_) {}
      _cameraController!.dispose();
    }

    _mlService.faceDetector.close();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // Timer color: green → amber → red
    final Color timerColor = _secondsRemaining <= 15
        ? AppStyles.errorRed
        : _secondsRemaining <= 30
        ? AppStyles.amberWarning
        : AppStyles.successGreen;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppStyles.backgroundLight,
        body: SafeArea(
          child: Column(
            children: [
              // ── Top App Bar ──────────────────────────────────────────────
              Theme(
                data: Theme.of(context).copyWith(
                  textTheme: Theme.of(context).textTheme.apply(
                    bodyColor: const Color(0xFF1A202C),
                    displayColor: const Color(0xFF1A202C),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 16.0,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 48),
                      const Spacer(),
                      Column(
                        children: [
                          const Text(
                            'Face Verification',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1A202C),
                              letterSpacing: -0.3,
                              inherit: false,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
              ),

              // ── Location Card ──────────────────────────────────────────
              FadeTransition(
                opacity: _locationFade,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24.0),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 12.0,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _locationVerified
                            ? Icons.check_circle_rounded
                            : Icons.location_searching_rounded,
                        color: _locationVerified
                            ? AppStyles.successGreen
                            : AppStyles.primaryBlue,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _locationVerified
                              ? 'Location verified'
                              : 'Checking your location…',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppStyles.textDark,
                          ),
                        ),
                      ),
                      if (!_locationVerified)
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppStyles.primaryBlue.withValues(alpha: 0.5),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // ── Camera Preview — uses Expanded to fill available space ──
              Expanded(
                child: AnimatedOpacity(
                  opacity: _locationVerified ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeIn,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final double availW = constraints.maxWidth;
                      final double availH = constraints.maxHeight;
                      final double circleSize = availW * 0.80;
                      final double circleTop = availH * 0.40 - circleSize / 2;

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
                              circleTop - 100 + circleSize / 2;

                          offsetX = (faceUIX - circleUIX).clamp(-6.0, 6.0);
                          offsetY = (faceUIY - circleUIY).clamp(-6.0, 6.0);
                        }
                      }

                      return SizedBox(
                        width: availW,
                        height: availH,
                        child: Stack(
                          children: [
                            // Background
                            Positioned.fill(
                              child: Container(
                                color: AppStyles.backgroundLight,
                              ),
                            ),

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
                                    top: circleTop - 100,
                                    child: ClipOval(
                                      child: SizedBox(
                                        width: circleSize,
                                        height: circleSize,
                                        child: OverflowBox(
                                          maxWidth: availW,
                                          maxHeight: availH,
                                          child: Transform.translate(
                                            offset: Offset(0, -circleTop),
                                            child: Stack(
                                              children: [
                                                _buildCameraPreview(availW),
                                                // Scan line inside clip
                                                Positioned.fill(
                                                  child: AnimatedBuilder(
                                                    animation:
                                                        _scanLineController,
                                                    builder: (context, child) {
                                                      return CustomPaint(
                                                        size: Size(
                                                          circleSize,
                                                          circleSize,
                                                        ),
                                                        painter: _ScanLinePainter(
                                                          scanValue:
                                                              _scanLineController
                                                                  .value,
                                                          circleSize:
                                                              circleSize,
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                                Positioned.fill(
                                                  child: AnimatedOpacity(
                                                    duration: const Duration(
                                                      milliseconds: 200,
                                                    ),
                                                    curve: Curves.easeOut,
                                                    opacity:
                                                        (_phase ==
                                                                _Phase
                                                                    .processing ||
                                                            _phase ==
                                                                _Phase.done)
                                                        ? 0.12
                                                        : 0.0,
                                                    child: Container(
                                                      color: Colors.black,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                  // Pulsing circle border + progress
                                  Positioned(
                                    left: (availW - circleSize) / 2,
                                    top: circleTop - 100,
                                    child: ScaleTransition(
                                      scale:
                                          Tween<double>(
                                            begin: 1.0,
                                            end: 1.05,
                                          ).animate(
                                            CurvedAnimation(
                                              parent: _successBounceController,
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
                                            (context, animatedProgress, child) {
                                              double tilt = 0.0;
                                              if (animatedProgress > 0.4 &&
                                                  animatedProgress < 0.9) {
                                                tilt =
                                                    math.sin(
                                                      (animatedProgress - 0.4) *
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
                                                        baseColor: _borderColor,
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
                                opacity: _phase == _Phase.capturing ? 0.3 : 0.0,
                                child: CustomPaint(
                                  painter: _FillLightPainter(
                                    circleCenter: Offset(
                                      availW / 2,
                                      (circleTop - 100) + circleSize / 2,
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
                                        ((circleTop - 100) + circleSize / 2) /
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
                              top: circleTop - 100,
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
                              top: (circleTop - 100) + circleSize + 32,
                              left: 16,
                              right: 16,
                              child: AnimatedOpacity(
                                opacity: _cameraPreviewReady ? 1.0 : 0.0,
                                duration: const Duration(milliseconds: 500),
                                curve: Curves.easeIn,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Single timer slot — swaps between 60s ring and blink countdown
                                    SizedBox(
                                      height: 56,
                                      child: Center(
                                        child: AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 300,
                                          ),
                                          child:
                                              (_phase == _Phase.liveness &&
                                                  (_instructionTitle.contains(
                                                        'Blink',
                                                      ) ||
                                                      _instructionSubtitle
                                                          .contains('Blink')) &&
                                                  !_challengeVerified)
                                              ? SizedBox(
                                                  key: const ValueKey('blink'),
                                                  width: 50,
                                                  height: 50,
                                                  child: AnimatedBuilder(
                                                    animation:
                                                        _blinkCountdownController,
                                                    builder: (context, child) {
                                                      final double remaining =
                                                          3.0 *
                                                          (1.0 -
                                                              _blinkCountdownController
                                                                  .value);
                                                      return Stack(
                                                        alignment:
                                                            Alignment.center,
                                                        children: [
                                                          SizedBox(
                                                            width: 50,
                                                            height: 50,
                                                            child: CircularProgressIndicator(
                                                              value:
                                                                  1.0 -
                                                                  _blinkCountdownController
                                                                      .value,
                                                              strokeWidth: 4.0,
                                                              color: Colors
                                                                  .orangeAccent,
                                                              backgroundColor: Colors
                                                                  .orangeAccent
                                                                  .withValues(
                                                                    alpha: 0.15,
                                                                  ),
                                                            ),
                                                          ),
                                                          AnimatedSwitcher(
                                                            duration:
                                                                const Duration(
                                                                  milliseconds:
                                                                      300,
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
                                                                    scale:
                                                                        animation,
                                                                    child: FadeTransition(
                                                                      opacity:
                                                                          animation,
                                                                      child:
                                                                          child,
                                                                    ),
                                                                  );
                                                                },
                                                            child: Text(
                                                              '${remaining.ceil()}',
                                                              key:
                                                                  ValueKey<int>(
                                                                    remaining
                                                                        .ceil(),
                                                                  ),
                                                              style: const TextStyle(
                                                                fontSize: 18,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w800,
                                                                color: Colors
                                                                    .orangeAccent,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      );
                                                    },
                                                  ),
                                                )
                                              : ScaleTransition(
                                                  key: const ValueKey('ring'),
                                                  scale: _timerPulseAnim,
                                                  child: AnimatedBuilder(
                                                    animation: _ringController,
                                                    builder: (context, _) {
                                                      return SizedBox(
                                                        width: 44,
                                                        height: 44,
                                                        child: CustomPaint(
                                                          painter:
                                                              _MiniRingPainter(
                                                                progress:
                                                                    _ringProgress
                                                                        .value,
                                                                color:
                                                                    timerColor,
                                                              ),
                                                          child: Center(
                                                            child: Text(
                                                              '${_secondsRemaining}s',
                                                              style: TextStyle(
                                                                fontSize: 12,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w800,
                                                                color:
                                                                    timerColor,
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
                                    ),

                                    const SizedBox(height: 6),

                                    // Attempt counter
                                    AnimatedOpacity(
                                      duration: const Duration(
                                        milliseconds: 400,
                                      ),
                                      opacity: _cameraPreviewReady ? 1.0 : 0.0,
                                      child: Text(
                                        'Attempt $_attemptCount of 3',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.grey.shade500,
                                        ),
                                      ),
                                    ),

                                    const SizedBox(height: 10),

                                    // HUD strip (Liveness → Scanning → Done)
                                    if (_phase != _Phase.initializing &&
                                        _phase != _Phase.processing &&
                                        _phase != _Phase.done)
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(16),
                                        child: BackdropFilter(
                                          filter: ImageFilter.blur(
                                            sigmaX: 10,
                                            sigmaY: 10,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 12,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.black54,
                                              gradient: LinearGradient(
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                                colors: [
                                                  Colors.black.withValues(
                                                    alpha: 0.6,
                                                  ),
                                                  Colors.transparent,
                                                ],
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              border: Border.all(
                                                color: Colors.white.withValues(
                                                  alpha: 0.5,
                                                ),
                                                width: 0.5,
                                              ),
                                            ),
                                            child: AnimatedBuilder(
                                              animation: _pulseController,
                                              builder: (context, _) {
                                                return Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment
                                                          .spaceBetween,
                                                  children: [
                                                    _NeonChip(
                                                      label: 'Liveness',
                                                      isActive:
                                                          _phase ==
                                                              _Phase
                                                                  .positioning ||
                                                          _phase ==
                                                              _Phase.liveness,
                                                      isDone:
                                                          _challengeVerified,
                                                      pulseValue:
                                                          _pulseController
                                                              .value,
                                                    ),
                                                    _ShimmerLine(
                                                      isDone:
                                                          _challengeVerified,
                                                      pulseController:
                                                          _pulseController,
                                                    ),
                                                    _NeonChip(
                                                      label: 'Scanning',
                                                      isActive:
                                                          _phase ==
                                                          _Phase.capturing,
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
                                                      pulseController:
                                                          _pulseController,
                                                    ),
                                                    _NeonChip(
                                                      label: 'Done',
                                                      isActive:
                                                          _phase == _Phase.done,
                                                      isDone:
                                                          _phase == _Phase.done,
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

                                    const SizedBox(height: 18),

                                    // Instruction card
                                    SlideTransition(
                                      position:
                                          Tween<Offset>(
                                            begin: const Offset(0, 0.06),
                                            end: const Offset(0, 0),
                                          ).animate(
                                            CurvedAnimation(
                                              parent: _textFadeController,
                                              curve: Curves.easeOut,
                                            ),
                                          ),
                                      child: FadeTransition(
                                        opacity: _textFadeController,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                            border: Border.all(
                                              color: _phase == _Phase.error
                                                  ? AppStyles.errorRed
                                                        .withValues(alpha: 0.3)
                                                  : AppStyles.primaryBlue
                                                        .withValues(alpha: 0.1),
                                              width: 1.5,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: 0.05,
                                                ),
                                                blurRadius: 10,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical:
                                                _instructionTitle ==
                                                    'Move to the center of the circle'
                                                ? 6
                                                : 10,
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                _instructionTitle,
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.w700,
                                                  color: _phase == _Phase.error
                                                      ? AppStyles.errorRed
                                                      : AppStyles.primaryBlue,
                                                ),
                                              ),
                                              _instructionTitle ==
                                                      'Move to the center of the circle'
                                                  ? const SizedBox.shrink()
                                                  : const SizedBox(height: 2),
                                              Text(
                                                _instructionSubtitle,
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: Colors.grey.shade600,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              if (_phase == _Phase.error) ...[
                                                const SizedBox(height: 16),
                                                TextButton(
                                                  onPressed: _onRetry,
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
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Build camera preview
  Widget _buildCameraPreview(double containerWidth) {
    if (!_cameraInitialized || _cameraController == null) {
      return SizedBox(
        width: containerWidth,
        height: containerWidth,
        child: _PulsingCameraLoader(),
      );
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
          child: CameraPreview(_cameraController!),
        ),
      ),
    );
  }

  void _onRetry() {
    _livenessService.resetCalibration();
    _liveEmbeddings.clear();
    _captureProgress = 0;
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
    });

    // Restart camera stream if needed
    if (_cameraInitialized && _cameraController != null) {
      try {
        _cameraController!.startImageStream(_onCameraFrame);
      } catch (_) {}
    }

    _setPhase(_Phase.positioning);
  }
}

// ─── _NeonChip ────────────────────────────────────────────────────────────────
class _NeonChip extends StatefulWidget {
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
  State<_NeonChip> createState() => _NeonChipState();
}

class _NeonChipState extends State<_NeonChip> {
  double _scale = 1.0;

  @override
  void didUpdateWidget(_NeonChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isDone && widget.isDone) {
      _triggerBounce();
    }
  }

  void _triggerBounce() async {
    if (!mounted) return;
    setState(() => _scale = 1.15);
    await Future.delayed(const Duration(milliseconds: 140));
    if (!mounted) return;
    setState(() => _scale = 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final chip = _buildChipContent();
    return AnimatedScale(
      scale: widget.isDone ? _scale : 1.0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutBack,
      child: chip,
    );
  }

  Widget _buildChipContent() {
    if (widget.isDone) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF2ECC71),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2ECC71).withValues(alpha: 0.4),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check, color: Colors.white, size: 12),
            const SizedBox(width: 4),
            Text(
              widget.label,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    if (widget.isActive) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppStyles.primaryBlue.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppStyles.primaryBlue.withValues(
              alpha: 0.5 + (0.5 * widget.pulseValue),
            ),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: AppStyles.primaryBlue.withValues(
                alpha: 0.2 * widget.pulseValue,
              ),
              blurRadius: 8,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Text(
          widget.label,
          style: const TextStyle(
            fontSize: 12,
            color: AppStyles.primaryBlue,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFD1D5DB), width: 1.0),
      ),
      child: Text(
        widget.label,
        style: const TextStyle(
          fontSize: 12,
          color: Color(0xFF6B7280),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ─── _ShimmerLine ─────────────────────────────────────────────────────────────
class _ShimmerLine extends StatelessWidget {
  final bool isDone;
  final AnimationController pulseController;

  const _ShimmerLine({required this.isDone, required this.pulseController});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AnimatedBuilder(
        animation: pulseController,
        builder: (context, child) {
          return Container(
            height: 2,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: isDone ? null : Colors.grey.shade600,
              gradient: isDone
                  ? LinearGradient(
                      colors: const [
                        Color(0xFF2ECC71),
                        Colors.white,
                        Color(0xFF2ECC71),
                      ],
                      stops: [
                        math.max(0.0, pulseController.value - 0.3),
                        pulseController.value,
                        math.min(1.0, pulseController.value + 0.3),
                      ],
                    )
                  : null,
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
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _scale = Tween<double>(
      begin: 0.82,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
    _opacity = Tween<double>(
      begin: 0.4,
      end: 0.85,
    ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF0F4FF),
      child: Center(
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            return Opacity(
              opacity: _opacity.value,
              child: Transform.scale(
                scale: _scale.value,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF1A73E8).withValues(alpha: 0.12),
                  ),
                  child: Center(
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF1A73E8),
                      ),
                      child: const Icon(
                        Icons.camera_alt_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
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

    // 1. Base pulsing border
    final paint = Paint()
      ..color = baseColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    final shadowPaint = Paint()
      ..color = baseColor.withValues(alpha: pulseValue * 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 + (pulseValue * 12));

    canvas.drawCircle(center, radius, shadowPaint);
    canvas.drawCircle(center, radius, paint);

    // 2. Progress ring
    if (progress > 0) {
      const Color progressColor = Color(0xFF2ECC71);
      final progressPaint = Paint()
        ..color = progressColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8.0
        ..strokeCap = StrokeCap.butt;

      final progressGlow = Paint()
        ..color = progressColor.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12.0
        ..strokeCap = StrokeCap.butt
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);

      final sweepAngle = 2 * math.pi * progress;
      canvas.drawArc(rect, -math.pi / 2, sweepAngle, false, progressGlow);
      canvas.drawArc(rect, -math.pi / 2, sweepAngle, false, progressPaint);
    }

    if (phase != _Phase.processing && phase != _Phase.done) {
      // Breathing halo
      final double breathOffset = 4.0 + (10.0 * pulseValue);
      final double haloRadius = radius + breathOffset;

      final Paint haloPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            baseColor.withValues(alpha: 0.15 * (1.0 - pulseValue)),
            baseColor.withValues(alpha: 0.0),
          ],
          stops: const [0.8, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: haloRadius));

      canvas.drawCircle(center, haloRadius, haloPaint);

      final glowArcPaint = Paint()
        ..color = baseColor.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);

      final glowAngle = pulseValue * 2 * math.pi;
      canvas.drawArc(rect, glowAngle, 0.436, false, glowArcPaint);
    }

    // 3D circle illusion
    final Paint topHighlightPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    final Paint bottomShadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
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

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.0 || progress >= 1.0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 1.0 - progress);

    final random = math.Random(12345);
    for (int i = 0; i < 30; i++) {
      final angle = random.nextDouble() * 2 * math.pi;
      final speed = 50.0 + random.nextDouble() * 100.0;
      final distance = (size.width / 2) + speed * progress;

      final x = center.dx + math.cos(angle) * distance;
      final y = center.dy + math.sin(angle) * distance;

      final rectSize = 3.0 + random.nextDouble() * 5.0;
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(x, y),
          width: rectSize,
          height: rectSize,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ParticleBurstPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

// ─── _ScanLinePainter ─────────────────────────────────────────────────────────
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
  bool shouldRepaint(covariant _ScanLinePainter oldDelegate) {
    return true;
  }
}

// ─── _MiniRingPainter ─────────────────────────────────────────────────────────
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
