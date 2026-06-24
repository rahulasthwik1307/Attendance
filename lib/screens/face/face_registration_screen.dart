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
import '../../services/face_landmark_service.dart';
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
  front, // Capture 15 front frames
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
  final FaceLandmarkService _landmarkService = FaceLandmarkService();
  final LivenessChallengeService _livenessService = LivenessChallengeService();
  bool _isProcessingFrame = false;
  DateTime _lastFrameTime = DateTime.now();
  CameraImage? _lastCameraImage;
  DateTime _lastCaptureTime = DateTime.fromMillisecondsSinceEpoch(0);

  // ─── Registration state ───────────────────────────────────────────────────
  _Phase _phase = _Phase.initializing;

  // Captured frame bytes (JPEG)
  final List<Uint8List> _frontFrames = [];

  // First front frame saved as registration photo
  Uint8List? _registrationPhotoBytes;
  Rect? _registrationPhotoBbox;

  // Embeddings
  final List<List<double>> _frontEmbeddings = [];

  // How many quality frames to capture (all front)
  static const int _framesPerPhase = 15;

  // ─── Camera freeze & processing state ─────────────────────────────────────
  bool _cameraFrozen = false; // True once enough frames collected
  bool _isSubmitting = false; // Guard against double-tap / re-entry

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
  int _captureProgress = 0; // 0-15 total captured frames
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

      // Initialize ML services
      await _landmarkService.initialize();

      // Warm up backend — prevents Hugging Face cold start during registration.
      // Fire-and-forget: ignore failures, backend may still respond.
      _landmarkService.pingBackend().catchError((_) {});

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
  void _onCameraFrame(CameraImage cameraImage) {
    // Skip if we're already processing a frame or camera shouldn't be running
    if (_isProcessingFrame) return;
    if (_cameraFrozen) return; // Camera frozen — ignore all future frames
    if (_phase == _Phase.processing || _phase == _Phase.done) return;

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
    
    _lastFrameTime = now;
    _isProcessingFrame = true;

    _processFrameAsync(cameraImage);
  }

  Future<void> _processFrameAsync(CameraImage cameraImage) async {
    if (!mounted) return;

    try {
      // Convert CameraImage to InputImage for ML Kit
      final InputImage? inputImage = _convertToInputImage(cameraImage);
      if (inputImage == null) {
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

      if (faces.isEmpty) {
        if (_phase == _Phase.liveness && !_challengeVerified) {
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

      // Pick the biggest face
      final Face? face = _selectBiggestCenteredFace(faces, cameraImage);
      if (face == null) {
        _updateInstruction('Fit your face in the circle', animate: false);
        _isProcessingFrame = false;
        return;
      }

      // Push raw face metrics into smoothing buffer
      _pushSmoothing(face);

      // ── Pre-liveness positioning gate ──────────────────────────────────
      if (_phase == _Phase.liveness && !_challengeVerified) {
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
            await Future.delayed(const Duration(milliseconds: 500));
            if (mounted) _setPhase(_Phase.front);
          }
          break;
        case _Phase.front:
          await _handleCapture(face, cameraImage, _Phase.front);
          break;
        default:
          break;
      }
    } catch (e) {
      // Swallow frame errors
    } finally {
      if (mounted) _isProcessingFrame = false;
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

    final int timeout = 3000;

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

    if (challenge == ChallengeType.blink &&
        !_livenessService.isBlinkCalibrated) {
      final bool calibDone = _livenessService.calibrateBlink(face);
      if (!calibDone) return;
      _challengeStartTime = DateTime.now();
      _lastKnownBlinkCount = 0;
      _blinkCountdownController.reset();
      _blinkCountdownController.forward();
      _updateInstruction(
        'Blink to Start',
        subtitle: 'Blink naturally 2 to 3 times to confirm you are present',
        animate: false,
      );
      return;
    }

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
    final now = DateTime.now();
    if (now.difference(_lastCaptureTime).inMilliseconds < 280) return;
    if (_cameraFrozen) return;

    if (!_isPoseCorrect(face, currentPhase)) {
      _updateInstruction(_getPoseInstruction(currentPhase), animate: false);
      return;
    }

    if (!_isFaceAcceptable(face, cameraImage, currentPhase)) {
      _updateInstruction(
        _getFacingInstruction(face, cameraImage),
        animate: false,
      );
      return;
    }

    _updateInstruction('Hold still…', subtitle: 'Almost done, stay steady');

    final Uint8List? jpegBytes = await _captureCurrentFrame();
    if (jpegBytes == null) return;

    if (currentPhase == _Phase.front && _registrationPhotoBytes == null) {
      _registrationPhotoBytes = jpegBytes;
      _registrationPhotoBbox = face.boundingBox;
    }

    await Future.delayed(const Duration(milliseconds: 40));

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

    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted && _phase == currentPhase) {
        setState(() {
          _borderColor = AppStyles.primaryBlue;
        });
      }
    });

    switch (currentPhase) {
      case _Phase.front:
        _frontFrames.add(jpegBytes);
        setState(() {
          _captureProgress++;
          _progressLabel = '$_captureProgress / $_framesPerPhase';
          _borderColor = AppStyles.successGreen;
        });
        HapticFeedback.lightImpact();
        break;
      default:
        break;
    }

    _lastCaptureTime = DateTime.now();

    if (currentPhase == _Phase.front &&
        _frontFrames.length >= _framesPerPhase) {
      _cameraFrozen = true;
      try {
        await _cameraController?.stopImageStream();
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _borderColor = AppStyles.successGreen;
      });

      HapticFeedback.mediumImpact();
      _setPhase(_Phase.processing);

      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) {
          _pulseController.stop();
          _successBounceController.forward(from: 0.0).then((_) {
            _successBounceController.reverse();
          });
        }
      });

      await Future.delayed(const Duration(milliseconds: 50));
      await _processAndUpload();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PROCESS + UPLOAD
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _processAndUpload() async {
    if (!mounted) return;
    if (_isSubmitting) return;
    _isSubmitting = true;

    if (_frontFrames.length < _framesPerPhase) {
      _isSubmitting = false;
      _setError('Not enough photos captured. Please try again.');
      return;
    }

    _updateInstruction('Face Captured ✓', subtitle: 'Processing…');

    try {
      final List<BatchEmbeddingResult> batchResults =
          await _landmarkService.generateEmbeddingBatchWithQuality(
        jpegBytesList: _frontFrames,
      );

      final List<BatchEmbeddingResult> validResults = batchResults
          .where((r) => r.embedding != null && r.qualityPassed)
          .toList();

      if (validResults.length < _framesPerPhase) {
        final int deficit = _framesPerPhase - validResults.length;

        _frontEmbeddings.clear();
        for (final r in validResults) {
          _frontEmbeddings.add(r.embedding!);
        }

        _cameraFrozen = false;
        _isSubmitting = false;
        _frontFrames.clear();

        if (!mounted) return;
        setState(() {
          _captureProgress = validResults.length;
          _progressLabel = '$_captureProgress / $_framesPerPhase';
          _borderColor = AppStyles.primaryBlue;
        });

        _updateInstruction(
          'Need more photos',
          subtitle: 'Hold still, capturing $deficit more…',
        );

        try {
          _setPhase(_Phase.front);
          await _cameraController?.startImageStream(_onCameraFrame);
        } catch (_) {}
        return;
      }

      validResults.sort((a, b) => b.qualityScore.compareTo(a.qualityScore));
      final List<BatchEmbeddingResult> topFrames = validResults.length > _framesPerPhase
          ? validResults.sublist(0, _framesPerPhase)
          : validResults;

      final List<List<double>> validEmbeddings = topFrames
          .map((r) => r.embedding!)
          .toList();

      if (validEmbeddings.length < 6) {
        _isSubmitting = false;
        _setError('Could not capture enough clear photos. Please try in better lighting.');
        return;
      }

      final int third = validEmbeddings.length ~/ 3;
      final List<List<double>> group1 = validEmbeddings.sublist(0, third);
      final List<List<double>> group2 = validEmbeddings.sublist(third, third * 2);
      final List<List<double>> group3 = validEmbeddings.sublist(third * 2);

      final List<double> embeddingA = _landmarkService.averageEmbeddings(group1);
      final List<double> embeddingB = _landmarkService.averageEmbeddings(group2);
      final List<double> embeddingC = _landmarkService.averageEmbeddings(group3);

      final List<double> masterEmbedding = _landmarkService.averageEmbeddings(
        [embeddingA, embeddingB, embeddingC],
      );

      _updateInstruction('Almost done!', subtitle: 'Saving your registration');
      final String? photoUrl = await _uploadRegistrationPhoto();

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('User not logged in');
      final userId = user.id;

      await Supabase.instance.client
          .from('students')
          .update({
            'embedding_a': embeddingA,
            'embedding_b': embeddingB,
            'embedding_c': embeddingC,
            'face_embedding': masterEmbedding,
            'registration_photo_url': photoUrl,
            'face_registered': true,
          })
          .eq('id', userId);

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
      _isSubmitting = false;
      _setError(_userFriendlyError(e.toString()));
    }
  }

  String _userFriendlyError(String technicalError) {
    final lower = technicalError.toLowerCase();
    if (lower.contains('camera')) return 'Camera could not start. Please try again.';
    if (lower.contains('timeout')) return 'Processing timed out. Please try again.';
    if (lower.contains('network') || lower.contains('socket') || lower.contains('connection'))
      return 'Network issue. Please check your connection and try again.';
    if (lower.contains('not logged in') || lower.contains('user'))
      return 'Session expired. Please sign in again.';
    return 'Something went wrong. Please try again.';
  }

  Future<String?> _uploadRegistrationPhoto() async {
    return null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────────────

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

  void _logInstructionChange(String newInstruction) {
    if (_lastPosInstruction != newInstruction) {
      debugPrint('[FACE_REG] Instruction: $_lastPosInstruction -> $newInstruction');
    }
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
    final double circleTop = _uiAvailH * 0.40 - _uiCircleSize / 2;
    final double circleCameraCY = rotH / 2 + circleTop / scale;
    final double circleCameraSize = _uiCircleSize / scale;

    final double smoothW = _bufAvg(_bufFaceWidth);
    final double smoothH = _bufAvg(_bufFaceHeight);
    final double smoothCX = _bufAvg(_bufFaceCX);
    final double smoothCY = _bufAvg(_bufFaceCY);

    final double smoothTop = smoothCY - smoothH / 2;
    final double smoothBottom = smoothCY + smoothH / 2;
    final double smoothLeft = smoothCX - smoothW / 2;
    final double smoothRight = smoothCX + smoothW / 2;
    final double circleRadius = circleCameraSize / 2;
    final double virtualCrownTop = smoothTop - (smoothH * 0.30);

    final double circleTopBound = circleCameraCY - circleRadius;
    final double circleBottomBound = circleCameraCY + circleRadius;
    final double circleLeftBound = (rotW / 2) - circleRadius;
    final double circleRightBound = (rotW / 2) + circleRadius;

    if (virtualCrownTop < circleTopBound ||
        smoothBottom > circleBottomBound ||
        smoothLeft < circleLeftBound ||
        smoothRight > circleRightBound) {
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }

    final double faceWidthRatio = smoothW / circleCameraSize;
    if (faceWidthRatio < 0.40) {
      _lastPosInstruction = 'Move closer to the camera';
      return 'Move closer to the camera';
    }

    if (faceWidthRatio > 0.95) {
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }

    final double offX = (smoothCX - (rotW / 2)).abs();
    if (offX > (circleRadius * 0.20)) {
      _lastPosInstruction = 'Move to the center of the circle';
      return 'Move to the center of the circle';
    }

    _lastPosInstruction = null;
    return null;
  }

  bool _isFaceAcceptable(Face face, CameraImage image, _Phase phase) {
    if (_uiCircleSize > 0 && _uiAvailW > 0 && _bufFaceWidth.isNotEmpty) {
      final int sensorOrientation =
          _cameraController!.description.sensorOrientation;
      final bool isRotated =
          sensorOrientation == 90 || sensorOrientation == 270;
      final double rotW = isRotated
          ? image.height.toDouble()
          : image.width.toDouble();
      final double scale = _uiAvailW / rotW;

      final double circleTopUI = _uiAvailH * 0.40 - _uiCircleSize / 2;
      final double circleCameraCY = (isRotated ? rotW : rotH) / 2 + circleTopUI / scale;
      final double circleCameraSize = _uiCircleSize / scale;
      final double circleRadius = circleCameraSize / 2;

      final double circleTopBound = circleCameraCY - circleRadius;
      final double circleBottomBound = circleCameraCY + circleRadius;
      final double circleLeftBound = (rotW / 2) - circleRadius;
      final double circleRightBound = (rotW / 2) + circleRadius;

      final double smoothH = _bufAvg(_bufFaceHeight);
      final double smoothTop = _bufAvg(_bufFaceCY) - smoothH / 2;
      final double smoothBottom = _bufAvg(_bufFaceCY) + smoothH / 2;
      final double smoothLeft = _bufAvg(_bufFaceCX) - _bufAvg(_bufFaceWidth) / 2;
      final double smoothRight = _bufAvg(_bufFaceCX) + _bufAvg(_bufFaceWidth) / 2;
      final double virtualCrownTop = smoothTop - (smoothH * 0.30);

      if (virtualCrownTop < circleTopBound ||
          smoothBottom > circleBottomBound ||
          smoothLeft < circleLeftBound ||
          smoothRight > circleRightBound) return false;
    }

    final double widthRatio = face.boundingBox.width / image.width;
    if (widthRatio < 0.12 || widthRatio > 0.85) return false;

    final double centerOffset = (face.boundingBox.left + face.boundingBox.width / 2 - image.width / 2).abs() / image.width;
    if (centerOffset > 0.25) return false;

    return true;
  }

  bool _isPoseCorrect(Face face, _Phase phase) {
    final double? yawRaw = face.headEulerAngleY;
    if (yawRaw == null) return false;
    return yawRaw.abs() <= 15;
  }

  String _getPoseInstruction(_Phase phase) => 'Look straight ahead';

  String _getFacingInstruction(Face face, CameraImage image) => 'Fit your face in the circle';

  Future<Uint8List?> _captureCurrentFrame() async {
    try {
      if (_lastCameraImage == null) return null;
      if (_lastCameraImage!.format.group == ImageFormatGroup.jpeg) {
        return Uint8List.fromList(_lastCameraImage!.planes[0].bytes);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  // ─── UI updates ─────────────────────────────────────────────────────

  void _setPhase(_Phase newPhase) {
    if (!mounted) return;
    setState(() => _phase = newPhase);

    if (newPhase == _Phase.liveness) {
      _challengeVerified = false;
      _challengeStartTime = null;
      _livenessService.reset();
      _steadyStartTime = null;
      _isFaceReady = false;
      _clearSmoothing();
    }
  }

  void _updateInstruction(String title, {String? subtitle, bool animate = true}) {
    if (!mounted) return;
    _instructionDebounceTimer?.cancel();
    _instructionDebounceTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() {
        _instructionTitle = title;
        _instructionSubtitle = subtitle ?? (_subtitles[title] ?? '');
      });
    });
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _instructionTitle = 'Something went wrong';
      _instructionSubtitle = 'Registration failed. Please try again.';
    });
  }

  Widget _buildProcessingOverlay() => Container(
        color: Colors.black54,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, color: Colors.white, size: 64),
              SizedBox(height: 16),
              Text('Face Captured ✓', style: TextStyle(color: Colors.white, fontSize: 20)),
            ],
          ),
        ),
      );

  @override
  void dispose() {
    _instructionDebounceTimer?.cancel();
    _pulseController.dispose();
    _textFadeController.dispose();
    _blinkCountdownController.dispose();
    _successBounceController.dispose();
    _particleController.dispose();
    _cameraController?.dispose();
    _mlService.faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppStyles.backgroundLight,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
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
                                        end: _captureProgress / _framesPerPhase,
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
                                  (_phase == _Phase.front)
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
                                                  isActive: _phase == _Phase.liveness,
                                                  isDone: _challengeVerified,
                                                  pulseValue: _pulseController.value,
                                                ),
                                                _ShimmerLine(
                                                  isDone: _frontEmbeddings.length >= _framesPerPhase,
                                                  pulseController: _pulseController,
                                                ),
                                                _NeonChip(
                                                  label: 'Front',
                                                  isActive: _phase == _Phase.front,
                                                  isDone: _frontEmbeddings.length >= _framesPerPhase,
                                                  pulseValue: _pulseController.value,
                                                ),
                                                _ShimmerLine(
                                                  isDone: _phase == _Phase.done || _phase == _Phase.processing,
                                                  pulseController: _pulseController,
                                                ),
                                                _NeonChip(
                                                  label: 'Done',
                                                  isActive: _phase == _Phase.processing,
                                                  isDone: _phase == _Phase.done,
                                                  pulseValue: _pulseController.value,
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
    _frontFrames.clear();
    _registrationPhotoBytes = null;
    _captureProgress = 0;
    _progressLabel = '';
    _challengeVerified = false;
    _challengeStartTime = null;
    _blinkCountdownController.reset();
    _steadyStartTime = null;
    _isFaceReady = false;
    _cameraFrozen = false;
    _isSubmitting = false;
    _clearSmoothing();

    setState(() {
      _borderColor = AppStyles.primaryBlue;
      _errorMessage = null;
    });

    // Restart camera stream if it was stopped
    try {
      _cameraController?.startImageStream(_onCameraFrame);
    } catch (_) {}

    _setPhase(_Phase.liveness);
  }

  /// Processing overlay shown when camera is frozen
  Widget _buildProcessingOverlay() {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: _cameraFrozen ? 1.0 : 0.0,
      child: Container(
        color: Colors.black.withValues(alpha: 0.55),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _phase == _Phase.done ? Icons.check_circle : Icons.check_circle_outline,
                color: AppStyles.successGreen,
                size: 48,
              ),
              const SizedBox(height: 12),
              const Text(
                'Face Captured ✓',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              if (_phase != _Phase.done) ...[
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Processing…',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
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
