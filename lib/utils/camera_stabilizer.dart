import 'dart:async';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

class CameraStabilizer {
  final CameraController controller;
  final String sessionId;
  final String logPrefix;

  bool _isStabilizing = false;
  bool _isStable = false;
  bool _cancelled = false;
  double? _stableBrightness;
  double? _lastBrightness;

  // Diagnostic values
  double exposureDrift = 0.0;
  double frameBrightnessDelta = 0.0;
  double frameLuminanceVariance = 0.0;
  double exposureCompensationValue = 0.0;
  String exposureState = 'Auto';

  // Stabilization durations for summaries
  int warmUpDurationMs = 0;
  int focusStabilizationDurationMs = 0;
  int exposureStabilizationDurationMs = 0;

  bool get isStable => _isStable;
  double? get stableBrightness => _stableBrightness;

  CameraStabilizer({
    required this.controller,
    required this.sessionId,
    required this.logPrefix,
  });

  void log(String message) {
    debugPrint('[FACE_CAMERA] [$logPrefix][$sessionId] $message');
  }

  /// Cancel any in-progress stabilization immediately.
  /// Every async continuation inside [stabilize] will exit on the next check.
  void cancel() {
    _cancelled = true;
  }

  /// Reset stabilization state so [stabilize] can be safely called again.
  /// Must be called before re-using the stabilizer after [cancel].
  void resetForRestart() {
    _cancelled = false;
    _isStabilizing = false;
    _isStable = false;
    _stableBrightness = null;
    _lastBrightness = null;
  }

  /// Resets frame stability references while keeping the stabilizer marked as stable.
  /// Used during retry to skip the full warm-up/stabilization sequence.
  void resetStabilityOnly() {
    _cancelled = false;
    _isStabilizing = false;
    _isStable = true;
    _stableBrightness = null;
    _lastBrightness = null;
  }

  Future<void> stabilize() async {
    if (_isStabilizing) return;
    // Clear any leftover cancellation from a previous attempt before starting.
    _cancelled = false;
    _isStabilizing = true;
    _isStable = false;

    final overallStopwatch = Stopwatch()..start();

    // ── 1. Warm-up Stage ───────────────────────────────────────────────────
    log('Camera opened');
    log('Warm-up started');
    final warmUpStopwatch = Stopwatch()..start();
    // Warm-up timeout: 600ms
    await Future.delayed(const Duration(milliseconds: 600));
    if (_cancelled) { _isStabilizing = false; return; }
    warmUpStopwatch.stop();
    warmUpDurationMs = warmUpStopwatch.elapsedMilliseconds;
    log('Warm-up completed (duration: ${warmUpDurationMs}ms)');

    // Log general camera description
    log('Camera Description: ${controller.description.name}, Orientation: ${controller.description.sensorOrientation}°');

    // ── 2. Focus & Exposure Init ──────────────────────────────────────────
    // Set Auto Focus and Auto Exposure
    bool exposureAutoSupported = false;
    try {
      await controller.setExposureMode(ExposureMode.auto);
      if (_cancelled) { _isStabilizing = false; return; }
      exposureAutoSupported = true;
      log('Exposure Mode Auto: Supported');
    } catch (e) {
      if (_cancelled) { _isStabilizing = false; return; }
      log('Exposure Mode Auto Unsupported: $e');
    }

    bool focusAutoSupported = false;
    try {
      await controller.setFocusMode(FocusMode.auto);
      if (_cancelled) { _isStabilizing = false; return; }
      focusAutoSupported = true;
      log('Focus Mode Auto: Supported');
    } catch (e) {
      if (_cancelled) { _isStabilizing = false; return; }
      log('Focus Mode Auto Unsupported: $e');
    }

    // ── 3. Focus Stabilization ────────────────────────────────────────────
    log('Waiting for Focus Stabilization');
    final focusStopwatch = Stopwatch()..start();
    await Future.delayed(const Duration(milliseconds: 300));
    if (_cancelled) { _isStabilizing = false; return; }
    focusStopwatch.stop();
    focusStabilizationDurationMs = focusStopwatch.elapsedMilliseconds;
    log('Focus Stable');

    // Lock Focus if supported
    bool focusLockSupported = false;
    try {
      await controller.setFocusMode(FocusMode.locked);
      if (_cancelled) { _isStabilizing = false; return; }
      focusLockSupported = true;
      log('Focus Lock: Supported & Locked');
    } catch (e) {
      if (_cancelled) { _isStabilizing = false; return; }
      log('Focus Lock Unsupported (Using Auto Focus if supported). Reason: $e');
    }

    // ── 4. Exposure Stabilization ─────────────────────────────────────────
    log('Waiting for Exposure Stabilization');
    final exposureStopwatch = Stopwatch()..start();
    await Future.delayed(const Duration(milliseconds: 300));
    if (_cancelled) { _isStabilizing = false; return; }
    exposureStopwatch.stop();
    exposureStabilizationDurationMs = exposureStopwatch.elapsedMilliseconds;
    log('Exposure Stable');

    // Attempt exposure offset (e.g. compensation +0.3)
    bool exposureCompSupported = false;
    try {
      double minOffset = await controller.getMinExposureOffset();
      if (_cancelled) { _isStabilizing = false; return; }
      double maxOffset = await controller.getMaxExposureOffset();
      if (_cancelled) { _isStabilizing = false; return; }
      double targetOffset = 0.3;
      exposureCompSupported = minOffset != maxOffset;
      if (exposureCompSupported) {
        log('Exposure Compensation: Supported (Range: [$minOffset, $maxOffset])');
        if (targetOffset >= minOffset && targetOffset <= maxOffset) {
          await controller.setExposureOffset(targetOffset);
          if (_cancelled) { _isStabilizing = false; return; }
          exposureCompensationValue = targetOffset;
          log('Exposure Compensation Set: +0.3');
        } else {
          log('Exposure Compensation Target +0.3 out of bounds [$minOffset, $maxOffset]');
        }
      } else {
        log('Exposure Compensation: Unsupported (Range: [$minOffset, $maxOffset])');
      }
    } catch (e) {
      if (_cancelled) { _isStabilizing = false; return; }
      log('Exposure Compensation Unsupported. Reason: $e');
    }

    // Lock Exposure if supported
    bool exposureLockSupported = false;
    try {
      await controller.setExposureMode(ExposureMode.locked);
      if (_cancelled) { _isStabilizing = false; return; }
      exposureState = 'Locked';
      exposureLockSupported = true;
      log('Exposure Lock: Supported & Locked');
    } catch (e) {
      if (_cancelled) { _isStabilizing = false; return; }
      exposureState = focusAutoSupported ? 'Auto' : 'Default';
      log('Exposure Lock Unsupported (Using Auto Exposure if supported). Reason: $e');
    }

    overallStopwatch.stop();
    _isStable = true;
    _isStabilizing = false;
    log('Camera capabilities: FocusAuto=$focusAutoSupported, FocusLock=$focusLockSupported, ExposureAuto=$exposureAutoSupported, ExposureLock=$exposureLockSupported, ExposureComp=$exposureCompSupported');
    log('Warm-up duration: ${warmUpDurationMs}ms, Focus stabilize: ${focusStabilizationDurationMs}ms, Exposure stabilize: ${exposureStabilizationDurationMs}ms');
    log('Stabilization result: Success');
    log('Capture Begins');
  }

