// lib/services/face_landmark_service.dart
//
// Uses MobileFaceNet TFLite model (mobilefacenet.tflite) to generate 192-dim
// face embeddings from cropped+aligned face images.
//
// Maintains exact same public API so screens don't need changes.

import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'package:shared_preferences/shared_preferences.dart';

class FaceLandmarkService {
  static final FaceLandmarkService _instance = FaceLandmarkService._internal();
  factory FaceLandmarkService() => _instance;
  FaceLandmarkService._internal();

  Interpreter? _interpreter;
  bool _isInitialized = false;

  // Public API - matches old FaceMlService
  Future<void> initialize() async {
    if (_isInitialized) return;

    final options = InterpreterOptions()
      ..useNnApiForAndroid = false
      ..threads = 4;
    _interpreter = await Interpreter.fromAsset(
      'assets/models/mobilefacenet.tflite',
      options: options,
    );
    _interpreter!.allocateTensors();

    _isInitialized = true;
    debugPrint('[FACE_LANDMARK] Initialized MobileFaceNet TFLite interpreter');
  }

  // Generates 192-dim MobileFaceNet embedding from face crop
  // Matches old method signature exactly
  Future<List<double>?> generateEmbedding({
    required Uint8List jpegBytes,
    required dynamic face, // google_mlkit_face_detection Face object
  }) async {
    if (!_isInitialized) await initialize();
    if (_interpreter == null) return null;

    try {
      debugPrint(
        '[FACE_LANDMARK] Starting MobileFaceNet embedding on ${jpegBytes.length} bytes',
      );

      // Step 1 — Decode the JPEG bytes to an image
      final img.Image? decoded = img.decodeJpg(jpegBytes);
      if (decoded == null) {
        debugPrint('[FACE_LANDMARK] Failed to decode JPEG');
        return null;
      }
      debugPrint(
        '[FACE_LANDMARK] Decoded image: ${decoded.width}x${decoded.height}',
      );

      // Step 2 — Extract bounding box from face parameter and crop
      // The JPEG was built from YUV in landscape orientation, so rotate
      // 90° counter-clockwise first because the bounding box is in portrait space.
      final img.Image rotated = img.copyRotate(decoded, angle: -90);
      debugPrint(
        '[FACE_LANDMARK] Rotated image: ${rotated.width}x${rotated.height}',
      );

      // Get bounding box from the google_mlkit Face object
      final dynamic boundingBox = face.boundingBox;
      final double fbLeft = (boundingBox.left as num).toDouble();
      final double fbTop = (boundingBox.top as num).toDouble();
      final double fbWidth = (boundingBox.width as num).toDouble();
      final double fbHeight = (boundingBox.height as num).toDouble();

      // Add 20% padding on all sides
      final double padX = fbWidth * 0.20;
      final double padY = fbHeight * 0.20;

      // Clamp to image bounds
      final int cropLeft = (fbLeft - padX).clamp(0, rotated.width - 1).toInt();
      final int cropTop = (fbTop - padY).clamp(0, rotated.height - 1).toInt();
      final int cropRight = (fbLeft + fbWidth + padX)
          .clamp(0, rotated.width)
          .toInt();
      final int cropBottom = (fbTop + fbHeight + padY)
          .clamp(0, rotated.height)
          .toInt();
      final int cropW = cropRight - cropLeft;
      final int cropH = cropBottom - cropTop;

      if (cropW <= 0 || cropH <= 0) {
        debugPrint('[FACE_LANDMARK] Invalid crop dimensions: ${cropW}x$cropH');
        return null;
      }

      final img.Image cropped = img.copyCrop(
        rotated,
        x: cropLeft,
        y: cropTop,
        width: cropW,
        height: cropH,
      );
      debugPrint(
        '[FACE_LANDMARK] Cropped face: ${cropped.width}x${cropped.height}',
      );

      // Step 3 — Resize to 112x112
      final img.Image resized = img.copyResize(
        cropped,
        width: 112,
        height: 112,
        interpolation: img.Interpolation.linear,
      );

      // Step 3.5 — Adaptive gamma correction
      double brightnessSum = 0.0;
      for (int y = 0; y < 112; y++) {
        for (int x = 0; x < 112; x++) {
          final p = resized.getPixel(x, y);
          brightnessSum +=
              0.299 * p.r.toDouble() +
              0.587 * p.g.toDouble() +
              0.114 * p.b.toDouble();
        }
      }
      final double avgBrightness = (brightnessSum / (112 * 112 * 255)).clamp(
        0.01,
        0.99,
      );
      double gamma = math.log(0.5) / math.log(avgBrightness);
      gamma = gamma.clamp(0.5, 2.5);
      debugPrint(
        '[FACE_LANDMARK] Gamma correction applied: gamma=${gamma.toStringAsFixed(4)} avgBrightness=${avgBrightness.toStringAsFixed(4)}',
      );
      final img.Image gammaCorrected = img.Image(width: 112, height: 112);
      for (int y = 0; y < 112; y++) {
        for (int x = 0; x < 112; x++) {
          final p = resized.getPixel(x, y);
          final int newR = (255 * math.pow(p.r.toDouble() / 255.0, gamma))
              .round()
              .clamp(0, 255);
          final int newG = (255 * math.pow(p.g.toDouble() / 255.0, gamma))
              .round()
              .clamp(0, 255);
          final int newB = (255 * math.pow(p.b.toDouble() / 255.0, gamma))
              .round()
              .clamp(0, 255);
          gammaCorrected.setPixelRgb(x, y, newR, newG, newB);
        }
      }

      // Step 4 — Build flat Float32List with per-image standardization
      // First pass: collect channel values
      final List<double> rVals = [];
      final List<double> gVals = [];
      final List<double> bVals = [];
      for (int y = 0; y < 112; y++) {
        for (int x = 0; x < 112; x++) {
          final pixel = gammaCorrected.getPixel(x, y);
          rVals.add(pixel.r.toDouble());
          gVals.add(pixel.g.toDouble());
          bVals.add(pixel.b.toDouble());
        }
      }
      double mean(List<double> v) => v.reduce((a, b) => a + b) / v.length;
      double std(List<double> v, double m) {
        double s = 0.0;
        for (final val in v) {
          s += (val - m) * (val - m);
        }
        return math.sqrt(s / v.length);
      }

      final double rMean = mean(rVals),
          gMean = mean(gVals),
          bMean = mean(bVals);
      final double rStd = std(rVals, rMean),
          gStd = std(gVals, gMean),
          bStd = std(bVals, bMean);
      debugPrint(
        '[FACE_LANDMARK] Per-channel stats: rMean=${rMean.toStringAsFixed(2)} rStd=${rStd.toStringAsFixed(2)} gMean=${gMean.toStringAsFixed(2)} gStd=${gStd.toStringAsFixed(2)} bMean=${bMean.toStringAsFixed(2)} bStd=${bStd.toStringAsFixed(2)}',
      );
      // Second pass: normalize
      final inputBuffer = Float32List(1 * 112 * 112 * 3);
      int pixelIndex = 0;
      for (int y = 0; y < 112; y++) {
        for (int x = 0; x < 112; x++) {
          final pixel = gammaCorrected.getPixel(x, y);
          inputBuffer[pixelIndex++] =
              ((pixel.r.toDouble() - rMean) / (rStd + 1e-6)).clamp(-3.0, 3.0);
          inputBuffer[pixelIndex++] =
              ((pixel.g.toDouble() - gMean) / (gStd + 1e-6)).clamp(-3.0, 3.0);
          inputBuffer[pixelIndex++] =
              ((pixel.b.toDouble() - bMean) / (bStd + 1e-6)).clamp(-3.0, 3.0);
        }
      }

      // Step 5 — Run interpreter. Output shape: [1, 192]
      final outputBuffer = Float32List(192);
      _interpreter!.run(inputBuffer.buffer, outputBuffer.buffer);

      final List<double> rawEmbedding = outputBuffer.toList();
      debugPrint(
        '[FACE_LANDMARK] Raw embedding length: ${rawEmbedding.length}',
      );
      debugPrint(
        '[FACE_LANDMARK] First 5 values: ${rawEmbedding.sublist(0, 5).map((v) => v.toStringAsFixed(4)).join(', ')}',
      );

      // Step 6 — L2 normalize the 192-dim output vector
      final normalized = _l2Normalize(rawEmbedding);
      debugPrint(
        '[FACE_LANDMARK] Generated normalized 192-dim MobileFaceNet embedding',
      );

      return normalized;
    } catch (e) {
      debugPrint('[FACE_LANDMARK] generateEmbedding error: $e');
      debugPrint('[FACE_LANDMARK] Stack trace: ${StackTrace.current}');
      return null;
    }
  }

