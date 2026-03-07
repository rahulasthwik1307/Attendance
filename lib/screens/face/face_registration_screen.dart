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

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/face_ml_service.dart';
import '../../utils/app_styles.dart';
import '../../utils/auth_flow_state.dart';

// FIXED: Removed _computeEmbedding isolate function — ML Kit plugins cannot
// run in background isolates (BackgroundIsolateBinaryMessenger error).
// Embedding generation now runs on main thread during capture phase.
// SKILL.md compliant for registration: only 9 frames, each ~15-25ms inference.

// ─── Registration phases ──────────────────────────────────────────────────────
enum _Phase {
  initializing, // Camera starting up
  liveness, // Blink verification (looking straight) — first gate
  left, // Capture 3 left frames (no liveness gate)
  front, // Capture 3 front frames (no blink — just capture)
  right, // Capture 3 right frames (no liveness gate)
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
  // ─── Animation controllers (kept from original UI) ──────────────────────
  late AnimationController _pulseController;
  late AnimationController _textFadeController;
  late AnimationController _blinkCountdownController;

  // ─── Camera ──────────────────────────────────────────────────────────────
  CameraController? _cameraController;
  bool _cameraInitialized = false;

  // ─── ML ──────────────────────────────────────────────────────────────────
  final FaceMlService _mlService = FaceMlService();
  final LivenessChallengeService _livenessService = LivenessChallengeService();
  bool _isProcessingFrame = false;
  DateTime _lastFrameTime = DateTime.now();
  CameraImage? _lastCameraImage;
  DateTime _lastCaptureTime = DateTime.fromMillisecondsSinceEpoch(0);

  // ─── Registration state ───────────────────────────────────────────────────
  _Phase _phase = _Phase.initializing;

  // Captured frame bytes per phase (JPEG)
  final List<Uint8List> _frontFrames = [];
  final List<Uint8List> _leftFrames = [];
  final List<Uint8List> _rightFrames = [];

  // First front frame saved as registration photo
  Uint8List? _registrationPhotoBytes;
  Rect? _registrationFaceBbox;

  // Embeddings per phase
  final List<List<double>> _frontEmbeddings = [];
  final List<List<double>> _leftEmbeddings = [];
  final List<List<double>> _rightEmbeddings = [];

  // How many quality frames to capture per phase
  static const int _framesPerPhase = 3;

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
  int _captureProgress = 0; // 0-9 total frames
  String _progressLabel = '';

  // ignore: unused_field
  String? _errorMessage;

  // ─── Face positioning state ────────────────────────────────────────────
  DateTime? _steadyStartTime;
  bool _isFaceReady = false;
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
    "Hold still…": "Almost ready, stay steady",
    "Blink to verify": "Blink naturally to confirm you are present",
    "Blink your eyes 2-3 times":
        "Blink naturally 2 to 3 times to confirm you are present",
    "Setting up camera…": "Please wait",
    "Calibrating…": "Look straight at the camera and hold still",
    "Look straight ahead": "Getting your front profile",
    "Turn slightly left": "Shift your position slightly to the left",
    "Turn slightly right": "Shift your position slightly to the right",
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

      // Initialize ML service
      await _mlService.initialize();

      // Start camera stream for face detection
      await _cameraController!.startImageStream(_onCameraFrame);
      debugPrint('[FACE_REG] Camera initialized successfully');

