// lib/screens/face/face_registration_screen.dart
//
// Phase 1 — Real face registration implementation.
//
// What this file does:
//   1. Opens live camera (front-facing)
//   2. Runs ML Kit face detection every frame (rate-limited to 10fps)
//   3. Shows real-time pose instructions based on actual face position
//   4. Runs EAR blink detection with personalized calibration
//   5. Auto-captures frames across 3 phases: FRONT, LEFT, RIGHT
//   6. Generates MobileFaceNet embeddings for each frame
//   7. Builds embedding_a (front+left average) and embedding_b (front+right average)
//   8. Uploads registration photo to Supabase Storage
//   9. Saves both embeddings + photo URL to students table
//  10. Navigates to registration_success screen
//
// What this file does NOT touch:
//   - QR scanner flow
//   - Dashboard
//   - supabase_service.dart
//   - Any attendance screens
//
// UI is preserved exactly from the original screen.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:image/image.dart' as img;

import 'package:camera/camera.dart';
import 'package:facial_liveness_verification/facial_liveness_verification.dart'
    show ChallengeType;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/face_ml_service.dart';
import '../../services/face_landmark_service.dart';
import '../../utils/app_styles.dart';
import '../../utils/auth_flow_state.dart';
import '../../utils/camera_stabilizer.dart';

// FIXED: Removed _computeEmbedding isolate function — ML Kit plugins cannot
// run in background isolates (BackgroundIsolateBinaryMessenger error).
// Embedding generation now runs on main thread during capture phase.
// SKILL.md compliant for registration: only 9 frames, each ~15-25ms inference.

// ─── Registration phases ──────────────────────────────────────────────────────
enum _Phase {
  initializing, // Camera starting up
  liveness, // Blink verification (looking straight) — first gate
  left, // Pose Capture Stage 1: Left
  front, // Pose Capture Stage 2: Front
  right, // Pose Capture Stage 3: Right
  up, // Pose Capture Stage 4: Up
  down, // Pose Capture Stage 5: Down
  processing, // Running embeddings + uploading to Supabase
  done, // Complete — navigating away
  error, // Something went wrong
}

class FaceRegistrationScreen extends StatefulWidget {
  const FaceRegistrationScreen({super.key});

  @override
  State<FaceRegistrationScreen> createState() => _FaceRegistrationScreenState();
}

