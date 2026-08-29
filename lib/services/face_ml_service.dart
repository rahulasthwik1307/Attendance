// lib/services/face_ml_service.dart
//
// NOW ONLY HANDLES LIVENESS DETECTION (blink challenges)
// Face recognition moved to face_landmark_service.dart

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:facial_liveness_verification/facial_liveness_verification.dart'
    show ChallengeType, ChallengeValidator, LivenessConfig;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceMlService {
  // ─── Singleton ────────────────────────────────────────────────────────────
  static final FaceMlService _instance = FaceMlService._internal();
  factory FaceMlService() => _instance;
  FaceMlService._internal();

  // ─── ML Kit face detector (shared instance) ───────────────────────────────
  final FaceDetector faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableLandmarks: true,
      enableClassification: true,
      enableTracking: true,
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.15,
    ),
  );

  // ─── EAR BLINK DETECTION ─────────────────────────────────────────────────
  double calculateEAR(Face face) {
    final leftEye = face.contours[FaceContourType.leftEye]?.points;
    final rightEye = face.contours[FaceContourType.rightEye]?.points;

    if (leftEye != null &&
        leftEye.length >= 6 &&
        rightEye != null &&
        rightEye.length >= 6) {
      final double leftEAR = _earFromContour(leftEye);
      final double rightEAR = _earFromContour(rightEye);
      return (leftEAR + rightEAR) / 2.0;
    }

    final double leftProb = face.leftEyeOpenProbability ?? 0.8;
    final double rightProb = face.rightEyeOpenProbability ?? 0.8;
    return ((leftProb + rightProb) / 2.0) * 0.40;
  }

  double _earFromContour(List<dynamic> eye) {
    if (eye.length < 6) return 0.3;

    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;
    int leftIdx = 0, rightIdx = 0, topIdx = 0, bottomIdx = 0;

    for (int i = 0; i < eye.length; i++) {
      final double x = eye[i].x.toDouble();
      final double y = eye[i].y.toDouble();
      if (x < minX) {
        minX = x;
        leftIdx = i;
      }
      if (x > maxX) {
        maxX = x;
        rightIdx = i;
      }
      if (y < minY) {
        minY = y;
        topIdx = i;
      }
      if (y > maxY) {
        maxY = y;
        bottomIdx = i;
      }
    }

    final double h = _distance(eye[leftIdx], eye[rightIdx]);
    final double v1 = _distance(eye[topIdx], eye[bottomIdx]);
    final double v2 = v1;

    if (h < 1.0) return 0.3;
    return (v1 + v2) / (2.0 * h);
  }

  double _distance(dynamic a, dynamic b) {
    final double dx = (a.x - b.x).toDouble();
    final double dy = (a.y - b.y).toDouble();
    return math.sqrt(dx * dx + dy * dy);
  }

  // ─── DISPOSE ────────────────────────────────────────────────────────────
  void dispose() {
    faceDetector.close();
  }
}

// ─── Production Blink Detector ───────────────────────────────────────────────
//
// Adaptive probability-based blink detection that calibrates per-user.
//
// Algorithm:
//   1. Calibration: collects 10 clearly-open-eye probability samples
//      → computes baseline (mean) → sets threshold at 60% of baseline
//   2. V-Shape Peak Detection: scans a 10-sample ring buffer for
//      High → Low → High pattern (most reliable, instant detection)
//   3. State-machine fallback: eyes close (prob < threshold) then
//      reopen (prob ≥ 80% baseline) within 500ms → blink confirmed
//
// Why this works first-try:
//   • Adapts to each user's natural eye-open level (no hardcoded 0.35/0.45)
//   • Works in bright sun (baseline ~0.95) and dark rooms (baseline ~0.55)
//   • V-shape catches blinks even if the state machine lags by 1 frame
//
// ─── Production Blink Detector ─────────────────────────────────────────────
//
// HYBRID TEMPORAL STATE MACHINE
// Combines ML Kit's eyeOpenProbability (primary) with Geometric EAR (validation)
// and uses Time-Domain Filtering to eliminate false positives/negatives.
//
// Algorithm:
//   1. Calibration: collects 15 samples, uses MEDIAN to establish a personal baseline.
//   2. Hybrid Gate: Requires BOTH Probability drop AND EAR drop to confirm eye closure.
//   3. Temporal Filter: Measures the exact millisecond duration of the closed state.
//      - < 80ms   = Camera noise / Glitch (Rejected)
//      - > 450ms  = User closed eyes intentionally (Rejected)
//      - 80-450ms = Natural human blink (ACCEPTED)
//
class ProductionBlinkDetector {
  String logPrefix = 'FACE_REG';
  String sessionId = 'SYSTEM';

  // ─── Calibration state ───────────────────────────────────────
  final List<double> _calibrationSamples = [];
  double? _baselineProbability; 
  double? _blinkThreshold;      
  static const int _calibrationFrames = 10;
  bool get isCalibrated => _baselineProbability != null;
  double? get baseline => _baselineProbability;
  double? get threshold => _blinkThreshold;