  /// Calculates stats for a camera frame (subsampled for speed)
  Map<String, double> computeFrameStats(CameraImage image) {
    final yPlane = image.planes[0];
    final bytes = yPlane.bytes;
    final len = bytes.length;
    if (len == 0) return {'brightness': 0.0, 'contrast': 0.0, 'sharpness': 0.0};

    // Subsample to avoid performance issues
    int sum = 0;
    final int step = (len / 1000).floor().clamp(1, 10000);
    int count = 0;
    for (int i = 0; i < len; i += step) {
      sum += bytes[i];
      count++;
    }
    final double mean = sum / count;

    double sumSquares = 0.0;
    double diffSum = 0.0;
    for (int i = 0; i < len; i += step) {
      final double val = bytes[i].toDouble();
      sumSquares += (val - mean) * (val - mean);
      if (i > 0) {
        diffSum += (bytes[i] - bytes[i - 1]).abs();
      }
    }
    final double stdDev = math.sqrt(sumSquares / count);
    final double sharpness = diffSum / count; // average gradient

    return {
      'brightness': mean,
      'contrast': stdDev,
      'sharpness': sharpness,
    };
  }

  /// Checks if the frame is stable compared to a reference brightness
  bool checkFrameStability(CameraImage image, {double threshold = 25.0}) {
    final stats = computeFrameStats(image);
    final currentBrightness = stats['brightness']!;
    
    if (_stableBrightness == null) {
      _stableBrightness = currentBrightness;
      _lastBrightness = currentBrightness;
      frameBrightnessDelta = 0.0;
      exposureDrift = 0.0;
      frameLuminanceVariance = stats['contrast']! * stats['contrast']!;
      return true;
    }

    frameBrightnessDelta = (currentBrightness - _lastBrightness!).abs();
    exposureDrift = (currentBrightness - _stableBrightness!).abs();
    frameLuminanceVariance = stats['contrast']! * stats['contrast']!;
    _lastBrightness = currentBrightness;

    if (exposureDrift > threshold) {
      log('Rejected: Brightness unstable (current=$currentBrightness, ref=$_stableBrightness, drift=$exposureDrift, threshold=$threshold)');
      return false;
    }

    // Slowly update reference brightness
    _stableBrightness = _stableBrightness! * 0.95 + currentBrightness * 0.05;
    return true;
  }
}