  // L2 normalization - identical to old method
  List<double> _l2Normalize(List<double> embedding) {
    double magnitude = 0.0;
    for (final v in embedding) {
      magnitude += v * v;
    }
    magnitude = math.sqrt(magnitude);
    if (magnitude < 1e-10) return embedding;
    return embedding.map((v) => v / magnitude).toList();
  }

  // AVERAGE EMBEDDINGS - identical to old method
  List<double> averageEmbeddings(List<List<double>> embeddings) {
    debugPrint('[FACE_LANDMARK] Averaging ${embeddings.length} embeddings');
    if (embeddings.isEmpty) {
      debugPrint('[FACE_LANDMARK] No embeddings to average');
      return [];
    }
    if (embeddings.length == 1) {
      debugPrint('[FACE_LANDMARK] Only one embedding, returning as is');
      return embeddings[0];
    }

    final int vecSize = embeddings[0].length;
    debugPrint('[FACE_LANDMARK] Embedding dimension: $vecSize');

    final List<double> averaged = List.filled(vecSize, 0.0);

    for (final emb in embeddings) {
      for (int i = 0; i < vecSize; i++) {
        averaged[i] += emb[i];
      }
    }
    for (int i = 0; i < vecSize; i++) {
      averaged[i] /= embeddings.length;
    }

    final normalized = _l2Normalize(averaged);
    debugPrint(
      '[FACE_LANDMARK] Averaged embedding first 5: ${normalized.sublist(0, 5).map((v) => v.toStringAsFixed(4)).join(', ')}',
    );

    return normalized;
  }