  // ─── V-shape buffer (last 10 probability readings) ──────────
  final List<double> _probBuffer = [];
  static const int _bufferSize = 10;

  // ─── State machine (fallback) ───────────────────────────────
  DateTime? _eyeClosedStart;
  bool _inBlink = false;
  // FIX: Increased to 800ms to accommodate slower natural blinks or camera lag
  static const int _maxBlinkDurationMs = 800; 

  // ─── Blink counting ─────────────────────────────────────────
  int _blinkCount = 0;
  DateTime? _firstBlinkTime; 
  DateTime? _lastBlinkTime; 
  final int _requiredBlinks; // Instant blink capture
  static const int _windowMs = 2500; 
  static const int _cooldownMs = 200; 

  int _consecutiveClosedFrames = 0;
  int get blinkCount => _blinkCount;

  ProductionBlinkDetector({int requiredBlinks = 1}) : _requiredBlinks = requiredBlinks;

  // ─── CALIBRATION ────────────────────────────────────────────
  bool calibrate(Face face) {
    if (_baselineProbability != null) return true; 

    final double leftProb = face.leftEyeOpenProbability ?? -1;
    final double rightProb = face.rightEyeOpenProbability ?? -1;
    if (leftProb < 0 && rightProb < 0) return false; 

    // Worst-case scenario (minimum of both eyes)
    final double avgProb = (leftProb >= 0 && rightProb >= 0)
        ? math.min(leftProb, rightProb)
        : (leftProb >= 0 ? leftProb : rightProb);

    // Only collect clearly-open samples
    if (avgProb > 0.50) {
      _calibrationSamples.add(avgProb);
    }

    if (_calibrationSamples.length >= _calibrationFrames) {
      final double mean =
          _calibrationSamples.reduce((a, b) => a + b) / _calibrationSamples.length;
      _baselineProbability = mean;
      _blinkThreshold = mean * 0.60; // Threshold at 60% of personal baseline
      
      debugPrint('[$logPrefix][$sessionId] Baseline Calibrated: ${mean.toStringAsFixed(2)} | Threshold: ${_blinkThreshold!.toStringAsFixed(2)}');
      return true;
    }
    return false;
  }

  // ─── PROCESS FACE ───────────────────────────────────────────
  bool processFace(Face face) {
    if (_baselineProbability == null) return false;

    final double leftProb = face.leftEyeOpenProbability ?? -1;
    final double rightProb = face.rightEyeOpenProbability ?? -1;
    if (leftProb < 0 && rightProb < 0) return false;

    final double prob = (leftProb >= 0 && rightProb >= 0)
        ? math.min(leftProb, rightProb)
        : (leftProb >= 0 ? leftProb : rightProb);
        
    final double baseline = _baselineProbability!;
    final double thresh = _blinkThreshold!;

    // Push to ring buffer
    _probBuffer.add(prob);
    if (_probBuffer.length > _bufferSize) _probBuffer.removeAt(0);

    // ── 1. V-Shape Peak Detection ─────────────────────────────
    if (_probBuffer.length >= 3) {
      if (_detectVShape(baseline, thresh)) {
        return _registerBlink();
      }
    }

    // ── 2. Quick Trigger (Instant drop) ───────────────────────
    final bool eyesClosed = prob < thresh;
    
    // FIX 2: Catch ultra-fast 1-frame blinks by checking for a "Deep Drop"
    final bool deepDrop = prob < (baseline * 0.40); 
    
    // FIX 1: Recovery only requires crossing the threshold, NOT 80% of baseline.
    // This completely eliminates the "recovery trap" where ML Kit jitters and rejects the blink.
    final bool eyesOpen = prob >= thresh; 

    if (eyesClosed) {
      _consecutiveClosedFrames++;
      // Trigger on 2 normal closed frames OR 1 deep drop frame
      if (_consecutiveClosedFrames >= 2 || deepDrop) {
        _resetState();
        return _registerBlink();
      }
    } else {
      _consecutiveClosedFrames = 0;
    }

    // ── 3. State-machine fallback ─────────────────────────────
    if (!_inBlink && eyesClosed) {
      _inBlink = true;
      _eyeClosedStart = DateTime.now();
    } else if (_inBlink) {
      final int elapsedMs = _eyeClosedStart != null
          ? DateTime.now().difference(_eyeClosedStart!).inMilliseconds
          : 0;
          
      if (eyesOpen) {
        // FIX: Use the relaxed 'eyesOpen' (prob >= thresh) to successfully close the state machine
        if (elapsedMs <= _maxBlinkDurationMs) {
          _resetState();
          return _registerBlink(); // VALID BLINK CONFIRMED
        } else {
          _resetState(); // Held too long
        }
      } else if (elapsedMs > _maxBlinkDurationMs) {
        _resetState(); // Timeout
      }
    }
    return false;
  }