class _FaceRegistrationScreenState extends State<FaceRegistrationScreen>
    with TickerProviderStateMixin {
  // ─── Session ID & Timings ────────────────────────────────────────────────
  late final String _sessionId;
  final Stopwatch _captureStopwatch = Stopwatch();
  final Stopwatch _apiStopwatch = Stopwatch();
  final Stopwatch _templateStopwatch = Stopwatch();
  final Stopwatch _uploadStopwatch = Stopwatch();
  final Stopwatch _totalStopwatch = Stopwatch();
  int _totalFramesCaptured = 0;
  int _totalFramesLogged = 0;

  // ─── Animation controllers (kept from original UI) ──────────────────────
  late AnimationController _pulseController;
  late AnimationController _textFadeController;
  late AnimationController _blinkCountdownController;

  // ─── Camera ──────────────────────────────────────────────────────────────
  CameraController? _cameraController;
  bool _cameraInitialized = false;
  late CameraStabilizer _cameraStabilizer;
  Face? _lastProcessedFace;
  int _nextCaptureInterval = 280;

  // ─── ML ──────────────────────────────────────────────────────────────────
  final FaceMlService _mlService = FaceMlService();
  final FaceLandmarkService _landmarkService = FaceLandmarkService();
  final LivenessChallengeService _livenessService = LivenessChallengeService();
  bool _isProcessingFrame = false;
  DateTime _lastFrameTime = DateTime.now();
  CameraImage? _lastCameraImage;
  DateTime _lastCaptureTime = DateTime.fromMillisecondsSinceEpoch(0);

  // ─── Registration state ───────────────────────────────────────────────────
  _Phase _phase = _Phase.initializing;

  // Captured frame bytes (JPEG) per pose
  final List<Uint8List> _leftFrames = [];
  final List<Map<String, double>> _leftFramesStats = [];

  final List<Uint8List> _frontFrames = [];
  final List<Map<String, double>> _frontFramesStats = [];

  final List<Uint8List> _rightFrames = [];
  final List<Map<String, double>> _rightFramesStats = [];

  final List<Uint8List> _upFrames = [];
  final List<Map<String, double>> _upFramesStats = [];

  final List<Uint8List> _downFrames = [];
  final List<Map<String, double>> _downFramesStats = [];

  // Selected best frames per pose
  final Map<_Phase, Uint8List> _bestFrames = {};
  final Map<_Phase, Map<String, double>> _bestFramesStats = {};

  // Adaptive quality gate and pending poses state
  final Map<_Phase, int> _consecutiveRejections = {};
  final Map<_Phase, bool> _hintShown = {};
  final Map<_Phase, int> _lastRelaxationLevel = {};
  List<_Phase> _pendingPoses = [
    _Phase.left,
    _Phase.front,
    _Phase.right,
    _Phase.up,
    _Phase.down,
  ];

  void _showHintOnce(_Phase phase, String hint) {
    if (_hintShown[phase] == true) return;
    _hintShown[phase] = true;
    if (!mounted) return;
    setState(() {
      _instructionSubtitle = hint;
    });
  }

  // Client-rejected frames list (reasons + stats)
  final List<Map<String, dynamic>> _clientRejectedLogs = [];

  // Attempts tracking (each captured/evaluated frame is an attempt)
  int _leftAttempts = 0;
  int _frontAttempts = 0;
  int _rightAttempts = 0;
  int _upAttempts = 0;
  int _downAttempts = 0;

  // First front frame saved as registration photo
  Uint8List? _registrationPhotoBytes;
  Rect? _registrationPhotoBbox;

  // Target accepted frames per pose
  int targetFramesForPose(_Phase phase) {
    switch (phase) {
      case _Phase.up:
      case _Phase.down:
        return 3;
      case _Phase.left:
      case _Phase.front:
      case _Phase.right:
      default:
        return 3;
    }
  }

  static const int _totalTargetFrames = 15;
  // ignore: unused_field
  static const int _maxAttemptsPerPose = 5;

  // New state variables for valid frame counting, camera freeze, and processing overlays
  final List<BatchEmbeddingResult> _validResults = [];
  int _validFrameCount = 0;
  bool _cameraFrozen = false;
  Uint8List? _lastCapturedFrameBytes;
  bool _isSubmitting = false;

  // Exposure adjustment throttle timestamp
  DateTime _lastExposureAdjustTime = DateTime.fromMillisecondsSinceEpoch(0);

  // Problem 2: one-shot capture completion lock — prevents duplicate _processAndUpload calls.
  // Set to true the moment we decide to stop capturing; reset only in _onRetry.
  bool _captureCompleted = false;

  // Problem 3: tracks whether the image stream is currently running so we
  // never call startImageStream() twice.
  bool _imageStreamRunning = false;

  // Instruction / UI state
  String _instructionTitle = 'Setting up camera…';
  String _instructionSubtitle = 'Please wait';
  Color _borderColor = AppStyles.primaryBlue;
  bool _challengeVerified = false;

  // ─── Challenge verification timeout ──────────────────────────────────────
  DateTime? _challengeStartTime;

  // Tracks intermediate blinks to trigger green flash per blink registered
  int _lastKnownBlinkCount = 0;

  // Progress: which step out of total (for display)
  int _captureProgress = 0; // 0-15 total frames
  String _progressLabel = '';

  // ignore: unused_field
  String? _errorMessage;

  // ─── Face positioning state ────────────────────────────────────────────
  DateTime? _steadyStartTime;
  bool _isFaceReady = false;
  DateTime? _poseSteadyStartTime;
  _Phase? _poseSteadyPhase; // tracks which phase the steady timer belongs to
  static const int _poseSteadyDurationMs = 550;
  Timer? _instructionDebounceTimer;

  // ── Flash effect ──
  bool _showFlash = false;

  // ── Micro-Interactions ──
  late AnimationController _successBounceController;
  late AnimationController _particleController;

  // Layout info captured from LayoutBuilder for coordinate mapping
  double _uiCircleSize = 0;
  double _uiAvailW = 0;
  double _uiAvailH = 0;

  // ─── Smoothing buffer (weighted moving average, last 5 frames) ────────
  static const int _smoothingBufferSize = 5;
  final List<double> _bufFaceWidth = [];
  final List<double> _bufFaceHeight = [];
  final List<double> _bufFaceCX = [];
  final List<double> _bufFaceCY = [];
  final List<double> _bufYaw = [];
  final List<double> _bufPitch = [];

  // ─── Hysteresis state ─────────────────────────────────────────────────
  // Tracks the last accepted positioning instruction to apply safety gaps.
  // null = face was accepted (in good position).
  String? _lastPosInstruction;

  // ─── Instruction strings ─────────────────────────────────────────────────
  // These match the original screen's instruction map exactly
  final Map<String, String> _subtitles = {
    "Fit your face in the circle": "Make sure your full face is visible",
    "Move closer": "Step a little closer to the camera",
    "Move closer to the camera":
        "Step a little closer so your face fills the circle",
    "Move back": "You are too close, step back slightly",
    "Move slightly backward": "You are too close, step back a little",
    "Move left": "Shift your position slightly to the left",
    "Move slightly Left": "Shift yourself slightly to the left",
    "Move right": "Shift your position slightly to the right",
    "Move slightly Right": "Shift yourself slightly to the right",
    "Move slightly Down": "Lower your face a bit",
    "Move slightly Up": "Raise your face a bit",
    "Look slightly up": "Look slightly up and hold still",
    "Look slightly down": "Look slightly down and hold still",
    "Reduce head movement slightly": "Keep pose within normal tilt",
    "Hold still…": "Almost ready, stay steady",
    "Blink to verify": "Blink naturally to confirm you are present",
    "Blink your eyes 2-3 times":
        "Blink naturally 2 to 3 times to confirm you are present",
    "Setting up camera…": "Please wait",
    "Calibrating…": "Look straight at the camera and hold still",
    "Look straight ahead": "Getting your front profile",
    "Turn slightly left": "Shift your position slightly to the left",
    "Turn slightly right": "Shift your position slightly to the right",
    "Too bright — move out of direct sunlight": "Reduce direct lighting on your face",
    "Too dark — improve the lighting on your face": "Face a light source or move to a brighter spot",
    "All poses captured": "Great! Processing your face profile…",
    "Processing…": "Generating your face profile",
    "Almost done!": "Saving your registration",
    "Registration complete!": "Your face has been registered",
    "Something went wrong": "Please try again",
  };

  @override
  void initState() {
    super.initState();
    debugPrint('[FACE_REG] Screen initialized');

    // Security guard from original screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!AuthFlowState.instance.passwordSet) {
        Navigator.of(context).pushReplacementNamed('/sign_in');
        return;
      }
    });

    // ── Animation setup (identical to original) ────────────────────────────
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

    // Start real registration flow
    _initializeCamera();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CAMERA INITIALIZATION
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _initializeCamera() async {
    try {
      _sessionId = FaceLandmarkService.newRegSessionId();

      // Get available cameras
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
        logPrefix: 'FACE_REG',
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

      // Warm up backend — prevents Hugging Face cold start during registration.
      // Fire-and-forget: ignore failures, backend may still respond.
      _landmarkService.pingBackend().catchError((_) {});

      // Start camera stream for face detection
      await _cameraController!.startImageStream(_onCameraFrame);
      _imageStreamRunning = true;

      _livenessService.logPrefix = 'FACE_REG';
      _livenessService.sessionId = _sessionId;

      debugPrint('[FACE_REG][$_sessionId]');
      debugPrint('Registration Started');

      _setPhase(_Phase.liveness);
    } catch (e) {
      _setError('Camera failed to start: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CAMERA FRAME PROCESSING — rate-limited to 10fps
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _onCameraFrame(CameraImage cameraImage) async {
    if (!_cameraStabilizer.isStable) return;
    // Problem 4: Immediately drop frames once capture is complete or processing
    // has started. These checks must come BEFORE storing _lastCameraImage so
    // that no late-arriving frame can slip through after the camera is frozen.
    if (_captureCompleted) return;
    if (_isSubmitting) return;
    if (_cameraFrozen) return;

    // Always store latest frame for capture use
    _lastCameraImage = cameraImage;

    // Rate limit: process max 10 frames per second (except during active blink)
    final now = DateTime.now();
    // Bypass rate limit entirely during active blink detection for lag-free ~30 FPS.
    // After blink verified or during capture phases, use standard 10fps.
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

    // Skip processing during these phases
    if (_phase == _Phase.initializing ||
        _phase == _Phase.processing ||
        _phase == _Phase.done ||
        _phase == _Phase.error) {
      return;
    }

    _lastFrameTime = now;
    _isProcessingFrame = true;

    try {
      // Convert CameraImage to InputImage for ML Kit
      final InputImage? inputImage = _convertToInputImage(cameraImage);
      if (inputImage == null) {
        debugPrint(
          'Face: inputImage conversion FAILED, format.raw=${cameraImage.format.raw}, planes=${cameraImage.planes.length}',
        );
        _isProcessingFrame = false;
        return;
      }

      // Detect faces
      final List<Face> faces = await _mlService.faceDetector.processImage(
        inputImage,
      );

      if (!mounted) {
        _isProcessingFrame = false;
        return;
      }

      debugPrint(
        'Face: detected ${faces.length} face(s), camSize=${cameraImage.width}x${cameraImage.height}, sensorOrient=${_cameraController!.description.sensorOrientation}',
      );

      if (faces.isEmpty) {
        // During capture sub-phases, don't reset instruction on momentary
        // face loss — blinks/turns can cause ML Kit to lose the face briefly.
        // Only show "Fit your face" during liveness phase (before blink verified).
        if (_phase == _Phase.liveness && !_challengeVerified) {
          // Reset positioning steady state and smoothing buffer on face loss
          _clearSmoothing();
          _steadyStartTime = null;
          if (_isFaceReady) {
            _isFaceReady = false;
            _livenessService.resetCalibration();
            _challengeStartTime = null;
            _blinkCountdownController.stop();
            _blinkCountdownController.reset();
            debugPrint(
              '[FACE_REG] Face lost — resetting calibration & challenge',
            );
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
              '[FACE_CAMERA] [FACE_REG][$_sessionId] Face tracking ID changed: ${_lastProcessedFace!.trackingId} -> ${face.trackingId}',
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
              '[FACE_CAMERA] [FACE_REG][$_sessionId] Face tracking lost via IoU (IoU: ${iou.toStringAsFixed(2)})',
            );
          }
        }
        if (!isSame) {
          debugPrint(
            '[FACE_CAMERA] [FACE_REG][$_sessionId] Face tracking lost — resetting captured frames and buffer',
          );
          _clearSmoothing();
          _frontFrames.clear();
          _frontFramesStats.clear();
          _validResults.clear();
          _validFrameCount = 0;
          _captureProgress = 0;
          _progressLabel = '';
          _steadyStartTime = null;
          _isFaceReady = false;
          _livenessService.resetCalibration();
          _challengeStartTime = null;
          _blinkCountdownController.stop();
          _blinkCountdownController.reset();
        }
      }
      _lastProcessedFace = face;

      // Push raw face metrics into smoothing buffer for moving average
      _pushSmoothing(face);

      // Adapt camera exposure to face region (throttled to 600ms)
      final frameStats = _cameraStabilizer.computeFrameStats(
        cameraImage,
        faceBoundingBox: face.boundingBox,
        sensorOrientation: _cameraController!.description.sensorOrientation,
      );
      final double faceBrightness = frameStats['brightness'] ?? 0.0;
      final nowAdjust = DateTime.now();
      if (nowAdjust.difference(_lastExposureAdjustTime).inMilliseconds >= 600) {
        _lastExposureAdjustTime = nowAdjust;
        _cameraStabilizer.adjustFaceExposure(faceBrightness);
      }

      // ── Pre-liveness positioning gate ──────────────────────────────────
      // Only applies during liveness phase (before initial blink).
      // Once _challengeVerified is true, capture phases skip this entirely.
      if (_phase == _Phase.liveness && !_challengeVerified) {
        // Choose strictness: strict before liveness starts, relaxed during
        final bool strict = !_isFaceReady;
        final String? posInstruction = _getPositioningInstruction(
          face,
          cameraImage,
          strict: strict,
        );

        if (posInstruction != null) {
          // Not positioned — reset steady timer and ready state
          if (_isFaceReady) {
            // Was in liveness challenge, now lost position — reset
            _isFaceReady = false;
            _livenessService.resetCalibration();
            _challengeStartTime = null;
            _blinkCountdownController.stop();
            _blinkCountdownController.reset();
            debugPrint(
              '[FACE_REG] Face lost position — resetting calibration & challenge',
            );
          }
          _steadyStartTime = null;
          _updateInstruction(posInstruction, animate: false);
          _isProcessingFrame = false;
          return;
        }

        // Face is centered and at correct distance — track steadiness
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
          // Steady for 800ms — mark ready
          _isFaceReady = true;
          _livenessService.reset();
          debugPrint(
            '[FACE_REG] Face positioned & steady 800ms — starting blink calibration',
          );

          // Show calibrating instruction while we collect baseline
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
            // Blink verified — transition to left capture phase
            debugPrint(
              '[FACE_REG] Liveness verified — moving directly to left capture phase',
            );
            await Future.delayed(const Duration(milliseconds: 500));
            if (mounted) _setPhase(_Phase.left);
          }
          break;
        case _Phase.left:
          await _handleCapture(face, cameraImage, _Phase.left);
          break;
        case _Phase.front:
          await _handleCapture(face, cameraImage, _Phase.front);
          break;
        case _Phase.right:
          await _handleCapture(face, cameraImage, _Phase.right);
          break;
        case _Phase.up:
          await _handleCapture(face, cameraImage, _Phase.up);
          break;
        case _Phase.down:
          await _handleCapture(face, cameraImage, _Phase.down);
          break;
        default:
          break;
      }
    } catch (e) {
      // Swallow frame errors silently — bad frames are common
    } finally {
      _isProcessingFrame = false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LIVENESS CHALLENGE HANDLER
  // Uses ChallengeValidator from facial_liveness_verification package.
  // Handles blink (front), turnLeft (left), turnRight (right).
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _handleLivenessChallenge(
    Face face,
    ChallengeType challenge,
  ) async {
    _challengeStartTime ??= DateTime.now();

    final int elapsed = DateTime.now()
        .difference(_challengeStartTime!)
        .inMilliseconds;

    // Timeout: 3s for initial blink liveness check
    final int timeout = 3000;

    if (elapsed > timeout) {
      debugPrint(
        '[FACE_REG] Challenge ${challenge.name} timed out (${elapsed}ms)',
      );
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

      // Brief pause so user sees the retry message
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      // Restart challenge countdown
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

    // ── Blink phase: run inline calibration before detecting ───────────────
    // Collects 10 baseline eye-probability samples after face is steady.
    // Only then shows the blink prompt and starts countdown.
    if (challenge == ChallengeType.blink &&
        !_livenessService.isBlinkCalibrated) {
      final bool calibDone = _livenessService.calibrateBlink(face);
      if (!calibDone) {
        return; // Still collecting — keep showing "Calibrating…"
      }
      // Calibration just finished — start countdown and show prompt
      _challengeStartTime = DateTime.now();
      _lastKnownBlinkCount = 0;
      _blinkCountdownController.reset();
      _blinkCountdownController.forward();
      _updateInstruction(
        'Blink to Start',
        subtitle: 'Blink naturally 2 to 3 times to confirm you are present',
        animate: false,
      );
      return; // Start detecting on the very next frame
    }

    // ── Try to detect the challenge ──────────────────────────────────────
    bool detected = false;
    switch (challenge) {
      case ChallengeType.blink:
        detected = _livenessService.detectBlink(face);
        // ─ Per-blink green flash (intermediate progress feedback) ──────────
        // Flash green every time a new blink is registered but not yet done.
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
      case ChallengeType.turnLeft:
        detected = _livenessService.detectTurnLeft(face);
        break;
      case ChallengeType.turnRight:
        detected = _livenessService.detectTurnRight(face);
        break;
      default:
        break;
    }

    if (detected) {
      FaceLogger.reg(_sessionId, 'Blink challenge VERIFIED ✓');
      _challengeVerified = true;
      _livenessService.reset();
      _challengeStartTime = null;
      _blinkCountdownController.stop();

      // Start the capture timer
      _captureStopwatch.start();

      if (mounted) {
        setState(() {
          _borderColor = AppStyles.successGreen;
        });
        HapticFeedback.lightImpact();
      }
      _updateInstruction(
        'Blink verified!',
        subtitle: 'Preparing next step…',
        animate: false,
      );
      // Transition happens in the phase switch (liveness → left)
    }
  }

  String _getChallengeInstruction(ChallengeType challenge) {
    switch (challenge) {
      case ChallengeType.blink:
        return 'Blink to verify';
      case ChallengeType.turnLeft:
        return 'Turn slightly left';
      case ChallengeType.turnRight:
        return 'Turn slightly right';
      default:
        return 'Hold still…';
    }
  }

  Future<void> _handleCapture(
    Face face,
    CameraImage cameraImage,
    _Phase currentPhase,
  ) async {
    // Problem 2 & 4: drop immediately if frozen or already completed
    if (_cameraFrozen) return;
    if (_captureCompleted) return;
    if (_isSubmitting) return;

    final now = DateTime.now();
    if (now.difference(_lastCaptureTime).inMilliseconds <
        _nextCaptureInterval) {
      return;
    }

    // Centering + size + boundary check
    if (!_isFaceAcceptable(face, cameraImage, currentPhase)) {
      _updateInstruction(
        _getFacingInstruction(face, cameraImage),
        animate: false,
      );
      return;
    }

    final double? yawRaw = face.headEulerAngleY;
    final double? pitch = face.headEulerAngleX;
    final double yaw = yawRaw != null ? -yawRaw : 0.0;

    if (currentPhase == _Phase.up || currentPhase == _Phase.down) {
      debugPrint('[POSE_DEBUG] Phase: ${currentPhase.name} | Yaw: ${yaw.toStringAsFixed(1)} | Pitch: ${pitch?.toStringAsFixed(1)}');
    }

    // Validate pose for current phase
    if (!_isPoseCorrect(face, currentPhase)) {
      _poseSteadyStartTime = null;
      final feedback =
          _getGentlePoseFeedback(face, currentPhase) ??
          _getPoseInstruction(currentPhase);
      _updateInstruction(feedback, animate: false);
      return;
    }

    if (_poseSteadyStartTime == null || _poseSteadyPhase != currentPhase) {
      _poseSteadyStartTime = DateTime.now();
      _poseSteadyPhase = currentPhase;
      _updateInstruction(
        'Hold still…',
        subtitle: 'Almost there, stay steady',
        animate: false,
      );
      return;
    }

    final int steadyMs = DateTime.now()
        .difference(_poseSteadyStartTime!)
        .inMilliseconds;
    final int requiredSteadyMs = (currentPhase == _Phase.up || currentPhase == _Phase.down) ? 800 : _poseSteadyDurationMs;
    if (steadyMs < requiredSteadyMs) {
      _updateInstruction(
        'Hold still…',
        subtitle: 'Almost there, stay steady',
        animate: false,
      );
      return;
    }

    // Increment attempts for this phase
    int currentAttempts = 0;
    int currentAccepted = 0;
    List<Uint8List> phaseFrames;
    List<Map<String, double>> phaseStats;

    if (currentPhase == _Phase.left) {
      _leftAttempts++;
      currentAttempts = _leftAttempts;
      phaseFrames = _leftFrames;
      phaseStats = _leftFramesStats;
    } else if (currentPhase == _Phase.front) {
      _frontAttempts++;
      currentAttempts = _frontAttempts;
      phaseFrames = _frontFrames;
      phaseStats = _frontFramesStats;
    } else if (currentPhase == _Phase.right) {
      _rightAttempts++;
      currentAttempts = _rightAttempts;
      phaseFrames = _rightFrames;
      phaseStats = _rightFramesStats;
    } else if (currentPhase == _Phase.up) {
      _upAttempts++;
      currentAttempts = _upAttempts;
      phaseFrames = _upFrames;
      phaseStats = _upFramesStats;
    } else {
      _downAttempts++;
      currentAttempts = _downAttempts;
      phaseFrames = _downFrames;
      phaseStats = _downFramesStats;
    }

    // Compute relaxation level based on consecutive rejections
    final int rejections = _consecutiveRejections[currentPhase] ?? 0;
    int level = 0;
    double sharpnessMin = 2.0;
    double brightMin = 45.0;
    double brightMax = 230.0;

    if (rejections >= 6) {
      level = 2;
      sharpnessMin = 1.0;
      brightMin = 30.0;
      brightMax = 245.0;
    } else if (rejections >= 3) {
      level = 1;
      sharpnessMin = 1.4;
      brightMin = 35.0;
      brightMax = 240.0;
    }

    if (_lastRelaxationLevel[currentPhase] != level) {
      _lastRelaxationLevel[currentPhase] = level;
      debugPrint(
        '[FACE_REG] Quality gate relaxed to level $level for ${currentPhase.name} (rejections: $rejections)',
      );
    }

    // Now validate quality (sharpness, brightness, size, centering)
    final List<String> rejectionReasons = [];
    final Map<String, double> stats = {};
    final bool isQualityPassed = _validateFrameQuality(
      face,
      cameraImage,
      currentPhase,
      rejectionReasons,
      stats,
      sharpnessMin: sharpnessMin,
      brightMin: brightMin,
      brightMax: brightMax,
    );

    if (!isQualityPassed) {
      _consecutiveRejections[currentPhase] = rejections + 1;
      if (rejections + 1 >= 3) {
        _showHintOnce(
          currentPhase,
          'Tip: face a light source if possible — capture continues…',
        );
      }

      // Discard immediately - log the rejection locally
      _clientRejectedLogs.add({
        'phase': currentPhase.name,
        'attempt': currentAttempts,
        'reasons': rejectionReasons,
        'stats': stats,
        'timestamp': DateTime.now().toIso8601String(),
      });
      debugPrint(
        '[FACE_REG] Frame rejected. Attempt $currentAttempts. Reasons: $rejectionReasons',
      );
      return;
    }

    // Reset consecutive rejections on quality pass
    _consecutiveRejections[currentPhase] = 0;

    // Stable frame selection check with relaxed threshold
    if (!_cameraStabilizer.checkFrameStability(cameraImage, threshold: 35.0)) {
      _isProcessingFrame = false;
      return;
    }

    _updateInstruction('Hold still…', subtitle: 'Almost done, stay steady');

    // Grab the current frame as JPEG
    final Uint8List? jpegBytes = await _captureCurrentFrame();
    if (jpegBytes == null) return;

    // Re-check locks after the async captureCurrentFrame
    if (_captureCompleted) return;
    if (_cameraFrozen) return;

    _lastCapturedFrameBytes = jpegBytes; // Store for freeze preview

    // Save first front frame as registration photo
    if (currentPhase == _Phase.front && _registrationPhotoBytes == null) {
      _registrationPhotoBytes = jpegBytes;
      _registrationPhotoBbox = face.boundingBox;
      debugPrint(
        '[FACE_REG] ✓ FRONT photo saved — yaw=${face.headEulerAngleY?.toStringAsFixed(1)}',
      );
    }

    // Allow UI to render the green flash smoothly
    await Future.delayed(const Duration(milliseconds: 40));

    // Briefly trigger the flash effect
    setState(() {
      _showFlash = true;
    });
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          _showFlash = false;
        });
      }
    });

    // Restore border color slightly after
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted && _phase == currentPhase) {
        setState(() {
          _borderColor = AppStyles.primaryBlue;
        });
      }
    });

    // Store JPEG bytes
    phaseFrames.add(jpegBytes);
    phaseStats.add(stats);
    currentAccepted = phaseFrames.length;

    _captureProgress = (_leftFrames.length +
        _frontFrames.length +
        _rightFrames.length +
        _upFrames.length +
        _downFrames.length);
    _progressLabel =
        'Accepted: $currentAccepted / ${targetFramesForPose(currentPhase)}';

    setState(() {
      _borderColor = AppStyles.successGreen;
    });
    HapticFeedback.lightImpact();
    debugPrint('[FACE_REG] Frame Captured for ${currentPhase.name}');
    debugPrint('[FACE_REG]   Current Batch = ${phaseFrames.length}');
    debugPrint('[FACE_REG]   Attempts = $currentAttempts');

    _lastCaptureTime = DateTime.now();
    _nextCaptureInterval = 400 + math.Random().nextInt(100);

    // If we reached the target accepted frames for this pose
    if (currentAccepted >= targetFramesForPose(currentPhase)) {
      // Pick the best frame out of the accepted ones
      final List<int> indices = List.generate(phaseFrames.length, (i) => i);
      indices.sort((a, b) {
        final double scoreA =
            (phaseStats[a]['sharpness'] ?? 0.0) *
            (phaseStats[a]['contrast'] ?? 0.0);
        final double scoreB =
            (phaseStats[b]['sharpness'] ?? 0.0) *
            (phaseStats[b]['contrast'] ?? 0.0);
        return scoreB.compareTo(scoreA); // descending order
      });
      final int bestIndex = indices.first;
      _bestFrames[currentPhase] = phaseFrames[bestIndex];
      _bestFramesStats[currentPhase] = phaseStats[bestIndex];

      debugPrint(
        '[FACE_REG] Completed pose ${currentPhase.name}. Best frame selected (index $bestIndex).',
      );

      _pendingPoses.remove(currentPhase);
      if (_pendingPoses.isEmpty) {
        if (_captureCompleted) return;
        _captureCompleted = true;

        _captureStopwatch.stop();

        FaceLogger.reg(_sessionId, 'Target Reached for all poses');
        FaceLogger.reg(_sessionId, '  Stopping Camera');
        FaceLogger.reg(_sessionId, '  Starting Processing');

        try {
          await _cameraController?.stopImageStream();
        } catch (_) {}
        _imageStreamRunning = false;

        setState(() {
          _cameraFrozen = true;
          _borderColor = AppStyles.successGreen;
        });

        _updateInstruction(
          'All poses captured',
          subtitle: 'Great! Processing your face profile…',
          animate: true,
        );

        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            _setPhase(_Phase.processing);
            _processAndUpload();
          }
        });
      } else {
        _setPhase(_pendingPoses.first);
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PROCESS + UPLOAD
  // Build both embeddings from captured frames and save to Supabase
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _processAndUpload() async {
    if (!mounted) return;
    if (_isSubmitting) return;

    _totalStopwatch.start();

    setState(() {
      _isSubmitting = true;
    });

    _updateInstruction('Processing…', subtitle: 'Generating your face profile');

    try {
      final List<Uint8List> bestFramesList = [
        _bestFrames[_Phase.left]!,
        _bestFrames[_Phase.front]!,
        _bestFrames[_Phase.right]!,
        _bestFrames[_Phase.up]!,
        _bestFrames[_Phase.down]!,
      ];
      final List<Map<String, double>> bestStatsList = [
        _bestFramesStats[_Phase.left]!,
        _bestFramesStats[_Phase.front]!,
        _bestFramesStats[_Phase.right]!,
        _bestFramesStats[_Phase.up]!,
        _bestFramesStats[_Phase.down]!,
      ];

      _totalFramesCaptured += bestFramesList.length;
      FaceLogger.reg(_sessionId, 'Embedding Generation Started');
      FaceLogger.reg(_sessionId, '  Batch size = ${bestFramesList.length}');

      _apiStopwatch.start();
      final List<BatchEmbeddingResult> batchResults = await _landmarkService
          .generateEmbeddingBatch(
            jpegBytesList: bestFramesList,
            localStatsList: bestStatsList,
            sessionId: _sessionId,
            prefix: 'FACE_REG',
            clientRejectedLogs: _clientRejectedLogs,
          );
      _apiStopwatch.stop();

      FaceLogger.reg(_sessionId, 'Batch Finished');
      FaceLogger.reg(_sessionId, '  Captured = ${bestFramesList.length}');

      // ── CASE 2: API / network failure ─────────────────────────────────────
      final bool apiFailed =
          batchResults.isNotEmpty && batchResults.first.apiFailed;

      if (apiFailed) {
        FaceLogger.reg(_sessionId, 'API FAILED');
        FaceLogger.reg(
          _sessionId,
          '  Reason           = ${batchResults.first.rejectionReason ?? "unknown"}',
        );
        FaceLogger.reg(_sessionId, '  Camera Restart   = NO');
        FaceLogger.reg(_sessionId, '  Waiting For User Retry');

        // Keep _captureCompleted = true and _cameraFrozen = true so no new
        // capture starts. Only release _isSubmitting so the retry button works.
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

      // ── CASE 1: API succeeded — evaluate quality ───────────────────────────
      int batchAccepted = 0;
      for (int i = 0; i < batchResults.length; i++) {
        final res = batchResults[i];
        final stats = bestStatsList[i];
        _totalFramesLogged++;

        final double brightness = stats['brightness'] ?? 0.0;
        final double contrast = stats['contrast'] ?? 0.0;
        final double sharpness = stats['sharpness'] ?? 0.0;
        final double yaw = stats['yaw'] ?? 0.0;
        final double pitch = stats['pitch'] ?? 0.0;
        final double roll = stats['roll'] ?? 0.0;

        final bool accepted = res.embedding != null && res.qualityPassed;

        debugPrint('[FACE_REG][$_sessionId]');
        debugPrint('Frame #$_totalFramesLogged');
        if (accepted) {
          debugPrint('Brightness=${brightness.round()}');
          debugPrint('Contrast=${contrast.round()}');
          debugPrint('Sharpness=${sharpness.round()}');
          debugPrint('FaceDetected=true');
          debugPrint('FaceInsideCircle=true');
          debugPrint('Yaw=${yaw.toStringAsFixed(1)}');
          debugPrint('Pitch=${pitch.toStringAsFixed(1)}');
          debugPrint('Roll=${roll.toStringAsFixed(1)}');
          debugPrint('Accepted=true');

          _validResults.add(res);
          batchAccepted++;
        } else {
          debugPrint('Accepted=false');
          debugPrint('Reason=${res.rejectionReason ?? "no_face_detected"}');
          debugPrint('Brightness=${brightness.round()}');
          debugPrint('Sharpness=${sharpness.round()}');
          debugPrint('Yaw=${yaw.toStringAsFixed(1)}');
          debugPrint('Pitch=${pitch.toStringAsFixed(1)}');
        }
      }

      // _validFrameCount is always the RUNNING TOTAL across all batches.
      _validFrameCount = _validResults.length;
      FaceLogger.reg(_sessionId, '  Backend Accepted = $batchAccepted');
      FaceLogger.reg(_sessionId, '  Total Valid      = $_validFrameCount');

      final List<_Phase> allPosesInOrder = [
        _Phase.left,
        _Phase.front,
        _Phase.right,
        _Phase.up,
        _Phase.down,
      ];
      final List<_Phase> failedPoses = [];

      for (int i = 0; i < batchResults.length; i++) {
        final res = batchResults[i];
        final pose = i < allPosesInOrder.length ? allPosesInOrder[i] : _Phase.left;
        final bool accepted = res.embedding != null && res.qualityPassed;
        if (!accepted) {
          failedPoses.add(pose);
        }
      }

      if (failedPoses.isNotEmpty) {
        if (failedPoses.length == 5 || _validFrameCount < 1) {
          FaceLogger.reg(_sessionId, 'Full Quality Retry (All frames rejected)');
          _leftFrames.clear();
          _leftFramesStats.clear();
          _frontFrames.clear();
          _frontFramesStats.clear();
          _rightFrames.clear();
          _rightFramesStats.clear();
          _upFrames.clear();
          _upFramesStats.clear();
          _downFrames.clear();
          _downFramesStats.clear();
          _bestFrames.clear();
          _bestFramesStats.clear();
          _leftAttempts = 0;
          _frontAttempts = 0;
          _rightAttempts = 0;
          _upAttempts = 0;
          _downAttempts = 0;
          _captureCompleted = false;
          _pendingPoses = List.from(allPosesInOrder);

          setState(() {
            _cameraFrozen = false;
            _isProcessingFrame = false;
            _captureProgress = 0;
            _progressLabel = '0 / $_totalTargetFrames';
            _isSubmitting = false;
          });

          _captureStopwatch.start();
          _setPhase(_Phase.left);

          if (!_imageStreamRunning) {
            try {
              await _cameraController?.startImageStream(_onCameraFrame);
              _imageStreamRunning = true;
            } catch (e) {
              _setError('Camera could not start. Please try again.');
              return;
            }
          }

          _updateInstruction(
            'Need clearer frames',
            subtitle: 'Please hold still in good lighting.',
          );
          return;
        } else {
          FaceLogger.reg(
            _sessionId,
            'Partial Quality Retake for failed poses: ${failedPoses.map((p) => p.name).join(", ")}',
          );
          debugPrint(
            '[FACE_REG] Partial retake triggered for failed poses: ${failedPoses.map((p) => p.name).join(", ")}',
          );

          for (final pose in failedPoses) {
            _bestFrames.remove(pose);
            _bestFramesStats.remove(pose);

            if (pose == _Phase.left) {
              _leftFrames.clear();
              _leftFramesStats.clear();
              _leftAttempts = 0;
            } else if (pose == _Phase.front) {
              _frontFrames.clear();
              _frontFramesStats.clear();
              _frontAttempts = 0;
            } else if (pose == _Phase.right) {
              _rightFrames.clear();
              _rightFramesStats.clear();
              _rightAttempts = 0;
            } else if (pose == _Phase.up) {
              _upFrames.clear();
              _upFramesStats.clear();
              _upAttempts = 0;
            } else if (pose == _Phase.down) {
              _downFrames.clear();
              _downFramesStats.clear();
              _downAttempts = 0;
            }
          }

          _pendingPoses = allPosesInOrder.where((p) => failedPoses.contains(p)).toList();
          _captureCompleted = false;

          setState(() {
            _cameraFrozen = false;
            _isProcessingFrame = false;
            _captureProgress =
                _leftFrames.length +
                _frontFrames.length +
                _rightFrames.length +
                _upFrames.length +
                _downFrames.length;
            _progressLabel = '$_captureProgress / $_totalTargetFrames';
            _isSubmitting = false;
          });

          _captureStopwatch.start();

          final _Phase firstFailedPose = _pendingPoses.first;
          _showHintOnce(
            firstFailedPose,
            'Retaking ${firstFailedPose.name} for better quality…',
          );
          _setPhase(firstFailedPose);

          if (!_imageStreamRunning) {
            try {
              await _cameraController?.startImageStream(_onCameraFrame);
              _imageStreamRunning = true;
            } catch (e) {
              _setError('Camera could not start. Please try again.');
              return;
            }
          }
          return;
        }
      }

      _templateStopwatch.start();
      final List<double>? leftEmbedding = batchResults[0].embedding;
      final List<double>? frontEmbedding = batchResults[1].embedding;
      final List<double>? rightEmbedding = batchResults[2].embedding;
      final List<double>? upEmbedding = batchResults[3].embedding;
      final List<double>? downEmbedding = batchResults[4].embedding;

      if (leftEmbedding == null ||
          frontEmbedding == null ||
          rightEmbedding == null ||
          upEmbedding == null ||
          downEmbedding == null) {
        _setError('Could not generate face embeddings. Please try again.');
        return;
      }

      _templateStopwatch.stop();

      _updateInstruction('Almost done!', subtitle: 'Saving your registration');
      FaceLogger.reg(_sessionId, 'Uploading To Supabase');

      _uploadStopwatch.start();
      // ── Upload registration photo to Supabase Storage
      final String? photoUrl = await _uploadRegistrationPhoto();

      // ── Save to students table in Supabase
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('User not logged in');
      final userId = user.id;

      final studentData = await Supabase.instance.client
          .from('students')
          .select('face_template_version, face_registered')
          .eq('id', userId)
          .maybeSingle();

      final bool isAlreadyRegistered =
          studentData?['face_registered'] as bool? ?? false;
      final int existingVersion =
          (studentData?['face_template_version'] as num?)?.toInt() ?? 0;
      final int newTemplateVersion =
          isAlreadyRegistered ? (existingVersion + 1) : 1;

      try {
        await Supabase.instance.client
            .from('students')
            .update({
              'embedding_a': leftEmbedding,
              'embedding_b': frontEmbedding,
              'embedding_c': rightEmbedding,
              'embedding_up': upEmbedding,
              'embedding_down': downEmbedding,
              'face_embedding': frontEmbedding, // Frontal fallback only, no master averaging!
              'verification_threshold': 0.68, // Fixed global threshold
              'registration_photo_url': photoUrl,
              'face_registered': true,
              'face_template_updated_at':
                  DateTime.now().toUtc().toIso8601String(),
              'face_template_version': newTemplateVersion,
              'embedding_model_name': 'insightface_buffalo_l',
              'embedding_model_version': 'v1',
              'embedding_dimension': 512,
            })
            .eq('id', userId);
        _uploadStopwatch.stop();
        _totalStopwatch.stop();

        // Compute quality stats for display in summary
        final double avgQuality = _validResults.isEmpty
            ? 0.0
            : _validResults
                      .map((e) => e.rawQualityScore)
                      .reduce((a, b) => a + b) /
                  _validResults.length;

        final int framesAccepted = _validFrameCount;
        final int framesRejected = _totalFramesCaptured - framesAccepted;

        final double avgLocalBrightness = _frontFramesStats.isEmpty
            ? 0.0
            : _frontFramesStats
                      .map((s) => s['brightness'] ?? 0.0)
                      .reduce((a, b) => a + b) /
                  _frontFramesStats.length;
        final double avgLocalSharpness = _frontFramesStats.isEmpty
            ? 0.0
            : _frontFramesStats
                      .map((s) => s['sharpness'] ?? 0.0)
                      .reduce((a, b) => a + b) /
                  _frontFramesStats.length;

        final double avgYaw = _validResults.isEmpty
            ? 0.0
            : _validResults.map((r) => r.yaw).reduce((a, b) => a + b) /
                  _validResults.length;
        final double avgPitch = _validResults.isEmpty
            ? 0.0
            : _validResults.map((r) => r.pitch).reduce((a, b) => a + b) /
                  _validResults.length;

        // Save registration averages to SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('reg_yaw_$userId', avgYaw);
        await prefs.setDouble('reg_pitch_$userId', avgPitch);
        await prefs.setDouble('reg_brightness_$userId', avgLocalBrightness);

        debugPrint('[FACE_REG][$_sessionId]');
        debugPrint('=========================');
        debugPrint('FACE REGISTRATION SUMMARY');
        debugPrint('=========================');
        debugPrint('Frames Captured=$_totalFramesCaptured');
        debugPrint('Frames Accepted=$framesAccepted');
        debugPrint('Frames Rejected=$framesRejected');
        debugPrint('Average Brightness=${avgLocalBrightness.round()}');
        debugPrint('Average Sharpness=${avgLocalSharpness.round()}');
        debugPrint('Average Yaw=${avgYaw.round()}');
        debugPrint('Average Pitch=${avgPitch.round()}');
        debugPrint('Average Quality=${avgQuality.round()}');
        debugPrint('=========================');
      } catch (e) {
        _uploadStopwatch.stop();
        _totalStopwatch.stop();
        FaceLogger.reg(_sessionId, 'Save failed: $e');
        setState(() {
          _phase = _Phase.error;
          _isSubmitting = false;
        });
        return;
      }

      await _landmarkService.clearEmbeddingsCache();

      if (mounted) {
        Navigator.pushReplacementNamed(
          context,
          '/face_preview',
          arguments: {
            'photoBytes': _registrationPhotoBytes,
            'faceBbox': _registrationPhotoBbox,
          },
        );
      }
    } catch (e) {
      _setError('Registration failed: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<String?> _uploadRegistrationPhoto() async {
    // Preview screen handles the photo upload with better quality
    return null;
  }

  // _saveToSupabase — removed; Supabase save logic is now inline in _processAndUpload

  // ─────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  // Convert CameraImage to ML Kit InputImage
  int _consecutiveImageErrors = 0;

  InputImage? _convertToInputImage(CameraImage image) {
    try {
      final camera = _cameraController!.description;

      // Use sensorOrientation directly for ML Kit rotation.
      // This is the standard approach from Google's ML Kit documentation.
      // The previous code incorrectly flipped front camera rotation
      // (90→270, 270→90), causing ML Kit to see images sideways
      // and detect zero faces.
      final int sensorDegrees = camera.sensorOrientation;
      final InputImageRotation? rotation = InputImageRotationValue.fromRawValue(
        sensorDegrees,
      );
      if (rotation == null) return null;

      // Validate format
      final format = InputImageFormatValue.fromRawValue(image.format.raw);
      if (format == null) return null;
      if (image.planes.isEmpty) return null;

      // ── Build NV21 byte buffer from YUV_420_888 ────────────────────────
      // NV21 = Y plane (w*h bytes) + interleaved VU plane (w*h/2 bytes)
      // This format is much more reliable with ML Kit on Android than
      // raw YUV_420_888 plane concatenation, which breaks on devices
      // where planes have row-stride padding.
      final Uint8List bytes;
      if (image.planes.length >= 3) {
        // YUV_420_888 → build NV21
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

        // Copy Y plane row by row (handles row-stride padding)
        for (int row = 0; row < h; row++) {
          final int srcOffset = row * yRowStride;
          for (int col = 0; col < w; col++) {
            nv21[pos++] = yPlane.bytes[srcOffset + col];
          }
        }

        // Interleave V and U (NV21 = VU interleaved)
        final int uvHeight = h ~/ 2;
        final int uvWidth = w ~/ 2;
        for (int row = 0; row < uvHeight; row++) {
          final int srcOffset = row * uvRowStride;
          for (int col = 0; col < uvWidth; col++) {
            final int pixelOffset = srcOffset + col * uvPixelStride;
            nv21[pos++] = vPlane.bytes[pixelOffset]; // V first (NV21)
            nv21[pos++] = uPlane.bytes[pixelOffset]; // then U
          }
        }

        bytes = nv21;
      } else {
        // Single plane (JPEG/BGRA) — use directly
        bytes = image.planes[0].bytes;
      }

      _consecutiveImageErrors = 0; // reset on success

      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.width, // NV21: bytesPerRow = width
        ),
      );
    } catch (_) {
      _consecutiveImageErrors++;
      // If too many consecutive errors, stop the stream to prevent crash
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

  // Select the biggest face by area and verify it's centered in the UI circle.
  // Essential for classroom environments where background students may be detected.
  Face? _selectBiggestCenteredFace(List<Face> faces, CameraImage image) {
    if (faces.isEmpty) return null;

    // Sort by bounding box area descending (largest face first)
    final sorted = List<Face>.from(faces)
      ..sort((a, b) {
        final double areaA = a.boundingBox.width * a.boundingBox.height;
        final double areaB = b.boundingBox.width * b.boundingBox.height;
        return areaB.compareTo(areaA);
      });

    final Face biggest = sorted.first;
    final double biggestArea =
        biggest.boundingBox.width * biggest.boundingBox.height;

    // Verify the biggest face is reasonably centered horizontally
    final double centerX =
        biggest.boundingBox.left + biggest.boundingBox.width / 2;
    final double imageCenterX = image.width / 2.0;
    final double offsetX = (centerX - imageCenterX).abs() / image.width;

    if (offsetX > 0.30) {
      // Biggest face is not centered enough — likely a background person
      debugPrint(
        '[FACE_REG] Biggest face rejected: offsetX=${offsetX.toStringAsFixed(3)} > 0.30',
      );
      return null;
    }

    if (sorted.length > 1) {
      final double secondArea =
          sorted[1].boundingBox.width * sorted[1].boundingBox.height;
      if (secondArea > 0.50 * biggestArea) {
        if (offsetX > 0.20) {
          debugPrint(
            '[FACE_REG] Second face present (>50% area) and largest face offsetX (${offsetX.toStringAsFixed(3)}) > 0.20 — requiring main person centered',
          );
          return null;
        }
      }

      debugPrint(
        '[FACE_REG] Biggest face filter: ${faces.length} faces detected, '
        'selected largest (area=${biggestArea.toStringAsFixed(0)}), '
        'ignored ${faces.length - 1} background face(s)',
      );
    }

    return biggest;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FACE POSITIONING — smoothed centering + distance + hysteresis
  // ─────────────────────────────────────────────────────────────────────────

  /// Push one frame of raw face data into the smoothing ring buffer.
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

  /// Arithmetic mean of a buffer list.
  double _bufAvg(List<double> buf) {
    if (buf.isEmpty) return 0;
    return buf.reduce((a, b) => a + b) / buf.length;
  }

  /// Reset smoothing buffer and hysteresis state.
  void _clearSmoothing() {
    _bufFaceWidth.clear();
    _bufFaceHeight.clear();
    _bufFaceCX.clear();
    _bufFaceCY.clear();
    _bufYaw.clear();
    _bufPitch.clear();
    _lastPosInstruction = null;
  }

  /// Log hysteresis-triggered instruction changes with [FACE_REG] prefix.
  void _logInstructionChange(String newInstruction) {
    if (_lastPosInstruction != newInstruction) {
      debugPrint(
        '[FACE_REG] Instruction Change: '
        '${_lastPosInstruction ?? "Accepted"} -> $newInstruction (Hysteresis Triggered)',
      );
    }
  }

  /// Checks if the largest detected face is centered within the UI circle and
  /// at the correct distance, using **smoothed** (5-frame moving average) face
  /// metrics and **hysteresis** (safety gaps) to prevent flickering.
  ///
  /// Returns `null` when the face is properly positioned, or a user-facing
  /// instruction string explaining what to adjust.
  ///
  /// Grace zone: 25% of circle size (strict) / 40% (relaxed during liveness).
  String? _getPositioningInstruction(
    Face face,
    CameraImage image, {
    bool strict = true,
  }) {
    if (_uiCircleSize == 0 || _uiAvailW == 0) return null; // layout not ready

    // ── Rotated camera dimensions (portrait) ──────────────────────────────
    final int sensorOrientation =
        _cameraController!.description.sensorOrientation;
    final bool isRotated = sensorOrientation == 90 || sensorOrientation == 270;
    final double rotW = isRotated
        ? image.height.toDouble()
        : image.width.toDouble();
    final double rotH = isRotated
        ? image.width.toDouble()
        : image.height.toDouble();

    // Scale from camera image pixels → screen (logical) pixels
    final double scale = _uiAvailW / rotW;

    // Circle center in camera coordinates
    final double circleCameraCX = rotW / 2;
    final double circleTop = _uiAvailH * 0.40 - _uiCircleSize / 2;
    final double circleCameraCY = rotH / 2 + circleTop / scale;

    // Circle diameter in camera pixels
    final double circleCameraSize = _uiCircleSize / scale;

    // ── Use smoothed (5-frame averaged) face metrics ────────────────────
    final double smoothW = _bufAvg(_bufFaceWidth);
    final double smoothH = _bufAvg(_bufFaceHeight);
    final double smoothCX = _bufAvg(_bufFaceCX);
    final double smoothCY = _bufAvg(_bufFaceCY);

    // Smoothed bounding-box edges
    final double smoothLeft = smoothCX - smoothW / 2;
    final double smoothRight = smoothCX + smoothW / 2;
    final double smoothTop = smoothCY - smoothH / 2;
    final double smoothBottom = smoothCY + smoothH / 2;

    final double circleRadius = circleCameraSize / 2;

    // ── 1. PRIORITY: Virtual Crown (Hairline) + Strict Boundary ──────────
    // ML Kit bounding box top is at the eyebrow, not the hairline.
    // Extend upward by 30% of face height to approximate the real crown/hair.
    final double virtualCrownTop = smoothTop - (smoothH * 0.30);

    // Absolute circle edge coordinates
    final double circleTopBound = circleCameraCY - circleRadius;
    final double circleBottomBound = circleCameraCY + circleRadius;
    final double circleLeftBound = circleCameraCX - circleRadius;
    final double circleRightBound = circleCameraCX + circleRadius;

    debugPrint(
      '[BOUNDARY_DEBUG] Crown: ${virtualCrownTop.toStringAsFixed(1)} | CircleTop: ${circleTopBound.toStringAsFixed(1)}',
    );

    // Hair/Crown touching or crossing the top of the circle
    if (virtualCrownTop < circleTopBound) {
      _logInstructionChange('Move slightly backward');
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }
    // Chin touching or crossing the bottom
    if (smoothBottom > circleBottomBound) {
      _logInstructionChange('Move slightly backward');
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }
    // Cheeks touching or crossing the sides
    if (smoothLeft < circleLeftBound || smoothRight > circleRightBound) {
      _logInstructionChange('Move slightly backward');
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }

    // ── 2. Distance check with hysteresis ───────────────────────────────
    final double faceWidthRatio = smoothW / circleCameraSize;
    final bool wasTooFar = _lastPosInstruction == 'Move closer to the camera';
    final bool wasTooClose = _lastPosInstruction == 'Move slightly backward';

    // Enter "closer": ratio < 0.40
    // Stay in "closer" until ratio >= 0.45 (safety gap prevents flicker)
    if (faceWidthRatio < 0.40 || (wasTooFar && faceWidthRatio < 0.45)) {
      _logInstructionChange('Move closer to the camera');
      _lastPosInstruction = 'Move closer to the camera';
      return 'Move closer to the camera';
    }

    // Enter "backward": ratio > 0.90 (comfortable close distance)
    // Stay "backward" until ratio <= 0.75
    final double backwardEnter = (_lastPosInstruction == null) ? 0.95 : 0.80;
    if (faceWidthRatio > backwardEnter ||
        (wasTooClose && faceWidthRatio > 0.75)) {
      _logInstructionChange('Move slightly backward');
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }

    // ── 3. Relaxed Visual centering — 20/25% grace zone ────────────
    // Only checked AFTER virtual crown and all edges are safely inside.
    final double graceZoneX =
        circleRadius * 0.20; // Expanded horizontal tolerance
    final double graceZoneY =
        circleRadius * 0.25; // Expanded vertical tolerance

    // Horizontal (front camera is mirrored)
    final double offX = (smoothCX - circleCameraCX).abs();
    if (offX > graceZoneX) {
      _logInstructionChange('Move to the center of the circle');
      _lastPosInstruction = 'Move to the center of the circle';
      return 'Move to the center of the circle';
    }

    // Vertical (not mirrored)
    final double offY = (smoothCY - circleCameraCY).abs();
    if (offY > graceZoneY) {
      _logInstructionChange('Move to the center of the circle');
      _lastPosInstruction = 'Move to the center of the circle';
      return 'Move to the center of the circle';
    }

    // ── All checks passed — face is well-positioned ─────────────────────
    if (_lastPosInstruction != null) {
      debugPrint(
        '[FACE_REG] Instruction Change: $_lastPosInstruction -> Accepted (Centered)',
      );
    }
    _lastPosInstruction = null;

    final int stableMs = _steadyStartTime != null
        ? DateTime.now().difference(_steadyStartTime!).inMilliseconds
        : 0;
    debugPrint(
      '[FACE_REG] Status: Centered | AvgWidth: ${faceWidthRatio.toStringAsFixed(2)} '
      '| CrownTop: ${virtualCrownTop.toStringAsFixed(1)} | CircleTop: ${circleTopBound.toStringAsFixed(1)} '
      '| OffX: ${offX.toStringAsFixed(1)} | OffY: ${offY.toStringAsFixed(1)} '
      '| StableTime: ${stableMs}ms',
    );

    return null; // Face is well-positioned
  }

  // Check face is acceptably centered and sized
  // Phase-aware face acceptability check.
  //
  // FRONT phase: strict 0.25 centerOffset — ensures a clean anchor image.
  // LEFT / RIGHT phases: relaxed 0.45 centerOffset — head turns naturally
  // shift the face bounding box toward one side of the frame.
  bool _isFaceAcceptable(Face face, CameraImage image, _Phase phase) {
    // ── PRIORITY: Virtual Crown Extended-Box boundary check ──────────────
    // If any edge of the extended bounding box (with 30% crown/hair padding
    // on top) is touching or outside the circle, reject immediately —
    // liveness challenges must NOT start.
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

      // Virtual crown — extend top by 30% of face height
      final double virtualCrownTop = smoothTop - (smoothH * 0.30);

      debugPrint(
        '[BOUNDARY_DEBUG] isFaceAcceptable Crown: ${virtualCrownTop.toStringAsFixed(1)} | CircleTop: ${circleTopBound.toStringAsFixed(1)}',
      );

      if (virtualCrownTop < circleTopBound ||
          smoothBottom > circleBottomBound ||
          smoothLeft < circleLeftBound ||
          smoothRight > circleRightBound) {
        debugPrint(
          '[FACE_REG] _isFaceAcceptable() returns false (crown/extended box outside circle boundary)',
        );
        return false;
      }
    }

    final double widthRatio = face.boundingBox.width / image.width;

    // Debug: log widthRatio so we can see what the device actually reports
    debugPrint('WidthRatio: $widthRatio');

    // Relaxed thresholds — bounding box scale varies across devices
    if (widthRatio < 0.12 || widthRatio > 0.85) {
      debugPrint(
        '[FACE_REG] _isFaceAcceptable() returns false (widthRatio: ${widthRatio.toStringAsFixed(3)} outside 0.12-0.85)',
      );
      return false;
    }

    // Phase-dependent centering tolerance
    final double maxOffset = (phase == _Phase.left || phase == _Phase.right)
        ? 0.40
        : 0.25;

    final double centerX = face.boundingBox.left + face.boundingBox.width / 2;
    final double imageCenterX = image.width / 2;
    final double centerOffset = (centerX - imageCenterX).abs() / image.width;

    if (centerOffset > maxOffset) {
      debugPrint(
        '[FACE_REG] _isFaceAcceptable() returns false (centerOffset: ${centerOffset.toStringAsFixed(3)} > $maxOffset for phase=${phase.name})',
      );
      return false;
    }

    // Head pitch check — allow ±35 degrees tolerance (natural downward gaze)
    final double? pitch = face.headEulerAngleX;
    if (pitch != null && pitch.abs() > 35) {
      debugPrint(
        '[FACE_REG] _isFaceAcceptable() returns false (pitch: ${pitch.toStringAsFixed(1)} > 35)',
      );
      return false;
    }

    // (Edge-touch check already handled at top of method)

    debugPrint('[FACE_REG] _isFaceAcceptable() returns true');
    return true;
  }

  // Check head yaw for current capture phase
  bool _isPoseCorrect(Face face, _Phase phase) {
    final double? yawRaw = face.headEulerAngleY;
    if (yawRaw == null) return false;

    final double yaw = -yawRaw;

    final double? pitch = face.headEulerAngleX;
    final double? roll = face.headEulerAngleZ;
    final double tolerance = (phase == _Phase.left || phase == _Phase.right)
        ? 20
        : 15;
    if (roll != null && roll.abs() > tolerance) return false;

    switch (phase) {
      case _Phase.left:
        if (pitch != null && pitch.abs() > tolerance) return false;
        return yaw >= -25 && yaw <= -10;
      case _Phase.front:
        if (pitch != null && pitch.abs() > tolerance) return false;
        return yaw.abs() <= 5;
      case _Phase.right:
        if (pitch != null && pitch.abs() > tolerance) return false;
        return yaw >= 10 && yaw <= 25;
      case _Phase.up:
        if (yaw.abs() > 10.0) return false;
        if (pitch == null) return false;
        // Strictly require looking UP (positive pitch)
        return pitch > 5.0 && pitch < 30.0;
      case _Phase.down:
        if (yaw.abs() > 10.0) return false;
        if (pitch == null) return false;
        // Strictly require looking DOWN (negative pitch)
        return pitch < -5.0 && pitch > -30.0;
      default:
        return true;
    }
  }

  String? _getGentlePoseFeedback(Face face, _Phase phase) {
    final double? yawRaw = face.headEulerAngleY;
    if (yawRaw == null) return null;
    final double yaw = -yawRaw;

    final double? pitch = face.headEulerAngleX;
    final double? roll = face.headEulerAngleZ;
    final double tolerance = (phase == _Phase.left || phase == _Phase.right)
        ? 20
        : 15;
    if (roll != null && roll.abs() > tolerance) {
      return 'Do not tilt your head';
    }

    if (phase == _Phase.up || phase == _Phase.down) {
      if (yaw.abs() > 10.0) {
        return 'Look straight ahead';
      }
      if (phase == _Phase.up) {
        if (pitch != null && pitch < 5.0) return 'Look slightly up';
        if (pitch != null && pitch > 30.0) return 'Reduce head movement slightly';
      }
      if (phase == _Phase.down) {
        if (pitch != null && pitch > -5.0) return 'Look slightly down';
        if (pitch != null && pitch < -30.0) return 'Reduce head movement slightly';
      }
      return null;
    }

    if (pitch != null && pitch.abs() > tolerance) {
      return 'Hold your head level';
    }

    switch (phase) {
      case _Phase.left:
        if (yaw > -10.0 && yaw <= -5.0) {
          return 'Turn a bit more left';
        }
        if (yaw < -25.0 && yaw >= -30.0) {
          return 'Turn slightly right';
        }
        break;
      case _Phase.right:
        if (yaw < 10.0 && yaw >= 5.0) {
          return 'Turn a bit more right';
        }
        if (yaw > 25.0 && yaw <= 30.0) {
          return 'Turn slightly left';
        }
        break;
      case _Phase.front:
        if ((yaw > -10.0 && yaw <= -5.0) || (yaw >= 5.0 && yaw < 10.0)) {
          return 'Look straight at the camera';
        }
        break;
      default:
        break;
    }
    return null;
  }

  bool _validateFrameQuality(
    Face face,
    CameraImage image,
    _Phase phase,
    List<String> rejectionReasons,
    Map<String, double> stats, {
    double sharpnessMin = 2.0,
    double brightMin = 45.0,
    double brightMax = 230.0,
  }) {
    final imgStats = _cameraStabilizer.computeFrameStats(
      image,
      faceBoundingBox: face.boundingBox,
      sensorOrientation: _cameraController!.description.sensorOrientation,
    );
    final double sharpness = imgStats['sharpness'] ?? 0.0;
    final double brightness = imgStats['brightness'] ?? 0.0;
    final double contrast = imgStats['contrast'] ?? 0.0;

    stats['sharpness'] = sharpness;
    stats['brightness'] = brightness;
    stats['contrast'] = contrast;
    stats['yaw'] = face.headEulerAngleY != null ? -face.headEulerAngleY! : 0.0;
    stats['pitch'] = face.headEulerAngleX ?? 0.0;
    stats['roll'] = face.headEulerAngleZ ?? 0.0;

    final double yaw = stats['yaw']!;
    final double pitch = stats['pitch']!;
    final double roll = stats['roll']!;

    final double pitchRollTolerance =
        (phase == _Phase.left || phase == _Phase.right) ? 20.0 : 15.0;

    if (phase == _Phase.up) {
      if (yaw.abs() > 10.0) rejectionReasons.add("yaw_out_of_range");
      if (pitch <= 5.0 || pitch >= 30.0) rejectionReasons.add("pitch_out_of_range_up");
    } else if (phase == _Phase.down) {
      if (yaw.abs() > 10.0) rejectionReasons.add("yaw_out_of_range");
      if (pitch >= -5.0 || pitch <= -30.0) rejectionReasons.add("pitch_out_of_range_down");
    } else {
      if (pitch.abs() > pitchRollTolerance) {
        rejectionReasons.add("pitch_out_of_range");
      }
      if (roll.abs() > pitchRollTolerance) {
        rejectionReasons.add("roll_out_of_range");
      }

      switch (phase) {
        case _Phase.left:
          if (yaw < -25.0 || yaw > -10.0) {
            rejectionReasons.add("yaw_out_of_range");
          }
          break;
        case _Phase.front:
          if (yaw.abs() > 5.0) {
            rejectionReasons.add("yaw_out_of_range");
          }
          break;
        case _Phase.right:
          if (yaw < 10.0 || yaw > 25.0) {
            rejectionReasons.add("yaw_out_of_range");
          }
          break;
        default:
          break;
      }
    }

    if (sharpness < sharpnessMin) {
      rejectionReasons.add("blur");
    }

    if (brightness > brightMax) {
      rejectionReasons.add("face_overexposed");
    } else if (brightness < brightMin) {
      rejectionReasons.add("face_underexposed");
    }

    final double widthRatio = face.boundingBox.width / image.width;
    stats['width_ratio'] = widthRatio;
    if (widthRatio < 0.20 || widthRatio > 0.80) {
      rejectionReasons.add("face_size_incorrect");
    }

    return rejectionReasons.isEmpty;
  }

  String _getPoseInstruction(_Phase phase) {
    switch (phase) {
      case _Phase.left:
        return 'Turn slightly left and hold still.';
      case _Phase.front:
        return 'Look straight at the camera.';
      case _Phase.right:
        return 'Turn slightly right and hold still.';
      case _Phase.up:
        return 'Look slightly up and hold still.';
      case _Phase.down:
        return 'Look slightly down and hold still.';
      default:
        return 'Hold still…';
    }
  }

  // Get instruction based on face position in frame
  String _getFacingInstruction(Face face, CameraImage image) {
    final double imageArea = image.width * image.height.toDouble();
    final double faceArea = face.boundingBox.width * face.boundingBox.height;
    final double coverageRatio = faceArea / imageArea;

    if (coverageRatio < 0.08) return 'Move closer';
    if (coverageRatio > 0.75) return 'Move back';

    final double? pitch = face.headEulerAngleX;
    if (pitch != null && pitch > 15) return 'Fit your face in the circle';

    return 'Fit your face in the circle';
  }

  // Capture current camera frame as JPEG bytes
  Future<Uint8List?> _captureCurrentFrame() async {
    try {
      if (_lastCameraImage == null) return null;
      final camImg = _lastCameraImage!;

      // If camera delivers JPEG directly (some Xiaomi devices do this)
      if (camImg.format.group == ImageFormatGroup.jpeg) {
        return Uint8List.fromList(camImg.planes[0].bytes);
      }

      // For YUV420 — convert synchronously on this thread
      // This is safe because _onCameraFrame already skips if isProcessingFrame
      // so we are never doing this on multiple threads at once
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

  // ─── UI state updates ─────────────────────────────────────────────────────

  void _setPhase(_Phase newPhase) {
    if (!mounted) return;
    if (_phase == newPhase) return;

    if (newPhase != _Phase.error && newPhase != _Phase.liveness) {
      HapticFeedback.mediumImpact();
      _successBounceController.forward(from: 0.0);
    }
    if (newPhase == _Phase.done) {
      _particleController.forward(from: 0.0);
    }

    setState(() {
      _phase = newPhase;
    });

    // Only reset challenge state for the liveness phase.
    // For capture phases (left/front/right), _challengeVerified stays true.
    if (newPhase == _Phase.liveness) {
      _challengeVerified = false;
      _challengeStartTime = null;
      _livenessService.reset();
      _steadyStartTime = null;
      _isFaceReady = false;
      _clearSmoothing();
    }

    if (newPhase == _Phase.left ||
        newPhase == _Phase.front ||
        newPhase == _Phase.right ||
        newPhase == _Phase.up ||
        newPhase == _Phase.down) {
      _poseSteadyStartTime = null;
      _poseSteadyPhase = null;
    }

    // Update instruction text for new phase
    switch (newPhase) {
      case _Phase.liveness:
        _blinkCountdownController.reset();
        _updateInstruction(
          'Fit your face in the circle',
          subtitle: 'Centre your face and hold steady to begin',
        );
        break;
      case _Phase.left:
        _updateInstruction(
          'Turn slightly left',
          subtitle: 'Turn slightly left and hold still',
        );
        break;
      case _Phase.front:
        _updateInstruction(
          'Look straight ahead',
          subtitle: 'Getting your front profile',
        );
        break;
      case _Phase.right:
        _updateInstruction(
          'Turn slightly right',
          subtitle: 'Turn slightly right and hold still',
        );
        break;
      case _Phase.up:
        _updateInstruction(
          'Look slightly up',
          subtitle: 'Look slightly up and hold still',
        );
        break;
      case _Phase.down:
        _updateInstruction(
          'Look slightly down',
          subtitle: 'Look slightly down and hold still',
        );
        break;
      case _Phase.processing:
        _updateInstruction(
          'Creating Face Profile',
          subtitle: 'Please wait while we securely process your face.',
        );
        break;
      case _Phase.done:
        _updateInstruction(
          'Registration complete!',
          subtitle: 'Your face has been registered',
        );
        break;
      case _Phase.error:
        // handled by _setError
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
          // Force blink timer to reset and start
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

  // FIXED: debugPrint full error for logs, show short user-friendly message in UI
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
  // DISPOSE — must stop stream before disposing controller
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void dispose() {
    debugPrint('[CAPTURE] Disposed');
    _instructionDebounceTimer?.cancel();
    _pulseController.dispose();
    _textFadeController.dispose();
    _blinkCountdownController.dispose();
    _successBounceController.dispose();
    _particleController.dispose();

    // Stop image stream FIRST, then dispose
    if (_cameraController != null && _cameraInitialized) {
      try {
        _cameraController!.stopImageStream();
      } catch (_) {}
      _cameraController!.dispose();
    }

    _mlService.faceDetector.close();
    super.dispose();
  }

  bool _isPoseStageCompleted(_Phase pose) {
    if (pose == _Phase.left) {
      return _leftFrames.length >= targetFramesForPose(_Phase.left) ||
          _bestFrames.containsKey(_Phase.left);
    } else if (pose == _Phase.front) {
      return _frontFrames.length >= targetFramesForPose(_Phase.front) ||
          _bestFrames.containsKey(_Phase.front);
    } else if (pose == _Phase.right) {
      return _rightFrames.length >= targetFramesForPose(_Phase.right) ||
          _bestFrames.containsKey(_Phase.right);
    } else if (pose == _Phase.up) {
      return _upFrames.length >= targetFramesForPose(_Phase.up) ||
          _bestFrames.containsKey(_Phase.up);
    } else if (pose == _Phase.down) {
      return _downFrames.length >= targetFramesForPose(_Phase.down) ||
          _bestFrames.containsKey(_Phase.down);
    }
    return false;
  }

  Widget _buildStageNode(String label, _Phase pose) {
    final bool isCompleted = _isPoseStageCompleted(pose);
    final bool isActive = _phase == pose;

    Color circleBgColor;
    Border circleBorder;
    List<BoxShadow>? circleShadow;
    Widget circleChild;
    Color labelColor;

    if (isCompleted) {
      circleBgColor = const Color(0xFF2ECC71); // Emerald Green
      circleBorder = Border.all(color: const Color(0xFF2ECC71), width: 1.5);
      circleShadow = null;
      circleChild = const Icon(Icons.check, color: Colors.white, size: 14);
      labelColor = const Color(0xFF2ECC71);
    } else if (isActive) {
      circleBgColor = Colors.white;
      circleBorder = Border.all(color: AppStyles.primaryBlue, width: 2.0);
      circleShadow = [
        BoxShadow(
          color: AppStyles.primaryBlue.withValues(alpha: 0.20),
          blurRadius: 6,
          spreadRadius: 1,
        ),
      ];
      circleChild = Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: AppStyles.primaryBlue,
          shape: BoxShape.circle,
        ),
      );
      labelColor = AppStyles.primaryBlue;
    } else {
      circleBgColor = Colors.white;
      circleBorder = Border.all(color: const Color(0xFFD1D5DB), width: 1.5);
      circleShadow = null;
      circleChild = Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: Color(0xFF9CA3AF),
          shape: BoxShape.circle,
        ),
      );
      labelColor = const Color(0xFF6B7280);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: circleBgColor,
            shape: BoxShape.circle,
            border: circleBorder,
            boxShadow: circleShadow,
          ),
          child: Center(child: circleChild),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: labelColor,
          ),
        ),
      ],
    );
  }

  Widget _buildStageConnector(bool isLeftCompleted) {
    return Container(
      margin: const EdgeInsets.only(top: 12, left: 2, right: 2),
      height: 2,
      color: isLeftCompleted ? const Color(0xFF2ECC71) : const Color(0xFFD1D5DB),
    );
  }

  Widget _buildStageIndicators() {
    final bool leftDone = _isPoseStageCompleted(_Phase.left);
    final bool frontDone = _isPoseStageCompleted(_Phase.front);
    final bool rightDone = _isPoseStageCompleted(_Phase.right);
    final bool upDone = _isPoseStageCompleted(_Phase.up);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStageNode('Left', _Phase.left),
          Expanded(child: _buildStageConnector(leftDone)),
          _buildStageNode('Front', _Phase.front),
          Expanded(child: _buildStageConnector(frontDone)),
          _buildStageNode('Right', _Phase.right),
          Expanded(child: _buildStageConnector(rightDone)),
          _buildStageNode('Up', _Phase.up),
          Expanded(child: _buildStageConnector(upDone)),
          _buildStageNode('Down', _Phase.down),
        ],
      ),
    );
  }

  Widget _buildCardContent() {
    final bool isPoseCapture =
        _phase == _Phase.left ||
        _phase == _Phase.front ||
        _phase == _Phase.right ||
        _phase == _Phase.up ||
        _phase == _Phase.down;

    if (isPoseCapture) {
      int currentAccepted = 0;
      if (_phase == _Phase.left) {
        currentAccepted = _leftFrames.length;
      } else if (_phase == _Phase.front) {
        currentAccepted = _frontFrames.length;
      } else if (_phase == _Phase.right) {
        currentAccepted = _rightFrames.length;
      } else if (_phase == _Phase.up) {
        currentAccepted = _upFrames.length;
      } else if (_phase == _Phase.down) {
        currentAccepted = _downFrames.length;
      }

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Pose Capture',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1A202C),
              letterSpacing: -0.3,
            ),
          ),
          _buildStageIndicators(),
          const SizedBox(height: 8),
          Text(
            _instructionTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppStyles.primaryBlue,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Accepted: $currentAccepted / ${targetFramesForPose(_phase)}',
            style: const TextStyle(
              fontSize: 13,
              color: Colors.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    // Default instruction card content (Blink, Processing, Error, Done)
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
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
        _instructionTitle == 'Move to the center of the circle'
            ? const SizedBox.shrink()
            : const SizedBox(height: 2),
        Text(
          _instructionSubtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (_phase == _Phase.processing) ...[
          const SizedBox(height: 16),
          const CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(AppStyles.primaryBlue),
          ),
        ],
        if (_phase == _Phase.error) ...[
          const SizedBox(height: 16),
          TextButton(
            onPressed: _onRetry,
            child: const Text(
              'Try Again',
              style: TextStyle(
                color: AppStyles.primaryBlue,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD — preserved from original UI exactly
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppStyles.backgroundLight,
        body: SafeArea(
          child: Column(
            children: [
              // ── Top App Bar (original) ──────────────────────────────────
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
                            'Step 2 of 3',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF4A5568),
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                              inherit: false,
                            ),
                          ),
                          const Text(
                            'Face Registration',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1A202C),
                              letterSpacing: -0.3,
                              inherit: false,
                            ),
                          ),
                          // Progress indicator below title
                          if (_captureProgress > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                _progressLabel,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppStyles.primaryBlue,
                                  fontWeight: FontWeight.w500,
                                  inherit: false,
                                ),
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

              // ── Camera Preview — uses Expanded to fill available space ──
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final double availW = constraints.maxWidth;
                    final double availH = constraints.maxHeight;
                    final double circleSize = availW * 0.80;
                    final double circleTop = availH * 0.40 - circleSize / 2;

                    // Store layout info for face positioning calculations
                    _uiCircleSize = circleSize;
                    _uiAvailW = availW;
                    _uiAvailH = availH;

                    double offsetX = 0;
                    double offsetY = 0;
                    if (_cameraInitialized && _bufFaceCX.isNotEmpty) {
                      final Size? previewSize =
                          _cameraController?.value.previewSize;
                      final double sensorW =
                          previewSize?.height ?? 3.0; // Swapped for portrait
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
                          // Background — solid color, no camera here
                          Positioned.fill(
                            child: Container(color: AppStyles.backgroundLight),
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
                                // Circle clip for the preview
                                Positioned(
                                  left: (availW - circleSize) / 2,
                                  top:
                                      circleTop -
                                      100, // Visually shift upward by 100px (final slight adjustment)
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
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),

                                // Pulsing circle border + Directional Guidance, Liquid Progress, and Bounce
                                Positioned(
                                  left: (availW - circleSize) / 2,
                                  top:
                                      circleTop -
                                      100, // Visually shift upward by 100px (final slight adjustment)
                                  child: ScaleTransition(
                                    scale: Tween<double>(begin: 1.0, end: 1.05)
                                        .animate(
                                          CurvedAnimation(
                                            parent: _successBounceController,
                                            curve: Curves.elasticOut,
                                          ),
                                        ),
                                    child: TweenAnimationBuilder<double>(
                                      tween: Tween<double>(
                                        begin: 0.0,
                                        end: _captureProgress / _totalTargetFrames.toDouble(),
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

                          // Fill Light Overlay (Premium Soft-Box Effect)
                          Positioned.fill(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 600),
                              curve: Curves.easeOut,
                              opacity: (_phase == _Phase.front)
                                  ? 0.3 // Gently fades in to 30% to act as a Flash
                                  : 0.0,
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

                          // Instant Studio Flash on Capture
                          Positioned.fill(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 100),
                              curve: Curves.easeOut,
                              opacity: _showFlash ? 0.3 : 0.0, // Flash at 30%
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
                            top:
                                circleTop -
                                100, // Visually shift upward by 100px (final slight adjustment)
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

                          // --- Dynamic Layout Column (Countdown, HUD, Instructions) ---
                          Positioned(
                            top: (circleTop - 100) + circleSize + 40,
                            left: 16,
                            right: 16,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 1. Blink countdown indicator (conditional visibility)
                                Builder(
                                  builder: (context) {
                                    final bool showCountdown =
                                        (_instructionTitle ==
                                            'Blink your eyes 2 to 3 times' ||
                                        _instructionSubtitle ==
                                            'Blink your eyes 2 to 3 times' ||
                                        _instructionSubtitle ==
                                            'Blink naturally 2 to 3 times to confirm presence' ||
                                        _instructionTitle.contains(
                                          'Blink to Start',
                                        ));

                                    return AnimatedOpacity(
                                      duration: const Duration(
                                        milliseconds: 300,
                                      ),
                                      opacity: showCountdown ? 1.0 : 0.0,
                                      child: Visibility(
                                        visible:
                                            showCountdown ||
                                            _blinkCountdownController
                                                .isAnimating,
                                        child: Column(
                                          children: [
                                            AnimatedBuilder(
                                              animation:
                                                  _blinkCountdownController,
                                              builder: (context, child) {
                                                final double remaining =
                                                    3.0 *
                                                    (1.0 -
                                                        _blinkCountdownController
                                                            .value);
                                                return SizedBox(
                                                  width: 50,
                                                  height: 50,
                                                  child: Stack(
                                                    alignment: Alignment.center,
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
                                                          backgroundColor:
                                                              Colors
                                                                  .orangeAccent
                                                                  .withValues(
                                                                    alpha: 0.15,
                                                                  ),
                                                        ),
                                                      ),
                                                      AnimatedSwitcher(
                                                        duration:
                                                            const Duration(
                                                              milliseconds: 300,
                                                            ),
                                                        transitionBuilder:
                                                            (
                                                              Widget child,
                                                              Animation<double>
                                                              animation,
                                                            ) {
                                                              return ScaleTransition(
                                                                scale:
                                                                    animation,
                                                                child: FadeTransition(
                                                                  opacity:
                                                                      animation,
                                                                  child: child,
                                                                ),
                                                              );
                                                            },
                                                        child: Text(
                                                          '${remaining.ceil()}',
                                                          key: ValueKey<int>(
                                                            remaining.ceil(),
                                                          ),
                                                          style: const TextStyle(
                                                            fontSize: 18,
                                                            fontWeight:
                                                                FontWeight.w800,
                                                            color: Colors
                                                                .orangeAccent,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              },
                                            ),
                                            const SizedBox(
                                              height: 14,
                                            ), // Gap below countdown
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),

                                // 2. Premium Glassmorphism HUD
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
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
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
                                            final bool isPoseActive =
                                                _phase == _Phase.left ||
                                                _phase == _Phase.front ||
                                                _phase == _Phase.right ||
                                                _phase == _Phase.up ||
                                                _phase == _Phase.down;
                                            final bool isPoseDone =
                                                _bestFrames.containsKey(
                                                  _Phase.left,
                                                ) &&
                                                _bestFrames.containsKey(
                                                  _Phase.front,
                                                ) &&
                                                _bestFrames.containsKey(
                                                  _Phase.right,
                                                ) &&
                                                _bestFrames.containsKey(
                                                  _Phase.up,
                                                ) &&
                                                _bestFrames.containsKey(
                                                  _Phase.down,
                                                );
                                            return Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                _NeonChip(
                                                  label: 'Blink',
                                                  isActive:
                                                      _phase == _Phase.liveness,
                                                  isDone: _challengeVerified,
                                                  pulseValue:
                                                      _pulseController.value,
                                                ),
                                                _ShimmerLine(
                                                  isDone:
                                                      isPoseActive ||
                                                      isPoseDone,
                                                  pulseController:
                                                      _pulseController,
                                                ),
                                                _NeonChip(
                                                  label: 'Pose Capture',
                                                  isActive: isPoseActive,
                                                  isDone: isPoseDone,
                                                  pulseValue:
                                                      _pulseController.value,
                                                ),
                                                _ShimmerLine(
                                                  isDone:
                                                      _phase == _Phase.done ||
                                                      _phase ==
                                                          _Phase.processing,
                                                  pulseController:
                                                      _pulseController,
                                                ),
                                                _NeonChip(
                                                  label: 'Done',
                                                  isActive:
                                                      _phase ==
                                                      _Phase.processing,
                                                  isDone: _phase == _Phase.done,
                                                  pulseValue:
                                                      _pulseController.value,
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ),

                                const SizedBox(height: 18), // Reduced gap
                                // 3. Instruction card
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
                                    child: AnimatedSize(
                                      duration: const Duration(
                                        milliseconds: 300,
                                      ),
                                      curve: Curves.easeInOut,
                                      child: Container(
                                        width: double.infinity,
                                        decoration: BoxDecoration(
                                          color: Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          border: Border.all(
                                            color: _phase == _Phase.error
                                                ? AppStyles.errorRed.withValues(
                                                    alpha: 0.3,
                                                  )
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
                                        padding: const EdgeInsets.all(16),
                                        child: _buildCardContent(),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
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
    );
  }

  // Build camera preview — uses AspectRatio for correct 4:3 framing
  Widget _buildCameraPreview(double containerWidth) {
    if (!_cameraInitialized || _cameraController == null) {
      final double circleSize = _uiCircleSize;
      final double circleTop = _uiAvailH * 0.40 - circleSize / 2;
      final double targetCenterY = circleTop + circleSize / 2;
      return SizedBox(
        width: containerWidth,
        height: containerWidth,
        child: Stack(
          children: [
            Container(color: const Color(0xFFF0F4FF)),
            Align(
              alignment: Alignment(
                0.0,
                (targetCenterY / (containerWidth / 2)) - 1.0,
              ),
              child: SizedBox(
                width: 120,
                height: 120,
                child: _PulsingCameraLoader(),
              ),
            ),
          ],
        ),
      );
    }

    // Use AspectRatio to let CameraPreview render at its native proportions.
    // FittedBox.cover then scales—without distortion—to fill the container.
    final Size? previewSize = _cameraController!.value.previewSize;
    // Android reports sensor dims in landscape; swap for portrait.
    final double sensorW = previewSize?.height ?? 3.0;
    final double sensorH = previewSize?.width ?? 4.0;
    final double previewAspect = sensorW / sensorH; // e.g. 0.75 for 3:4

    return SizedBox(
      width: containerWidth,
      height: containerWidth / previewAspect, // matches 4:3 naturally
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
                  ),
                )
              : CameraPreview(_cameraController!),
        ),
      ),
    );
  }

  void _onRetry() {
    // Reset all state and try again
    _livenessService.reset();
    _leftFrames.clear();
    _leftFramesStats.clear();
    _frontFrames.clear();
    _frontFramesStats.clear();
    _rightFrames.clear();
    _rightFramesStats.clear();
    _upFrames.clear();
    _upFramesStats.clear();
    _downFrames.clear();
    _downFramesStats.clear();
    _bestFrames.clear();
    _bestFramesStats.clear();
    _clientRejectedLogs.clear();
    _leftAttempts = 0;
    _frontAttempts = 0;
    _rightAttempts = 0;
    _upAttempts = 0;
    _downAttempts = 0;

    _validResults.clear();
    _validFrameCount = 0;
    _cameraFrozen = false;
    _lastCapturedFrameBytes = null;
    _isSubmitting = false;

    // Problem 2 & 3: reset both new flags for a fresh registration attempt
    _captureCompleted = false;
    _imageStreamRunning = false;

    _registrationPhotoBytes = null;
    _captureProgress = 0;
    _progressLabel = '';
    _challengeVerified = false;
    _challengeStartTime = null;
    _blinkCountdownController.reset();
    _steadyStartTime = null;
    _isFaceReady = false;
    _poseSteadyStartTime = null;
    _poseSteadyPhase = null;
    _clearSmoothing();

    setState(() {
      _borderColor = AppStyles.primaryBlue;
      _errorMessage = null;
    });

    debugPrint('[FACE_REG] =================================');
    debugPrint('[FACE_REG] Registration Started (Retry)');
    debugPrint('[FACE_REG] Target Frames : $_totalTargetFrames total');
    debugPrint('[FACE_REG] Valid Frames  : 0');
    debugPrint('[FACE_REG] =================================');

    _setPhase(_Phase.liveness);

    if (_cameraController != null && _cameraInitialized) {
      try {
        _cameraController!.stopImageStream().then((_) {
          _imageStreamRunning = false;
          if (mounted) {
            _cameraController!.startImageStream(_onCameraFrame);
            _imageStreamRunning = true;
          }
        });
      } catch (_) {
        // Stream may not have been running — start fresh
        if (!_imageStreamRunning) {
          try {
            _cameraController!.startImageStream(_onCameraFrame);
            _imageStreamRunning = true;
          } catch (_) {}
        }
      }
    }
  }
}

// ─── Phase neon chip ──────────────────────────────────────────────────────────────
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
    await Future.delayed(const Duration(milliseconds: 140)); // Half duration
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
      // Solid Emerald Green Pop
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
      // Glowing Blue Neon Border
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

    // Pending grey state
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

// ─── Fill Light Painter (Premium Soft-Box Effect) ─────────────────────────
class _FillLightPainter extends CustomPainter {
  final Offset circleCenter;
  final double circleRadius;

  _FillLightPainter({required this.circleCenter, required this.circleRadius});

  @override
  void paint(Canvas canvas, Size size) {
    // Punches a hole where the face circle is
    final Path backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final Path circlePath = Path()
      ..addOval(Rect.fromCircle(center: circleCenter, radius: circleRadius));
    final Path fillPath = Path.combine(
      PathOperation.difference,
      backgroundPath,
      circlePath,
    );

    // Radial gradient imitating a soft photography ring/fill light
    final Paint paint = Paint()
      ..shader = RadialGradient(
        center: Alignment(
          (circleCenter.dx / size.width) * 2 - 1,
          (circleCenter.dy / size.height) * 2 - 1,
        ),
        radius: 1.2, // Spread outwards smoothly
        colors: [
          Colors.white,
          const Color(0xFFE2F0FD), // Very light soft blue tint
          Colors.white.withValues(alpha: 0.0), // Fade to edge
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

// ─── Border & Progress Painter ──────────────────────────────────────────────
class _BorderPainter extends CustomPainter {
  final double pulseValue;
  final Color baseColor;
  final double progress; // 0.0 to 1.0
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
    // 2. High-Impact Progress Ring (Emerald Green light-pipe glow)
    if (progress > 0) {
      const Color progressColor = Color(0xFF2ECC71); // Vibrant Emerald
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

      // Draw arc from top (-pi/2) clockwise
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

    // ── 3D Circle Illusion ──
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

    // Directional guidance removed — front-only registration
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

class _ParticleBurstPainter extends CustomPainter {
  final double progress; // 0.0 to 1.0 from _particleController

  _ParticleBurstPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.0 || progress >= 1.0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 1.0 - progress);

    final random = math.Random(
      12345,
    ); // Deterministic seed for stable burst pattern
    for (int i = 0; i < 30; i++) {
      final angle = random.nextDouble() * 2 * math.pi;
      final speed = 50.0 + random.nextDouble() * 100.0;
      final distance = (size.width / 2) + speed * progress;

      final x = center.dx + math.cos(angle) * distance;
      final y = center.dy + math.sin(angle) * distance;

      // Randomly sized rectangular pieces
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