  // COSINE SIMILARITY - identical to old method
  double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  // VERIFY FACE — compare live embeddings against storedEmbeddingA only
  // using cosine similarity, take the median score, compare against threshold.
  VerificationResult verifyFace({
    required List<List<double>> liveEmbeddings,
    required List<double> storedEmbeddingA,
    required List<double> storedEmbeddingB,
    required List<double> storedEmbeddingC,
    double threshold = 0.75,
  }) {
    if (liveEmbeddings.isEmpty) {
      return VerificationResult(
        isMatch: false,
        score: 0.0,
        message: 'No frames captured',
      );
    }

    debugPrint('[FACE_VER] ═══ VERIFICATION DEBUG (MobileFaceNet) ═══');
    debugPrint('[FACE_VER] Live frames: ${liveEmbeddings.length}');
    debugPrint('[FACE_VER] StoredA (front) length: ${storedEmbeddingA.length}');
    debugPrint(
      '[FACE_VER] StoredA first 5: ${storedEmbeddingA.sublist(0, 5).map((v) => v.toStringAsFixed(4)).join(', ')}',
    );

    // Compare each live embedding against all three stored embeddings, take best
    final List<double> frontScores = [];
    for (int i = 0; i < liveEmbeddings.length; i++) {
      final double scoreA = cosineSimilarity(
        liveEmbeddings[i],
        storedEmbeddingA,
      );
      final double scoreB = cosineSimilarity(
        liveEmbeddings[i],
        storedEmbeddingB,
      );
      final double scoreC = cosineSimilarity(
        liveEmbeddings[i],
        storedEmbeddingC,
      );
      final double best = [scoreA, scoreB, scoreC].reduce(math.max);
      frontScores.add(best);
      debugPrint(
        '[FACE_VER] Frame $i → scoreA=${scoreA.toStringAsFixed(4)} scoreB=${scoreB.toStringAsFixed(4)} scoreC=${scoreC.toStringAsFixed(4)} best=${best.toStringAsFixed(4)}',
      );
    }

    // Take median score
    final List<double> sortedScores = List.from(frontScores)..sort();
    final double medianScore = sortedScores[sortedScores.length ~/ 2];

    final double dynamicThreshold = _calculateDynamicThreshold(frontScores);
    // Use the stricter of the two thresholds (provided default or dynamic)
    final double effectiveThreshold = math.max(threshold, dynamicThreshold);

    debugPrint(
      '[FACE_VER] medianScore=${medianScore.toStringAsFixed(4)} fixed_threshold=$threshold dynamic_threshold=${dynamicThreshold.toStringAsFixed(4)}',
    );

    if (medianScore >= effectiveThreshold) {
      return VerificationResult(
        isMatch: true,
        score: medianScore,
        message: 'Verified',
      );
    }

    String message = medianScore > 0.15
        ? 'Try in better lighting'
        : 'Face not recognized';
    return VerificationResult(
      isMatch: false,
      score: medianScore,
      message: message,
    );
  }

  // DYNAMIC THRESHOLD — adjusts based on score consistency (MobileFaceNet thresholds)
  double _calculateDynamicThreshold(List<double> scores) {
    if (scores.isEmpty) return 0.75;

    // Calculate mean
    double mean = scores.reduce((a, b) => a + b) / scores.length;

    // Calculate variance
    double variance =
        scores.map((s) => (s - mean) * (s - mean)).reduce((a, b) => a + b) /
        scores.length;

    // MobileFaceNet thresholds in working range
    if (variance < 0.005) {
      return 0.72; // Low variance — consistent scores, slightly relaxed
    } else if (variance < 0.02) {
      return 0.74; // Medium variance
    } else {
      return 0.75; // High variance
    }
  }

  // CLEAR EMBEDDINGS CACHE
  Future<void> clearEmbeddingsCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('emb_a');
    await prefs.remove('emb_b');
    await prefs.remove('emb_c');
    await prefs.remove('emb_student_id');
    await prefs.remove('emb_cached_at');
    debugPrint('[FACE_LANDMARK] Cleared embeddings cache');
  }

  // DISPOSE — call when app closes
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isInitialized = false;
  }
}

// Result type - identical to old one
class VerificationResult {
  final bool isMatch;
  final double score;
  final String message;

  const VerificationResult({
    required this.isMatch,
    required this.score,
    required this.message,
  });
}
