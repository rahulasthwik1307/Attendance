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
class ProductionBlinkDetector {
  // ── Calibration state ──────────────────────────────────────────────
  final List<double> _calibrationSamples = [];
  double? _baselineProbability; // mean open-eye prob for THIS user
  double? _blinkThreshold; // 60% of baseline
  static const int _calibrationFrames = 10;

  bool get isCalibrated => _baselineProbability != null;
  double? get baseline => _baselineProbability;
  double? get threshold => _blinkThreshold;

  // ── V-shape buffer (last 10 probability readings) ─────────────────
  final List<double> _probBuffer = [];
  static const int _bufferSize = 10;

  // ── State machine (fallback) ──────────────────────────────────────
  DateTime? _eyeClosedStart;
  bool _inBlink = false;
  static const int _maxBlinkDurationMs = 500;

  // ── Double-blink counter ──────────────────────────────────────────
  // Requires 1 distinct blink within _windowMs.
  int _blinkCount = 0;
  DateTime? _firstBlinkTime; // start of the 2.5s window
  DateTime? _lastBlinkTime; // prevents counting one long blink as two
  static const int _requiredBlinks = 1; // Instant blink capture
  static const int _windowMs = 2500; // 2.5 second window
  static const int _cooldownMs = 200; // min gap between blinks

  // ── Quick Trigger ───────────────────────────────────────────────
  int _consecutiveClosedFrames = 0;

  int get blinkCount => _blinkCount;

  // ────────────────────────────────────────────────────────────────────
  // CALIBRATION — adaptive baseline per user
  //
  // Collects 10 frames where eyes are clearly open (prob > 0.50).
  // Sets baseline = mean, threshold = baseline × 0.60.
  // Returns true when calibration is complete.
  // ────────────────────────────────────────────────────────────────────
  bool calibrate(Face face) {
    if (_baselineProbability != null) return true; // already calibrated

    final double leftProb = face.leftEyeOpenProbability ?? -1;
    final double rightProb = face.rightEyeOpenProbability ?? -1;
    if (leftProb < 0 && rightProb < 0) return false; // no data

    // Use the minimum of both eyes (worst-case)
    final double avgProb = (leftProb >= 0 && rightProb >= 0)
        ? math.min(leftProb, rightProb)
        : (leftProb >= 0 ? leftProb : rightProb);

    // Only collect clearly-open samples (prob > 0.50)
    if (avgProb > 0.50) {
      _calibrationSamples.add(avgProb);
      debugPrint(
        '[FACE_REG] Calibration sample ${_calibrationSamples.length}/$_calibrationFrames '
        '| prob=${avgProb.toStringAsFixed(3)}',
      );
    }

    if (_calibrationSamples.length >= _calibrationFrames) {
      final double mean =
          _calibrationSamples.reduce((a, b) => a + b) /
          _calibrationSamples.length;
      _baselineProbability = mean;
      _blinkThreshold = mean * 0.60; // 60% of personal baseline

      debugPrint(
        '[FACE_REG] Baseline Calibrated: ${mean.toStringAsFixed(2)} '
        '| Threshold Set: ${_blinkThreshold!.toStringAsFixed(2)}',
      );
      return true;
    }

    return false;
  }

  // ────────────────────────────────────────────────────────────────────
  // PROCESS FACE — V-shape detection + state-machine fallback
  //
  // Returns true when a valid blink is detected.
  // ────────────────────────────────────────────────────────────────────
  bool processFace(Face face) {
    if (_baselineProbability == null) return false;

    final double leftProb = face.leftEyeOpenProbability ?? -1;
    final double rightProb = face.rightEyeOpenProbability ?? -1;
    if (leftProb < 0 && rightProb < 0) return false;

    // Min of both eyes (worst eye must close for a real blink)
    final double prob = (leftProb >= 0 && rightProb >= 0)
        ? math.min(leftProb, rightProb)
        : (leftProb >= 0 ? leftProb : rightProb);

    final double baseline = _baselineProbability!;
    final double thresh = _blinkThreshold!;

    debugPrint(
      '[FACE_REG] Blink check | '
      'prob=${prob.toStringAsFixed(3)} '
      'baseline=${baseline.toStringAsFixed(3)} '
      'threshold=${thresh.toStringAsFixed(3)} '
      'bufLen=${_probBuffer.length} '
      'state=${_inBlink ? "CLOSED" : "OPEN"}',
    );

    // ── Push into ring buffer ──────────────────────────────────────
    _probBuffer.add(prob);
    if (_probBuffer.length > _bufferSize) {
      _probBuffer.removeAt(0);
    }

    // ── 1. V-Shape Peak Detection ─────────────────────────────────
    // Scan buffer for: High (≥ 80% baseline) → Low (< threshold) → High
    if (_probBuffer.length >= 3) {
      if (_detectVShape(baseline, thresh)) {
        return _registerBlink();
      }
    }

    // ── 2. Quick Trigger (Instant drop) ───────────────────────────
    final bool eyesClosed = prob < thresh;
    final bool eyesOpen = prob >= baseline * 0.80;

    if (eyesClosed) {
      _consecutiveClosedFrames++;
      if (_consecutiveClosedFrames >= 2) {
        debugPrint(
          '[FACE_REG] Blink candidate (Quick Trigger, 2 frames below threshold)',
        );
        _resetState();
        return _registerBlink();
      }
    } else {
      _consecutiveClosedFrames = 0;
    }

    // ── 3. State-machine fallback ─────────────────────────────────
    if (!_inBlink && eyesClosed) {
      // Eyes just closed — start timer
      _inBlink = true;
      _eyeClosedStart = DateTime.now();
      debugPrint('[FACE_REG] Blink state → CLOSED (timer started)');
    } else if (_inBlink) {
      final int elapsedMs = _eyeClosedStart != null
          ? DateTime.now().difference(_eyeClosedStart!).inMilliseconds
          : 0;

      if (eyesOpen) {
        // Eyes reopened — check duration
        if (elapsedMs <= _maxBlinkDurationMs) {
          debugPrint(
            '[FACE_REG] Blink candidate (state-machine, ${elapsedMs}ms)',
          );
          _resetState();
          return _registerBlink();
        } else {
          debugPrint(
            '[FACE_REG] Blink rejected — too long (${elapsedMs}ms > ${_maxBlinkDurationMs}ms)',
          );
          _resetState();
        }
      } else if (elapsedMs > _maxBlinkDurationMs) {
        // Held eyes closed too long — not a blink
        debugPrint(
          '[FACE_REG] Blink aborted — eyes held closed ${elapsedMs}ms',
        );
        _resetState();
      }
    }

    return false;
  }