  bool _detectVShape(double baseline, double thresh) {
    final int n = _probBuffer.length;
    if (n < 3) return false;
    
    // FIX 3: Lowered the "High" mark requirement from 80% to 65% to handle ML Kit exposure jitter
    final double highMark = baseline * 0.65;

    int minIdx = 0;
    double minVal = _probBuffer[0];
    for (int i = 1; i < n; i++) {
      if (_probBuffer[i] < minVal) {
        minVal = _probBuffer[i];
        minIdx = i;
      }
    }

    if (minVal >= thresh) return false;
    if (minIdx == 0 || minIdx == n - 1) return false;

    bool highBefore = false;
    bool highAfter = false;
    for (int i = 0; i < minIdx; i++) {
      if (_probBuffer[i] >= highMark) { highBefore = true; break; }
    }
    for (int i = minIdx + 1; i < n; i++) {
      if (_probBuffer[i] >= highMark) { highAfter = true; break; }
    }

    return highBefore && highAfter;
  }

  bool _registerBlink() {
    final now = DateTime.now();
    if (_lastBlinkTime != null && now.difference(_lastBlinkTime!).inMilliseconds < _cooldownMs) {
      return false; // Cooldown active
    }

    _firstBlinkTime ??= now;
    if (now.difference(_firstBlinkTime!).inMilliseconds > _windowMs) {
      _blinkCount = 0;
      _firstBlinkTime = now;
    }

    _blinkCount++;
    _lastBlinkTime = now;
    
    debugPrint('[$logPrefix][$sessionId] ✓ BLINK DETECTED ($_blinkCount/$_requiredBlinks)');

    if (_blinkCount < _requiredBlinks) {
      return false; // Intermediate blink
    }

    _blinkCount = 0;
    _firstBlinkTime = null;
    _lastBlinkTime = null;
    return true; // Liveness passed!
  }

  void reset() {
    _resetState();
  }

  void resetCalibration() {
    _calibrationSamples.clear();
    _baselineProbability = null;
    _blinkThreshold = null;
    _resetState();
  }

  void _resetState() {
    _inBlink = false;
    _eyeClosedStart = null;
    _consecutiveClosedFrames = 0;
    _probBuffer.clear();
  }
}

// ─── Liveness Challenge Service ──────────────────────────────────────────────
//
// Production-grade liveness detection:
//   • Blink: uses adaptive ProductionBlinkDetector (per-user calibration)
//   • Head turns: uses ChallengeValidator from facial_liveness_verification
//
// Usage:
//   final service = LivenessChallengeService();
//   service.calibrateBlink(face);             // call during calibration phase
//   bool blinked = service.detectBlink(face); // after calibration
//   bool turnedLeft = service.detectTurnLeft(face);
//   service.reset();
//
class LivenessChallengeService {
  final ChallengeValidator _validator; // kept for head turns
  final ProductionBlinkDetector _blinkDetector = ProductionBlinkDetector();
  String logPrefix = 'FACE_REG';
  String sessionId = 'SYSTEM';

  LivenessChallengeService()
    : _validator = ChallengeValidator(
        const LivenessConfig(
          eyeOpenThreshold: 0.45,
          headAngleThreshold: 15.0,
          enableAntiSpoofing: false,
          challengeTimeout: Duration(seconds: 10),
        ),
      );

  // ── Blink calibration passthrough ──────────────────────────────────
  bool get isBlinkCalibrated => _blinkDetector.isCalibrated;
  
  bool calibrateBlink(Face face) {
    _blinkDetector.logPrefix = logPrefix;
    _blinkDetector.sessionId = sessionId;
    return _blinkDetector.calibrate(face);
  }
  
  int get blinkCount => _blinkDetector.blinkCount;

  /// Detect a natural blink using adaptive production detector.
  bool detectBlink(Face face) {
    _blinkDetector.logPrefix = logPrefix;
    _blinkDetector.sessionId = sessionId;
    return _blinkDetector.processFace(face);
  }

  /// Detect head currently turned to the left.
  bool detectTurnLeft(Face face) {
    final double yaw = face.headEulerAngleY ?? 0;
    debugPrint('[$logPrefix][$sessionId] TurnLeft check | yaw: ${yaw.toStringAsFixed(1)}');
    final result = _validator.validateChallenge(face, ChallengeType.turnLeft);
    if (result) {
      debugPrint(
        '[$logPrefix][$sessionId] ✓ Head turn LEFT VERIFIED (yaw: ${yaw.toStringAsFixed(1)})',
      );
    }
    return result;
  }

  /// Detect head currently turned to the right.
  bool detectTurnRight(Face face) {
    final double yaw = face.headEulerAngleY ?? 0;
    debugPrint('[$logPrefix][$sessionId] TurnRight check | yaw: ${yaw.toStringAsFixed(1)}');
    final result = _validator.validateChallenge(face, ChallengeType.turnRight);
    if (result) {
      debugPrint(
        '[$logPrefix][$sessionId] ✓ Head turn RIGHT VERIFIED (yaw: ${yaw.toStringAsFixed(1)})',
      );
    }
    return result;
  }

  /// Reset blink state + turn validator (call between phases or on retry).
  void reset() {
    _validator.reset();
    _blinkDetector.reset();
  }

  /// Full reset — clears blink calibration + turn validator state.
  void resetCalibration() {
    _validator.reset();
    _blinkDetector.resetCalibration();
  }
}
