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

      // Step 2.5 — Brightness quality gate on cropped face
      double cropBrightnessSum = 0.0;
      for (int y = 0; y < cropH; y++) {
        for (int x = 0; x < cropW; x++) {
          final p = cropped.getPixel(x, y);
          cropBrightnessSum +=
              0.299 * p.r.toDouble() +
              0.587 * p.g.toDouble() +
              0.114 * p.b.toDouble();
        }
      }
      final double avgCropBrightness =
          cropBrightnessSum / (cropW * cropH * 255);
      if (avgCropBrightness < 0.16 || avgCropBrightness > 0.94) {
        debugPrint(
          '[FACE_LANDMARK] Frame rejected: poor lighting avgCropBrightness=${avgCropBrightness.toStringAsFixed(4)}',
        );
        return null;
      }

      // Anti-spoof Check 1 — Color Variance (Screen Detection)
      double sumR = 0.0, sumG = 0.0, sumB = 0.0;
      final int totalPixels = cropW * cropH;
      for (int y = 0; y < cropH; y++) {
        for (int x = 0; x < cropW; x++) {
          final p = cropped.getPixel(x, y);
          sumR += p.r.toDouble();
          sumG += p.g.toDouble();
          sumB += p.b.toDouble();
        }
      }
      final double meanR = sumR / totalPixels;
      final double meanG = sumG / totalPixels;
      final double meanB = sumB / totalPixels;
      double colorVarianceSum = 0.0;
      for (int y = 0; y < cropH; y++) {
        for (int x = 0; x < cropW; x++) {
          final p = cropped.getPixel(x, y);
          final double dr = p.r.toDouble() - meanR;
          final double dg = p.g.toDouble() - meanG;
          final double db = p.b.toDouble() - meanB;
          colorVarianceSum += dr * dr + dg * dg + db * db;
        }
      }
      final double colorVariance = colorVarianceSum / totalPixels;
      if (colorVariance < 80.0) {
        debugPrint(
          '[FACE_LANDMARK] Anti-spoof rejected: low color variance=${colorVariance.toStringAsFixed(1)}',
        );
        return null;
      }

      // Anti-spoof Check 2 — LBP Texture Diversity (Skin Texture Detection)
      final int lbpX = (cropW - 64) ~/ 2;
      final int lbpY = (cropH - 64) ~/ 2;
      final List<List<double>> grayRegion = List.generate(
        64,
        (ry) => List.generate(64, (rx) {
          final p = cropped.getPixel(lbpX + rx, lbpY + ry);
          return 0.299 * p.r.toDouble() +
              0.587 * p.g.toDouble() +
              0.114 * p.b.toDouble();
        }),
      );
      final Set<int> lbpCodes = {};
      for (int y = 1; y <= 62; y++) {
        for (int x = 1; x <= 62; x++) {
          final double center = grayRegion[y][x];
          int code = 0;
          if (grayRegion[y - 1][x - 1] >= center) code |= 1 << 7; // top-left
          if (grayRegion[y - 1][x] >= center) code |= 1 << 6; // top
          if (grayRegion[y - 1][x + 1] >= center) code |= 1 << 5; // top-right
          if (grayRegion[y][x + 1] >= center) code |= 1 << 4; // right
          if (grayRegion[y + 1][x + 1] >= center) {
            code |= 1 << 3; // bottom-right
          }
          if (grayRegion[y + 1][x] >= center) code |= 1 << 2; // bottom
          if (grayRegion[y + 1][x - 1] >= center) code |= 1 << 1; // bottom-left
          if (grayRegion[y][x - 1] >= center) code |= 1 << 0; // left
          lbpCodes.add(code);
        }
      }
      final int lbpUniqueCodes = lbpCodes.length;
      if (lbpUniqueCodes < 70) {
        debugPrint(
          '[FACE_LANDMARK] Anti-spoof rejected: low LBP diversity=$lbpUniqueCodes',
        );
        return null;
      }

      debugPrint(
        '[FACE_LANDMARK] Anti-spoof passed: colorVariance=${colorVariance.toStringAsFixed(1)} lbpCodes=$lbpUniqueCodes',
      );

      // Step 3 — Resize to 112x112
      final img.Image resized = img.copyResize(
        cropped,
        width: 112,
        height: 112,
        interpolation: img.Interpolation.linear,
      );

      // Step 3.5 — CLAHE (Contrast Limited Adaptive Histogram Equalization)
      // Replaces gamma correction - makes embeddings robust to position changes
      final img.Image gammaCorrected = _applyCLAHE(resized, clipLimit: 2.0, tileSize: 8);
      debugPrint('[FACE_LANDMARK] CLAHE applied: clipLimit=2.0');

      // Step 3.7 — Laplace sharpening
      final img.Image sharpened = img.Image(width: 112, height: 112);
      for (int y = 0; y < 112; y++) {
        for (int x = 0; x < 112; x++) {
          final center = gammaCorrected.getPixel(x, y);
          final top = gammaCorrected.getPixel(x, (y - 1).clamp(0, 111));
          final bottom = gammaCorrected.getPixel(x, (y + 1).clamp(0, 111));
          final left = gammaCorrected.getPixel((x - 1).clamp(0, 111), y);
          final right = gammaCorrected.getPixel((x + 1).clamp(0, 111), y);
          final int sR =
              (5 * center.r.toInt() -
                      top.r.toInt() -
                      bottom.r.toInt() -
                      left.r.toInt() -
                      right.r.toInt())
                  .clamp(0, 255);
          final int sG =
              (5 * center.g.toInt() -
                      top.g.toInt() -
                      bottom.g.toInt() -
                      left.g.toInt() -
                      right.g.toInt())
                  .clamp(0, 255);
          final int sB =
              (5 * center.b.toInt() -
                      top.b.toInt() -
                      bottom.b.toInt() -
                      left.b.toInt() -
                      right.b.toInt())
                  .clamp(0, 255);
          sharpened.setPixelRgb(x, y, sR, sG, sB);
        }
      }
      debugPrint('[FACE_LANDMARK] Laplace sharpening applied');

      // Step 4 — Build flat Float32List with per-image standardization
      // First pass: collect channel values
      final List<double> rVals = [];
      final List<double> gVals = [];
      final List<double> bVals = [];
      for (int y = 0; y < 112; y++) {
        for (int x = 0; x < 112; x++) {
          final pixel = sharpened.getPixel(x, y);
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
          final pixel = sharpened.getPixel(x, y);
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

  // VERIFY FACE — true median of per-frame mean scores + majority gate.
  VerificationResult verifyFace({
    required List<List<double>> liveEmbeddings,
    required List<double> storedEmbeddingA,
    required List<double> storedEmbeddingB,
    required List<double> storedEmbeddingC,
    double threshold = 0.82,
  }) {
    if (liveEmbeddings.isEmpty) {
      return VerificationResult(
        isMatch: false,
        score: 0.0,
        message: 'No frames captured',
      );
    }

    debugPrint('[FACE_VER] ═══ VERIFICATION DEBUG ═══');
    debugPrint('[FACE_VER] Live frames: ${liveEmbeddings.length}');

    // Build a single stable reference by averaging and re-normalising all 3
    // stored embeddings. This gives one reliable anchor point.
    final int dim = storedEmbeddingA.length;
    final List<double> avgStored = _l2Normalize(
      List.generate(
        dim,
        (i) => (storedEmbeddingA[i] + storedEmbeddingB[i] + storedEmbeddingC[i]) / 3.0,
      ),
    );

    // For each live frame, compute the MEAN similarity across all 4 references
    // (A, B, C individually + the averaged template).
    // Mean prevents any single embedding variant from inflating the score.
    final List<double> frameScores = [];
    for (int i = 0; i < liveEmbeddings.length; i++) {
      final double sA   = cosineSimilarity(liveEmbeddings[i], storedEmbeddingA);
      final double sB   = cosineSimilarity(liveEmbeddings[i], storedEmbeddingB);
      final double sC   = cosineSimilarity(liveEmbeddings[i], storedEmbeddingC);
      final double sAvg = cosineSimilarity(liveEmbeddings[i], avgStored);
      final double frameMean = (sA + sB + sC + sAvg) / 4.0;
      frameScores.add(frameMean);
      debugPrint(
        '[FACE_VER] Frame $i → sA=${sA.toStringAsFixed(4)} '
        'sB=${sB.toStringAsFixed(4)} sC=${sC.toStringAsFixed(4)} '
        'sAvg=${sAvg.toStringAsFixed(4)} mean=${frameMean.toStringAsFixed(4)}',
      );
    }

    // Take the TRUE MEDIAN of frame scores.
    // Median is robust: one unusually good or bad frame cannot decide the result.
    final List<double> sorted = List<double>.from(frameScores)..sort();
    final double medianScore = sorted.length.isOdd
        ? sorted[sorted.length ~/ 2]
        : (sorted[sorted.length ~/ 2 - 1] + sorted[sorted.length ~/ 2]) / 2.0;

    // Hard floor: never accept below 0.82 regardless of personal threshold.
    final double effectiveThreshold = math.max(threshold, 0.82);

    // Majority gate: more than half of frames must individually pass.
    // This blocks impostors who get lucky on one or two frames.
    final int requiredPassing = (liveEmbeddings.length / 2).ceil();
    final int passingFrames = frameScores
        .where((s) => s >= effectiveThreshold)
        .length;
    final bool majorityPass = passingFrames >= requiredPassing;

    debugPrint(
      '[FACE_VER] medianScore=${medianScore.toStringAsFixed(4)} '
      'effectiveThreshold=${effectiveThreshold.toStringAsFixed(4)} '
      'passingFrames=$passingFrames required=$requiredPassing '
      'majorityPass=$majorityPass',
    );

    if (medianScore >= effectiveThreshold && majorityPass) {
      return VerificationResult(
        isMatch: true,
        score: medianScore,
        message: 'Verified',
      );
    }

    final String message = medianScore > 0.20
        ? 'Try in better lighting'
        : 'Face not recognized';
    return VerificationResult(
      isMatch: false,
      score: medianScore,
      message: message,
    );
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

  /// CLAHE: Contrast Limited Adaptive Histogram Equalization
  /// Normalizes local contrast to make face recognition robust to lighting/position changes
  img.Image _applyCLAHE(img.Image src, {double clipLimit = 2.0, int tileSize = 8}) {
    final int width = src.width;
    final int height = src.height;
    final int tilesX = (width / tileSize).ceil();
    final int tilesY = (height / tileSize).ceil();

    // Convert to grayscale for analysis
    final List<List<double>> gray = List.generate(
      height,
      (y) => List.generate(
        width,
        (x) {
          final p = src.getPixel(x, y);
          return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        },
      ),
    );

    // Build tile histograms with clipping
    final List<List<List<int>>> tileCDFs = List.generate(
      tilesY,
      (ty) => List.generate(
        tilesX,
        (tx) {
          final List<int> hist = List.filled(256, 0);
          final int startY = ty * tileSize;
          final int startX = tx * tileSize;
          final int endY = math.min(startY + tileSize, height);
          final int endX = math.min(startX + tileSize, width);

          // Build histogram
          for (int y = startY; y < endY; y++) {
            for (int x = startX; x < endX; x++) {
              final int bin = gray[y][x].round().clamp(0, 255);
              hist[bin]++;
            }
          }

          // Clip histogram
          final int totalPixels = (endY - startY) * (endX - startX);
          final int clipLimitPixels = ((clipLimit * totalPixels) / 256).round();
          int excess = 0;
          for (int i = 0; i < 256; i++) {
            if (hist[i] > clipLimitPixels) {
              excess += hist[i] - clipLimitPixels;
              hist[i] = clipLimitPixels;
            }
          }
          final int redistribution = excess ~/ 256;
          for (int i = 0; i < 256; i++) {
            hist[i] += redistribution;
          }

          // Build CDF
          final List<int> cdf = List.filled(256, 0);
          cdf[0] = hist[0];
          for (int i = 1; i < 256; i++) {
            cdf[i] = cdf[i - 1] + hist[i];
          }
          final int total = cdf[255];
          if (total > 0) {
            for (int i = 0; i < 256; i++) {
              cdf[i] = ((cdf[i] * 255) ~/ total).clamp(0, 255);
            }
          }
          return cdf;
        },
      ),
    );

    // Apply with bilinear interpolation
    final img.Image result = img.Image(width: width, height: height);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final double tileX = (x / tileSize) - 0.5;
        final double tileY = (y / tileSize) - 0.5;
        final int tx = tileX.floor().clamp(0, tilesX - 1);
        final int ty = tileY.floor().clamp(0, tilesY - 1);
        final int txNext = (tx + 1).clamp(0, tilesX - 1);
        final int tyNext = (ty + 1).clamp(0, tilesY - 1);
        final double fx = (tileX - tx).clamp(0.0, 1.0);
        final double fy = (tileY - ty).clamp(0.0, 1.0);

        final int grayVal = gray[y][x].round().clamp(0, 255);
        final int v00 = tileCDFs[ty][tx][grayVal];
        final int v01 = tileCDFs[ty][txNext][grayVal];
        final int v10 = tileCDFs[tyNext][tx][grayVal];
        final int v11 = tileCDFs[tyNext][txNext][grayVal];

        final double v0 = v00 * (1 - fx) + v01 * fx;
        final double v1 = v10 * (1 - fx) + v11 * fx;
        final int newGray = (v0 * (1 - fy) + v1 * fy).round().clamp(0, 255);

        final p = src.getPixel(x, y);
        final double factor = newGray / (gray[y][x] + 1e-6);
        result.setPixelRgb(
          x, y,
          (p.r * factor).round().clamp(0, 255),
          (p.g * factor).round().clamp(0, 255),
          (p.b * factor).round().clamp(0, 255),
        );
      }
    }
    return result;
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