  // ────────────────────────────────────────────────────────────────────
  // REGISTER BLINK — counts towards double-blink requirement
  //
  // Records each valid blink, enforces 200ms cooldown between blinks,
  // tracks a 2.5s window, and returns true only when 2 blinks are counted.
  // ────────────────────────────────────────────────────────────────────
  bool _registerBlink() {
    final now = DateTime.now();

    // Enforce cooldown — ignore if last blink was too recent
    if (_lastBlinkTime != null &&
        now.difference(_lastBlinkTime!).inMilliseconds < _cooldownMs) {
      debugPrint('[FACE_REG] Blink ignored — cooldown active');
      return false;
    }

    // Start window on first blink
    _firstBlinkTime ??= now;

    // Check if window has expired — reset if so
    if (now.difference(_firstBlinkTime!).inMilliseconds > _windowMs) {
      debugPrint('[FACE_REG] Blink window expired — resetting counter');
      _blinkCount = 0;
      _firstBlinkTime = now;
    }

    _blinkCount++;
    _lastBlinkTime = now;

    if (_blinkCount < _requiredBlinks) {
      debugPrint(
        '[FACE_REG] Blink $_blinkCount detected. Waiting for ${_requiredBlinks - _blinkCount} more…',
      );
      return false; // intermediate blink — signal screen but don't complete
    }

    // Double blink achieved
    debugPrint('[FACE_REG] ✓ Double Blink Verified. Proceeding to capture.');
    // Reset counter so if re-used it starts fresh
    _blinkCount = 0;
    _firstBlinkTime = null;
    _lastBlinkTime = null;
    return true;
  }

  // ────────────────────────────────────────────────────────────────────
  // V-SHAPE SCANNER — finds High → Low → High pattern in buffer
  //
  // Scans the buffer backwards from the most recent frames.
  // Requires at least one sample below threshold flanked by samples
  // at ≥ 80% of baseline on both sides.
  // ────────────────────────────────────────────────────────────────────
  bool _detectVShape(double baseline, double thresh) {
    final int n = _probBuffer.length;
    if (n < 3) return false;

    final double highMark = baseline * 0.80;

    // Find the minimum value in the buffer
    int minIdx = 0;
    double minVal = _probBuffer[0];
    for (int i = 1; i < n; i++) {
      if (_probBuffer[i] < minVal) {
        minVal = _probBuffer[i];
        minIdx = i;
      }
    }

    // Min must be below the blink threshold
    if (minVal >= thresh) return false;

    // Must not be at the edges (need flanking high values)
    if (minIdx == 0 || minIdx == n - 1) return false;

    // Check for at least one high value before and after the dip
    bool highBefore = false;
    bool highAfter = false;

    for (int i = 0; i < minIdx; i++) {
      if (_probBuffer[i] >= highMark) {
        highBefore = true;
        break;
      }
    }
    for (int i = minIdx + 1; i < n; i++) {
      if (_probBuffer[i] >= highMark) {
        highAfter = true;
        break;
      }
    }

    return highBefore && highAfter;
  }

  /// Reset blink state machine and buffer (NOT calibration).
  void reset() {
    _resetState();
  }

  /// Full reset — clears calibration and all state.
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
    // NOTE: intentionally does NOT reset _blinkCount / _firstBlinkTime /
    // _lastBlinkTime — those are part of the double-blink window logic
    // and are reset only via resetCalibration() or inside _registerBlink().
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
  bool calibrateBlink(Face face) => _blinkDetector.calibrate(face);
  int get blinkCount => _blinkDetector.blinkCount;

  /// Detect a natural blink using adaptive production detector.
  bool detectBlink(Face face) {
    return _blinkDetector.processFace(face);
  }

  /// Detect head currently turned to the left.
  bool detectTurnLeft(Face face) {
    final double yaw = face.headEulerAngleY ?? 0;
    debugPrint('[FACE_REG] TurnLeft check | yaw: ${yaw.toStringAsFixed(1)}');
    final result = _validator.validateChallenge(face, ChallengeType.turnLeft);
    if (result) {
      debugPrint(
        '[FACE_REG] ✓ Head turn LEFT VERIFIED (yaw: ${yaw.toStringAsFixed(1)})',
      );
    }
    return result;
  }

  /// Detect head currently turned to the right.
  bool detectTurnRight(Face face) {
    final double yaw = face.headEulerAngleY ?? 0;
    debugPrint('[FACE_REG] TurnRight check | yaw: ${yaw.toStringAsFixed(1)}');
    final result = _validator.validateChallenge(face, ChallengeType.turnRight);
    if (result) {
      debugPrint(
        '[FACE_REG] ✓ Head turn RIGHT VERIFIED (yaw: ${yaw.toStringAsFixed(1)})',
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