      _setPhase(_Phase.liveness);
    } catch (e) {
      _setError('Camera failed to start: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CAMERA FRAME PROCESSING — rate-limited to 10fps
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _onCameraFrame(CameraImage cameraImage) async {
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

      // Push raw face metrics into smoothing buffer for moving average
      _pushSmoothing(face);

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
            debugPrint('[FACE_REG] Liveness verified — moving to left phase');
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
      debugPrint('[FACE_REG] Blink challenge VERIFIED ✓');
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
    // Minimum delay between captures to avoid overwhelming the camera
    final now = DateTime.now();
    if (now.difference(_lastCaptureTime).inMilliseconds < 800) return;

    // Validate pose for current phase
    if (!_isPoseCorrect(face, currentPhase)) {
      _updateInstruction(_getPoseInstruction(currentPhase), animate: false);
      return;
    }

    // Quality + centering check (phase-aware: relaxed offset for side turns)
    if (!_isFaceAcceptable(face, cameraImage, currentPhase)) {
      _updateInstruction(
        _getFacingInstruction(face, cameraImage),
        animate: false,
      );
      return;
    }

    _updateInstruction('Hold still…', subtitle: 'Almost done, stay steady');

    // Grab the current frame as JPEG
    final Uint8List? jpegBytes = await _captureCurrentFrame();
    if (jpegBytes == null) return;
    debugPrint(
      '[FACE_REG] CAPTURE frame accepted | phase=${currentPhase.name} size=${jpegBytes.length}b',
    );

    // Save first front frame as registration photo
    if (currentPhase == _Phase.front && _registrationPhotoBytes == null) {
      _registrationPhotoBytes = jpegBytes;
      _registrationFaceBbox = face.boundingBox;
      debugPrint(
        '[FACE_REG] ✓ FRONT photo saved — bbox=${face.boundingBox} yaw=${face.headEulerAngleY?.toStringAsFixed(1)}',
      );
    }

    // Update progress BEFORE heavy embedding calculation to un-freeze UI
    setState(() {
      _captureProgress++;
      _progressLabel = '$_captureProgress / ${_framesPerPhase * 3}';
      _borderColor = AppStyles.successGreen;
    });
    HapticFeedback.lightImpact();

    // Allow UI to render the progress ring update and green flash smoothly
    await Future.delayed(const Duration(milliseconds: 40));

    // 5. Briefly trigger the flash effect
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

    // 6. Restore border color slightly after
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted && _phase == currentPhase) {
        setState(() {
          _borderColor = AppStyles.primaryBlue;
        });
      }
    });

    // Generate embedding immediately on main thread.
    // SKILL.md compliant for registration (only 9 frames).
    final emb = await _mlService.generateEmbedding(
      jpegBytes: jpegBytes,
      face: face,
    );

    // Store in correct list
    switch (currentPhase) {
      case _Phase.front:
        _frontFrames.add(jpegBytes);
        if (emb != null) {
          _frontEmbeddings.add(emb);
        } else {
          debugPrint(
            '[FACE_REG] Failed to generate embedding for phase front (frame ${_frontFrames.length})',
          );
        }
        break;
      case _Phase.left:
        _leftFrames.add(jpegBytes);
        if (emb != null) {
          _leftEmbeddings.add(emb);
        } else {
          debugPrint(
            '[FACE_REG] Failed to generate embedding for phase left (frame ${_leftFrames.length})',
          );
        }
        break;
      case _Phase.right:
        _rightFrames.add(jpegBytes);
        if (emb != null) {
          _rightEmbeddings.add(emb);
        } else {
          debugPrint(
            '[FACE_REG] Failed to generate embedding for phase right (frame ${_rightFrames.length})',
          );
        }
        break;
      default:
        break;
    }

    _lastCaptureTime = DateTime.now();

    // Check if phase is complete
    if (currentPhase == _Phase.left && _leftFrames.length >= _framesPerPhase) {
      debugPrint(
        '[FACE_REG] PHASE: left → front (${_leftFrames.length} left frames collected)',
      );
      _updateInstruction(
        'Great job!',
        subtitle: 'Left profile saved',
        animate: false,
      );
      HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 500));
      _setPhase(_Phase.front);
    } else if (currentPhase == _Phase.front &&
        _frontFrames.length >= _framesPerPhase) {
      debugPrint(
        '[FACE_REG] PHASE: front → right (${_frontFrames.length} front frames collected)',
      );
      _updateInstruction(
        'Perfect!',
        subtitle: 'Front profile saved',
        animate: false,
      );
      HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 500));
      _setPhase(_Phase.right);
    } else if (currentPhase == _Phase.right &&
        _rightFrames.length >= _framesPerPhase) {
      debugPrint(
        '[FACE_REG] PHASE: right → processing (${_rightFrames.length} right frames collected)',
      );
      // All phases done — process and upload
      // Stop camera FIRST — no delay, instant black-out on 9/9
      try {
        await _cameraController?.stopImageStream();
      } catch (_) {}

      _updateInstruction(
        'All done!',
        subtitle: 'Preparing face data',
        animate: false,
      );
      HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 500));
      _setPhase(_Phase.processing);

      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) {
          _pulseController.stop();
          _successBounceController.forward(from: 0.0).then((_) {
            _successBounceController.reverse();
          });
        }
      });

      // Delay to let processing UI show up before heavy synchronous math
      await Future.delayed(const Duration(milliseconds: 50));
      await _processAndUpload();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PROCESS + UPLOAD
  // Build both embeddings from captured frames and save to Supabase
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _processAndUpload() async {
    if (!mounted) return;

    // ── Final frame count check ──────────────────────────────────────────
    debugPrint(
      '[FACE_REG] Final Frame Check: Front: ${_frontFrames.length}, '
      'Left: ${_leftFrames.length}, Right: ${_rightFrames.length}',
    );

    if (_frontFrames.length < _framesPerPhase) {
      _setError(
        'Capture incomplete (Front frames missed). Please stay inside the circle.',
      );
      return;
    }
    if (_leftFrames.length < _framesPerPhase) {
      _setError(
        'Capture incomplete (Left side missed). Please stay inside the circle.',
      );
      return;
    }
    if (_rightFrames.length < _framesPerPhase) {
      _setError(
        'Capture incomplete (Right side missed). Please stay inside the circle.',
      );
      return;
    }

    _updateInstruction('Processing…', subtitle: 'Generating your face profile');

    try {
      // FIXED: Embeddings already generated during capture phase on main thread.
      // No more compute() isolate calls — avoids BackgroundIsolateBinaryMessenger crash.
      final List<List<double>> embASource = [
        ..._frontEmbeddings,
        ..._leftEmbeddings,
      ];
      final List<List<double>> embBSource = [
        ..._frontEmbeddings,
        ..._rightEmbeddings,
      ];

      debugPrint(
        '[FACE_REG] Processing embeddings: front=${_frontEmbeddings.length}, left=${_leftEmbeddings.length}, right=${_rightEmbeddings.length}',
      );

      final List<double> embeddingA = _mlService.averageEmbeddings(embASource);
      final List<double> embeddingB = _mlService.averageEmbeddings(embBSource);

      if (embeddingA.isEmpty || embeddingB.isEmpty) {
        _setError('Could not generate face embeddings. Please try again.');
        return;
      }

      _updateInstruction('Almost done!', subtitle: 'Saving your registration');

      // ── Upload registration photo to Supabase Storage
      final String? photoUrl = await _uploadRegistrationPhoto();

      // ── Save to students table in Supabase
      await _saveToSupabase(
        embeddingA: embeddingA,
        embeddingB: embeddingB,
        photoUrl: photoUrl,
      );

      _setPhase(_Phase.done);
      debugPrint(
        '[FACE_REG] Registration COMPLETE ✓ — navigating to success screen',
      );

      // Navigate to registration success screen
      if (mounted) {
        Navigator.of(context).pushReplacementNamed(
          '/face_preview',
          arguments: {
            'photoBytes': _registrationPhotoBytes,
            'faceBbox': _registrationFaceBbox,
          },
        );
      }
    } catch (e) {
      _setError('Registration failed: ${e.toString()}');
    }
  }

  Future<String?> _uploadRegistrationPhoto() async {
    if (_registrationPhotoBytes == null) return null;

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return null;

      final String fileName =
          'registration_${user.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final String filePath = '${user.id}/$fileName';

      await Supabase.instance.client.storage
          .from('face-registrations')
          .uploadBinary(
            filePath,
            _registrationPhotoBytes!,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: true,
            ),
          );

      // Get public URL
      final String publicUrl = Supabase.instance.client.storage
          .from('face-registrations')
          .getPublicUrl(filePath);

      return publicUrl;
    } catch (e) {
      // Photo upload failure is non-fatal — teacher can still see profile
      return null;
    }
  }

  Future<void> _saveToSupabase({
    required List<double> embeddingA,
    required List<double> embeddingB,
    String? photoUrl,
  }) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) throw Exception('User not logged in');

    // Update the students table row for this student
    // The row already exists (created during signup) — we just update embeddings
    await Supabase.instance.client
        .from('students')
        .update({
          'embedding_a': embeddingA, // Supabase stores jsonb natively from List
          'embedding_b': embeddingB,
          'registration_photo': photoUrl,
          'is_approved': false, // Teacher must approve before attendance works
        })
        .eq('id', user.id);

    // Update local auth flow state
    AuthFlowState.instance.faceRegistered = false; // Not approved yet
  }

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

    if (faces.length > 1) {
      debugPrint(
        '[FACE_REG] Biggest face filter: ${faces.length} faces detected, '
        'selected largest (area=${(biggest.boundingBox.width * biggest.boundingBox.height).toStringAsFixed(0)}), '
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
    // FRONT: strict 0.25 — anchor image must be well-centred.
    // LEFT/RIGHT: relaxed 0.45 — side turns naturally shift the bounding box.
    final bool isSideTurn = phase == _Phase.left || phase == _Phase.right;
    final double maxOffset = isSideTurn ? 0.45 : 0.25;

    final double centerX = face.boundingBox.left + face.boundingBox.width / 2;
    final double imageCenterX = image.width / 2;
    final double centerOffset = (centerX - imageCenterX).abs() / image.width;

    if (centerOffset > maxOffset) {
      debugPrint(
        '[FACE_REG] _isFaceAcceptable() returns false (centerOffset: ${centerOffset.toStringAsFixed(3)} > $maxOffset for phase=${phase.name})',
      );
      return false;
    }

    if (isSideTurn && centerOffset > 0.25) {
      // Accepted only because of the relaxed side-turn threshold — log it
      debugPrint(
        '[FACE_REG] Side-turn accepted with relaxed offset: ${centerOffset.toStringAsFixed(3)} (phase=${phase.name})',
      );
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

    // Fix: Negate yaw for front camera (common Xiaomi/POCO inversion)
    // This makes "Turn slightly left" match user's physical left turn
    final double yaw = -yawRaw;

    switch (phase) {
      case _Phase.front:
        return yaw.abs() <= 6; // ±6° — ensures truly straight front capture
      case _Phase.left:
        return yaw >= -28 && yaw <= -8; // Turned left (negative after flip)
      case _Phase.right:
        return yaw >= 8 && yaw <= 28; // Turned right
      default:
        return true;
    }
  }

  String _getPoseInstruction(_Phase phase) {
    switch (phase) {
      case _Phase.front:
        return 'Look straight ahead';
      case _Phase.left:
        return 'Turn slightly left';
      case _Phase.right:
        return 'Turn slightly right';
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
          'Turn Left',
          subtitle: 'Turn your head slowly to the left',
        );
        break;
      case _Phase.front:
        _updateInstruction(
          'Look Straight',
          subtitle: 'Face the camera and hold still',
        );
        break;
      case _Phase.right:
        _updateInstruction(
          'Turn Right',
          subtitle: 'Turn your head slowly to the right',
        );
        break;
      case _Phase.processing:
        _updateInstruction(
          'Face registration completed',
          subtitle: 'Saving your registration securely',
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
                lower.contains('move slightly backward')) {
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

  // FIXED: debugPrint full error for logs, show short user-friendly message in UI
  void _setError(String message) {
    if (!mounted) return;
    debugPrint('[FACE_REG] ERROR: $message');
    setState(() {
      _phase = _Phase.error;
      _errorMessage = message;
      _borderColor = AppStyles.errorRed;
      _instructionTitle = 'Something went wrong';
      _instructionSubtitle = 'Registration failed. Please try again.';
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DISPOSE — must stop stream before disposing controller
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _pulseController.dispose();
    _textFadeController.dispose();
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
                                                          _phase == _Phase.done)
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
                                        end:
                                            _captureProgress /
                                            (_framesPerPhase * 3),
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
                              opacity:
                                  (_phase == _Phase.left ||
                                      _phase == _Phase.front ||
                                      _phase == _Phase.right)
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
                                                  isDone: _challengeVerified,
                                                  pulseController:
                                                      _pulseController,
                                                ),
                                                _NeonChip(
                                                  label: 'Left',
                                                  isActive:
                                                      _phase == _Phase.left,
                                                  isDone:
                                                      _leftEmbeddings.length >=
                                                      _framesPerPhase,
                                                  pulseValue:
                                                      _pulseController.value,
                                                ),
                                                _ShimmerLine(
                                                  isDone:
                                                      _leftEmbeddings.length >=
                                                      _framesPerPhase,
                                                  pulseController:
                                                      _pulseController,
                                                ),
                                                _NeonChip(
                                                  label: 'Front',
                                                  isActive:
                                                      _phase == _Phase.front,
                                                  isDone:
                                                      _frontEmbeddings.length >=
                                                      _framesPerPhase,
                                                  pulseValue:
                                                      _pulseController.value,
                                                ),
                                                _ShimmerLine(
                                                  isDone:
                                                      _frontEmbeddings.length >=
                                                      _framesPerPhase,
                                                  pulseController:
                                                      _pulseController,
                                                ),
                                                _NeonChip(
                                                  label: 'Right',
                                                  isActive:
                                                      _phase == _Phase.right,
                                                  isDone:
                                                      _rightEmbeddings.length >=
                                                      _framesPerPhase,
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
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(16),
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
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical:
                                            _instructionTitle ==
                                                'Move to the center of the circle'
                                            ? 6
                                            : 10,
                                      ),
                                      child: Column(
                                        mainAxisSize:
                                            MainAxisSize.min, // Fix alignment
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

                                          // Retry button on error
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
      return SizedBox(
        width: containerWidth,
        height: containerWidth,
        child: _PulsingCameraLoader(),
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
          child: CameraPreview(_cameraController!),
        ),
      ),
    );
  }

  void _onRetry() {
    // Reset all state and try again
    _livenessService.reset();
    _frontEmbeddings.clear();
    _leftEmbeddings.clear();
    _rightEmbeddings.clear();
    _frontFrames.clear();
    _leftFrames.clear();
    _rightFrames.clear();
    _registrationPhotoBytes = null;
    _registrationFaceBbox = null;
    _captureProgress = 0;
    _progressLabel = '';
    _challengeVerified = false;
    _challengeStartTime = null;
    _blinkCountdownController.reset();
    _steadyStartTime = null;
    _isFaceReady = false;
    _clearSmoothing();

    setState(() {
      _borderColor = AppStyles.primaryBlue;
      _errorMessage = null;
    });

    _setPhase(_Phase.left);
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

    // 3. Directional Guidance (Turn Left / Right)
    if (phase == _Phase.left || phase == _Phase.right) {
      _drawDirectionalFlow(canvas, center, radius, phase);
    }
  }

  void _drawDirectionalFlow(
    Canvas canvas,
    Offset center,
    double radius,
    _Phase phase,
  ) {
    // Flowing energy trail / arrows
    final bool isLeft = phase == _Phase.left;
    final double sign = isLeft ? -1.0 : 1.0;

    final arrowPaint = Paint()
      ..color = AppStyles.primaryBlue.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    final arrowGlow = Paint()
      ..color = AppStyles.primaryBlue.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);

    // Base position for arrows (side of the circle)
    final double arrowRadius = radius * 0.75;
    final Offset arrowCenter = center + Offset(sign * arrowRadius, 0);

    // Draw 3 chevrons
    for (int i = 0; i < 3; i++) {
      final double xOffset = sign * (i * 12.0);
      final double phaseShift = i * 0.33;
      double opacity = math.sin((flowValue * math.pi) + phaseShift).abs();

      arrowPaint.color = AppStyles.primaryBlue.withValues(alpha: 0.8 * opacity);
      arrowGlow.color = AppStyles.primaryBlue.withValues(alpha: 0.5 * opacity);

      final Path path = Path();
      final double pX = arrowCenter.dx + xOffset;
      final double pY = arrowCenter.dy;
      const double size = 8.0;

      path.moveTo(pX - sign * size, pY - size);
      path.lineTo(pX, pY);
      path.lineTo(pX - sign * size, pY + size);

      canvas.drawPath(path, arrowGlow);
      canvas.drawPath(path, arrowPaint);
    }
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
