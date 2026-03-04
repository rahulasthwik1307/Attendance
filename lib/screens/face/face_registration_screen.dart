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
  front, // Blink verification → capture 3 front frames
  left, // Head turn left verification → capture 3 left frames
  right, // Head turn right verification → capture 3 right frames
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
  late AnimationController _scanLineController;
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

  // Progress: which step out of total (for display)
  int _captureProgress = 0; // 0-9 total frames
  String _progressLabel = '';

  // ignore: unused_field
  String? _errorMessage;

  // ─── Face positioning state ────────────────────────────────────────────
  DateTime? _steadyStartTime;
  bool _isFaceReady = false;

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
      duration: const Duration(milliseconds: 500),
    )..forward();

    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _blinkCountdownController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
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

      _setPhase(_Phase.front);
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

    // Rate limit: process max 10 frames per second
    final now = DateTime.now();
    final int limit = (_phase == _Phase.front && !_challengeVerified)
        ? 33
        : 100; // Higher FPS during blink detection
    if (now.difference(_lastFrameTime).inMilliseconds < limit) return;
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
        // Only show "Fit your face" during challenge verification sub-phase.
        if (!_challengeVerified) {
          // Reset positioning steady state and smoothing buffer on face loss
          _clearSmoothing();
          _steadyStartTime = null;
          if (_isFaceReady) {
            _isFaceReady = false;
            _livenessService.reset();
            _challengeStartTime = null;
            if (_phase == _Phase.front) {
              _blinkCountdownController.stop();
              _blinkCountdownController.reset();
            }
            debugPrint(
              '[FACE_REG] Face lost — resetting positioning & challenge',
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

      // Debug: smoothed face metrics (5-frame average, reduces noise)
      debugPrint(
        '[FACE_REG] Face detected | '
        'avgW: ${_bufAvg(_bufFaceWidth).toStringAsFixed(1)} '
        'avgCX: ${_bufAvg(_bufFaceCX).toStringAsFixed(1)} '
        'avgCY: ${_bufAvg(_bufFaceCY).toStringAsFixed(1)} '
        'rawYaw: ${face.headEulerAngleY?.toStringAsFixed(1)} '
        'rawPitch: ${face.headEulerAngleX?.toStringAsFixed(1)}',
      );

      // ── Pre-liveness positioning gate ──────────────────────────────────
      // Centering + distance + steadiness must pass before liveness starts.
      // During liveness (isFaceReady && !challengeVerified), use relaxed check;
      // if user moves out, reset that liveness phase.
      if (!_challengeVerified) {
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
            _livenessService.reset();
            _challengeStartTime = null;
            if (_phase == _Phase.front) {
              _blinkCountdownController.stop();
              _blinkCountdownController.reset();
            }
            debugPrint(
              '[FACE_REG] Face lost position during liveness — resetting challenge',
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
          if (steadyMs < 500) {
            _updateInstruction(
              'Hold still…',
              subtitle: 'Almost ready, stay steady',
              animate: false,
            );
            _isProcessingFrame = false;
            return;
          }
          // Steady for 500ms — mark ready and kick off liveness challenge
          _isFaceReady = true;
          _challengeStartTime = DateTime.now();
          _livenessService.reset();
          debugPrint(
            '[FACE_REG] Face positioned & steady 500ms — starting liveness',
          );

          if (_phase == _Phase.front) {
            _blinkCountdownController.reset();
            _blinkCountdownController.forward();
          }
          // Show appropriate challenge instruction
          _updateInstruction(
            _getChallengeInstruction(_phaseToChallengeType(_phase)),
            subtitle: _getChallengeSubtitle(_phaseToChallengeType(_phase)),
            animate: false,
          );
        }
      }

      // Route to correct phase handler
      switch (_phase) {
        case _Phase.front:
          if (!_challengeVerified) {
            await _handleLivenessChallenge(face, ChallengeType.blink);
          } else {
            await _handleCapture(face, cameraImage, _Phase.front);
          }
          break;
        case _Phase.left:
          if (!_challengeVerified) {
            await _handleLivenessChallenge(face, ChallengeType.turnLeft);
          } else {
            await _handleCapture(face, cameraImage, _Phase.left);
          }
          break;
        case _Phase.right:
          if (!_challengeVerified) {
            await _handleLivenessChallenge(face, ChallengeType.turnRight);
          } else {
            await _handleCapture(face, cameraImage, _Phase.right);
          }
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

    // Timeout: 8s for blink, 10s for head turns
    final int timeout = challenge == ChallengeType.blink ? 8000 : 10000;

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
        challenge == ChallengeType.blink
            ? 'No blink detected'
            : 'Turn not detected',
        subtitle: challenge == ChallengeType.blink
            ? 'Please blink naturally once (relaxed eyes). Retrying…'
            : 'Please turn your head slowly. Retrying…',
        animate: false,
      );

      // Brief pause so user sees the retry message
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      // Restart challenge countdown
      if (challenge == ChallengeType.blink) {
        _blinkCountdownController.reset();
        _blinkCountdownController.forward();
      }
      _updateInstruction(
        _getChallengeInstruction(challenge),
        subtitle: _getChallengeSubtitle(challenge),
        animate: false,
      );
      return;
    }

    // ── Try to detect the challenge ──────────────────────────────────────
    bool detected = false;
    switch (challenge) {
      case ChallengeType.blink:
        detected = _livenessService.detectBlink(face);
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
      debugPrint('[FACE_REG] Challenge ${challenge.name} VERIFIED ✓');
      _challengeVerified = true;
      _livenessService.reset();
      _challengeStartTime = null;

      if (challenge == ChallengeType.blink) {
        _blinkCountdownController.stop();
      }

      // Visual confirmation flash
      if (mounted) {
        setState(() {
          _borderColor = AppStyles.successGreen;
        });
      }
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) {
        setState(() {
          _borderColor = AppStyles.primaryBlue;
        });
        _updateInstruction(
          _getPoseInstruction(_phase),
          subtitle: 'Hold still for capture',
          animate: false,
        );
      }
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

  String _getChallengeSubtitle(ChallengeType challenge) {
    switch (challenge) {
      case ChallengeType.blink:
        return 'Blink naturally to confirm your presence';
      case ChallengeType.turnLeft:
        return 'Turn your head to the left slowly';
      case ChallengeType.turnRight:
        return 'Turn your head to the right slowly';
      default:
        return 'Stay steady';
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

    // Quality + centering check
    if (!_isFaceAcceptable(face, cameraImage)) {
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
    }

    // FIXED: Generate embedding immediately on main thread to avoid isolate
    // plugin crash. SKILL.md compliant for registration (only 9 frames,
    // each inference ~15-25ms on CPU with 2 threads).
    final emb = await _mlService.generateEmbedding(
      jpegBytes: jpegBytes,
      face: face,
    );

    // Store in correct list
    switch (currentPhase) {
      case _Phase.front:
        _frontFrames.add(jpegBytes);
        if (emb != null) _frontEmbeddings.add(emb);
        break;
      case _Phase.left:
        _leftFrames.add(jpegBytes);
        if (emb != null) _leftEmbeddings.add(emb);
        break;
      case _Phase.right:
        _rightFrames.add(jpegBytes);
        if (emb != null) _rightEmbeddings.add(emb);
        break;
      default:
        break;
    }

    _lastCaptureTime = DateTime.now();

    // Update progress
    setState(() {
      _captureProgress++;
      _progressLabel = '$_captureProgress / ${_framesPerPhase * 3}';
    });

    // Brief visual flash to confirm capture
    setState(() {
      _borderColor = AppStyles.successGreen;
    });
    await Future.delayed(const Duration(milliseconds: 150));
    if (mounted) {
      setState(() {
        _borderColor = AppStyles.primaryBlue;
      });
    }

    // Check if phase is complete
    if (currentPhase == _Phase.front &&
        _frontFrames.length >= _framesPerPhase) {
      debugPrint(
        '[FACE_REG] PHASE: front → left (${_frontFrames.length} front frames collected)',
      );
      await Future.delayed(const Duration(milliseconds: 300));
      _setPhase(_Phase.left);
    } else if (currentPhase == _Phase.left &&
        _leftFrames.length >= _framesPerPhase) {
      debugPrint(
        '[FACE_REG] PHASE: left → right (${_leftFrames.length} left frames collected)',
      );
      await Future.delayed(const Duration(milliseconds: 300));
      _setPhase(_Phase.right);
    } else if (currentPhase == _Phase.right &&
        _rightFrames.length >= _framesPerPhase) {
      debugPrint(
        '[FACE_REG] PHASE: right → processing (${_rightFrames.length} right frames collected)',
      );
      // All phases done — process and upload
      await Future.delayed(const Duration(milliseconds: 300));
      _setPhase(_Phase.processing);
      await _processAndUpload();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PROCESS + UPLOAD
  // Build both embeddings from captured frames and save to Supabase
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _processAndUpload() async {
    if (!mounted) return;

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
        Navigator.of(context).pushReplacementNamed('/registration_success');
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

  /// Map a [_Phase] to its corresponding [ChallengeType].
  ChallengeType _phaseToChallengeType(_Phase phase) {
    switch (phase) {
      case _Phase.front:
        return ChallengeType.blink;
      case _Phase.left:
        return ChallengeType.turnLeft;
      case _Phase.right:
        return ChallengeType.turnRight;
      default:
        return ChallengeType.blink;
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

    // ── 1. Distance check with hysteresis ───────────────────────────────
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

    // Smoothed bounding-box edges for border-touch detection
    final double smoothLeft = smoothCX - smoothW / 2;
    final double smoothRight = smoothCX + smoothW / 2;
    final double smoothTop = smoothCY - smoothH / 2;
    final double smoothBottom = smoothCY + smoothH / 2;

    final double circleRadius = circleCameraSize / 2;

    // True circular containment — check all 4 bounding-box corners
    final corners = [
      Offset(smoothLeft, smoothTop),
      Offset(smoothRight, smoothTop),
      Offset(smoothLeft, smoothBottom),
      Offset(smoothRight, smoothBottom),
    ];

    bool cornerOutsideCircle = false;
    for (final corner in corners) {
      final dx = corner.dx - circleCameraCX;
      final dy = corner.dy - circleCameraCY;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance > circleRadius * 0.98) {
        cornerOutsideCircle = true;
        break;
      }
    }

    // Enter "backward": ratio > threshold or any corner outside the circle
    // Stay "backward" until ratio <= 0.75
    final double backwardEnter = (_lastPosInstruction == null) ? 0.85 : 0.80;
    if (faceWidthRatio > backwardEnter ||
        cornerOutsideCircle ||
        (wasTooClose && faceWidthRatio > 0.75)) {
      _logInstructionChange('Move slightly backward');
      _lastPosInstruction = 'Move slightly backward';
      return 'Move slightly backward';
    }

    // ── 2. Centering check — 25% grace zone with hysteresis ─────────────
    final double graceZone = (strict ? 0.25 : 0.40) * circleCameraSize;
    // Exit threshold 20% tighter than entry → prevents flicker at boundary
    final double exitGrace = graceZone * 0.80;

    // Horizontal (front camera is mirrored)
    final double offX = smoothCX - circleCameraCX;
    if (offX > graceZone ||
        (_lastPosInstruction == 'Move slightly Right' && offX > exitGrace)) {
      _logInstructionChange('Move slightly Right');
      _lastPosInstruction = 'Move slightly Right';
      return 'Move slightly Right';
    }
    if (offX < -graceZone ||
        (_lastPosInstruction == 'Move slightly Left' && offX < -exitGrace)) {
      _logInstructionChange('Move slightly Left');
      _lastPosInstruction = 'Move slightly Left';
      return 'Move slightly Left';
    }

    // Vertical (not mirrored)
    final double offY = smoothCY - circleCameraCY;
    if (offY < -graceZone ||
        (_lastPosInstruction == 'Move slightly Down' && offY < -exitGrace)) {
      _logInstructionChange('Move slightly Down');
      _lastPosInstruction = 'Move slightly Down';
      return 'Move slightly Down';
    }
    if (offY > graceZone ||
        (_lastPosInstruction == 'Move slightly Up' && offY > exitGrace)) {
      _logInstructionChange('Move slightly Up');
      _lastPosInstruction = 'Move slightly Up';
      return 'Move slightly Up';
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
      '| OffX: ${offX.toStringAsFixed(1)} | OffY: ${offY.toStringAsFixed(1)} '
      '| StableTime: ${stableMs}ms',
    );

    return null; // Face is well-positioned
  }

  // Check face is acceptably centered and sized
  bool _isFaceAcceptable(Face face, CameraImage image) {
    final double widthRatio = face.boundingBox.width / image.width;

    // Debug: log widthRatio so we can see what the device actually reports
    debugPrint("WidthRatio: $widthRatio");

    // Relaxed thresholds — bounding box scale varies across devices
    if (widthRatio < 0.12 || widthRatio > 0.85) {
      debugPrint(
        "[FACE_REG] _isFaceAcceptable() returns false (widthRatio: ${widthRatio.toStringAsFixed(3)} outside 0.12-0.85)",
      );
      return false;
    }

    // Horizontal centering check — 25% offset tolerance from center
    final double centerX = face.boundingBox.left + face.boundingBox.width / 2;
    final double imageCenterX = image.width / 2;
    final double centerOffset = (centerX - imageCenterX).abs() / image.width;

    if (centerOffset > 0.25) {
      debugPrint(
        "[FACE_REG] _isFaceAcceptable() returns false (centerOffset: ${centerOffset.toStringAsFixed(3)} > 0.25)",
      );
      return false;
    }

    // Head pitch check — allow ±25 degrees tolerance
    final double? pitch = face.headEulerAngleX;
    if (pitch != null && pitch.abs() > 25) {
      debugPrint(
        "[FACE_REG] _isFaceAcceptable() returns false (pitch: ${pitch.toStringAsFixed(1)} > 25)",
      );
      return false;
    }

    debugPrint("[FACE_REG] _isFaceAcceptable() returns true");
    return true;
  }

  // Check head yaw for current capture phase
  bool _isPoseCorrect(Face face, _Phase phase) {
    final double? yawRaw = face.headEulerAngleY;
    if (yawRaw == null) return false;

    // Fix: Negate yaw for front camera (common Xiaomi/POCO inversion)
    // This makes "Turn slightly left" match user's physical left turn
    final double yaw = -yawRaw;

    debugPrint(
      '[FACE_REG] Pose yaw check | raw=${yawRaw.toStringAsFixed(1)} → corrected=${yaw.toStringAsFixed(1)} phase=${phase.name}',
    );

    switch (phase) {
      case _Phase.front:
        return yaw.abs() <= 12; // ±12°
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
    if (coverageRatio > 0.60) return 'Move back';

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

  void _setPhase(_Phase phase) {
    if (!mounted) return;

    setState(() {
      _phase = phase;
    });

    // Reset challenge verification and positioning state for each new phase
    _challengeVerified = false;
    _challengeStartTime = null;
    _livenessService.reset();
    _steadyStartTime = null;
    _isFaceReady = false;
    _clearSmoothing();

    // Update instruction text for new phase — start with centering prompt
    // (liveness instruction will be shown once face is positioned & steady)
    switch (phase) {
      case _Phase.front:
        _blinkCountdownController.reset();
        // Don't auto-start countdown — positioning gate will start it
        _updateInstruction(
          'Fit your face in the circle',
          subtitle: 'Centre your face and hold steady',
        );
        break;
      case _Phase.left:
        _updateInstruction(
          'Fit your face in the circle',
          subtitle: 'Centre your face before turning left',
        );
        break;
      case _Phase.right:
        _updateInstruction(
          'Fit your face in the circle',
          subtitle: 'Centre your face before turning right',
        );
        break;
      case _Phase.processing:
        _updateInstruction(
          'Processing…',
          subtitle: 'Generating your face profile',
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

    // Don't re-animate if instruction hasn't changed — prevents flickering
    // when _handleBlinkPrompt / _handleCalibration call this every frame
    if (_instructionTitle == title) return;

    if (animate) {
      _textFadeController.reverse().then((_) {
        if (!mounted) return;
        setState(() {
          _instructionTitle = title;
          _instructionSubtitle = subtitle ?? (_subtitles[title] ?? '');
        });
        _textFadeController.forward();
      });
    } else {
      setState(() {
        _instructionTitle = title;
        _instructionSubtitle = subtitle ?? (_subtitles[title] ?? '');
      });
    }
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
    _scanLineController.dispose();
    _blinkCountdownController.dispose();

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
                              padding: const EdgeInsets.only(top: 2),
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
                flex: 5,
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

                    return SizedBox(
                      width: availW,
                      height: availH,
                      child: Stack(
                        children: [
                          // Background — solid color, no camera here
                          Positioned.fill(
                            child: Container(color: AppStyles.backgroundLight),
                          ),

                          // Circle clip for the preview
                          Positioned(
                            left: (availW - circleSize) / 2,
                            top: circleTop,
                            child: ClipOval(
                              child: SizedBox(
                                width: circleSize,
                                height: circleSize,
                                child: OverflowBox(
                                  maxWidth: availW,
                                  maxHeight: availH,
                                  child: Transform.translate(
                                    offset: Offset(0, -circleTop),
                                    child: _buildCameraPreview(availW),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Pulsing circle border
                          Positioned(
                            left: (availW - circleSize) / 2,
                            top: circleTop,
                            child: AnimatedBuilder(
                              animation: _pulseController,
                              builder: (context, child) {
                                return Container(
                                  width: circleSize,
                                  height: circleSize,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _borderColor,
                                      width: 2.5,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: _borderColor.withAlpha(
                                          (_pulseController.value * 255 * 0.5)
                                              .toInt(),
                                        ),
                                        blurRadius:
                                            8 + (_pulseController.value * 12),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),

                          // Scan line
                          Positioned(
                            left: (availW - circleSize) / 2,
                            top: circleTop,
                            child: AnimatedBuilder(
                              animation: _scanLineController,
                              builder: (context, child) {
                                return CustomPaint(
                                  size: Size(circleSize, circleSize),
                                  painter: _ScanLinePainter(
                                    scanValue: _scanLineController.value,
                                    circleSize: circleSize,
                                  ),
                                );
                              },
                            ),
                          ),

                          // Blink countdown indicator
                          if (_phase == _Phase.front && !_challengeVerified)
                            Positioned(
                              left: (availW - 44) / 2,
                              top: circleTop + circleSize + 12,
                              child: AnimatedBuilder(
                                animation: _blinkCountdownController,
                                builder: (context, child) {
                                  final double remaining =
                                      8.0 *
                                      (1.0 - _blinkCountdownController.value);
                                  return SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        CircularProgressIndicator(
                                          value:
                                              1.0 -
                                              _blinkCountdownController.value,
                                          strokeWidth: 3.0,
                                          color: AppStyles.primaryBlue,
                                          backgroundColor: AppStyles.primaryBlue
                                              .withValues(alpha: 0.15),
                                        ),
                                        Text(
                                          '${remaining.ceil()}',
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            color: AppStyles.primaryBlue,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),

                          // Processing overlay
                          if (_phase == _Phase.processing)
                            Positioned(
                              left: (availW - circleSize) / 2,
                              top: circleTop,
                              child: Container(
                                width: circleSize,
                                height: circleSize,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.black.withValues(alpha: 0.5),
                                ),
                                child: const Center(
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 3,
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

              const SizedBox(height: 10),

              // ── Phase progress dots ──────────────────────────────────────
              if (_phase != _Phase.initializing &&
                  _phase != _Phase.processing &&
                  _phase != _Phase.done)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _PhaseDot(
                      label: 'Front',
                      isActive: _phase == _Phase.front,
                      isDone: _frontEmbeddings.length >= _framesPerPhase,
                    ),
                    const SizedBox(width: 8),
                    const Text('•', style: TextStyle(color: Color(0xFFCBD5E0))),
                    const SizedBox(width: 8),
                    _PhaseDot(
                      label: 'Left',
                      isActive: _phase == _Phase.left,
                      isDone: _leftEmbeddings.length >= _framesPerPhase,
                    ),
                    const SizedBox(width: 8),
                    const Text('•', style: TextStyle(color: Color(0xFFCBD5E0))),
                    const SizedBox(width: 8),
                    _PhaseDot(
                      label: 'Right',
                      isActive: _phase == _Phase.right,
                      isDone: _rightEmbeddings.length >= _framesPerPhase,
                    ),
                  ],
                ),

              const SizedBox(height: 4),

              // ── Instruction card ─────────────────────────────────────────
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: FadeTransition(
                      opacity: _textFadeController,
                      child: Container(
                        decoration: BoxDecoration(
                          color: _phase == _Phase.error
                              ? AppStyles.errorRed.withValues(alpha: 0.06)
                              : AppStyles.primaryBlue.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _instructionTitle,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: _phase == _Phase.error
                                    ? AppStyles.errorRed
                                    : AppStyles.primaryBlue,
                              ),
                            ),
                            const SizedBox(height: 6),
                            // FIXED: maxLines + ellipsis prevents RenderFlex
                            // overflow when error messages are long
                            Text(
                              _instructionSubtitle,
                              textAlign: TextAlign.center,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              softWrap: true,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: Color(0xFF4A5568),
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
                ),
              ),

              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  // Build camera preview — uses AspectRatio for correct 4:3 framing
  Widget _buildCameraPreview(double containerWidth) {
    if (!_cameraInitialized || _cameraController == null) {
      return Container(
        color: Colors.grey.shade200,
        child: const Center(child: CircularProgressIndicator()),
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

    _setPhase(_Phase.front);
  }
}

// ─── Phase indicator dot ──────────────────────────────────────────────────────
class _PhaseDot extends StatelessWidget {
  final String label;
  final bool isActive;
  final bool isDone;

  const _PhaseDot({
    required this.label,
    required this.isActive,
    required this.isDone,
  });

  @override
  Widget build(BuildContext context) {
    Color color;
    if (isDone) {
      color = AppStyles.successGreen;
    } else if (isActive) {
      color = AppStyles.primaryBlue;
    } else {
      color = const Color(0xFFCBD5E0);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: color,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

// ─── Scan line painter (kept from original) ───────────────────────────────────
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
  bool shouldRepaint(covariant _ScanLinePainter oldDelegate) => true;
}
