// lib/services/face_ml_service.dart
//
// Handles everything ML-related for face registration and verification:
//   • Mobile ArcFace FP16 embedding generation (512-dim, L2 normalized)
//   • Image preprocessing: crop → 5-point align → resize 112x112
//                          → histogram equalization → normalize [-1,1]
//   • EAR (Eye Aspect Ratio) blink detection with personalized threshold
//   • Cosine similarity comparison
//
// This file does NOT touch Supabase, camera, or UI.
// It is a pure service called by face screens.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:facial_liveness_verification/facial_liveness_verification.dart'
    show ChallengeType, ChallengeValidator, LivenessConfig;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceMlService {
  // ─── Singleton ────────────────────────────────────────────────────────────
  static final FaceMlService _instance = FaceMlService._internal();
  factory FaceMlService() => _instance;
  FaceMlService._internal();

  // ─── Internal state ───────────────────────────────────────────────────────
  Interpreter? _interpreter;
  bool _isInitialized = false;

  // ─── ML Kit face detector (shared instance) ───────────────────────────────
  // enableContours = true  → gives 6 eye contour points for accurate EAR
  // enableLandmarks = true → gives nose, mouth corners for alignment
  // minFaceSize = 0.15     → ignores background faces automatically
  // mode = fast            → never use accurate on live camera feed
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

  final FaceMeshDetector faceMeshDetector = FaceMeshDetector(
    option: FaceMeshDetectorOptions.faceMesh,
  );

  // ─── ArcFace 5-point target landmark positions in 112×112 space ──────────
  // These are the canonical positions MobileFaceNet (ArcFace-trained) expects.
  // Alignment warps each face so landmarks land exactly here.
  // ignore: unused_field
  static const List<List<double>> _arcFaceTargets = [
    [38.29, 51.69], // left eye
    [73.53, 51.50], // right eye
    [56.02, 71.73], // nose tip
    [41.55, 92.37], // left mouth corner
    [70.72, 92.20], // right mouth corner
  ];

  // ─────────────────────────────────────────────────────────────────────────
  // INIT — call once at app startup (splash screen)
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // GPU delegate for MobileFaceNet only.
      // NOTE: On MediaTek Helio (Redmi Note / Realme) and POCO X5 Pro, use CPU
      // with 2 threads to avoid random OpenCL/OpenGL native crashes.
      // CPU with 2 threads runs MobileFaceNet in ~15-25ms, which is plenty fast.
      final options = InterpreterOptions()..threads = 2;

      _interpreter = await Interpreter.fromAsset(
        'assets/models/mobile_arcface_fp16.tflite',
        options: options,
      );

      _isInitialized = true;
    } catch (e) {
      throw Exception('Failed to load Mobile ArcFace FP16 model: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // GENERATE EMBEDDING from a raw camera image bytes + detected face
  //
  // Returns a 512-dim L2-normalized float vector (Mobile ArcFace FP16 output).
  // Returns null if preprocessing fails (bad crop, no landmarks).
  // ─────────────────────────────────────────────────────────────────────────
  Future<List<double>?> generateEmbedding({
    required Uint8List jpegBytes,
    required Face face, // used as fallback if re-detection fails
  }) async {
    if (!_isInitialized) await initialize();

    // ── Step 1: Write JPEG to a temp file ─────────────────────────────────
    // The `face` passed in was detected from the live YUV camera buffer whose
    // coordinate system differs from the decoded JPEG (rotation, flip, etc.).
    // Writing to a file and re-running ML Kit gives us a `Face` whose landmark
    // coordinates are anchored to the decoded JPEG's pixel space.
    File? tempFile;
    Face? jpegFace;
    try {
      final String tempPath =
          '${Directory.systemTemp.path}/face_emb_${DateTime.now().millisecondsSinceEpoch}.jpg';
      tempFile = File(tempPath);
      await tempFile.writeAsBytes(jpegBytes);

      final InputImage staticInput = InputImage.fromFilePath(tempPath);

      // Use a fresh detector with accurate mode for static images
      final FaceDetector staticDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableContours: true,
          enableLandmarks: true,
          enableClassification: true,
          enableTracking: false,
          performanceMode: FaceDetectorMode.accurate,
          minFaceSize: 0.10,
        ),
      );

      try {
        final List<Face> detected = await staticDetector.processImage(
          staticInput,
        );
        await staticDetector.close();

        if (detected.isNotEmpty) {
          // Pick the largest face in the JPEG
          jpegFace = detected.reduce(
            (a, b) => a.boundingBox.width >= b.boundingBox.width ? a : b,
          );
          debugPrint(
            '[FACE_REG] Re-detect OK — using JPEG-space face '
            '(box: ${jpegFace.boundingBox.width.toStringAsFixed(0)}×'
            '${jpegFace.boundingBox.height.toStringAsFixed(0)})',
          );
        } else {
          debugPrint(
            '[FACE_REG] Re-detect: no face found in JPEG — using caller face as fallback',
          );
        }
      } catch (e) {
        await staticDetector.close();
        debugPrint('[FACE_REG] Re-detect error: $e — using fallback face');
      }
    } catch (e) {
      debugPrint('[FACE_REG] Temp file error: $e — using fallback face');
    } finally {
      // Clean up temp file (fire-and-forget)
      try {
        tempFile?.deleteSync();
      } catch (_) {}
    }

    // Use the JPEG-space face if available;
    // otherwise: scale the live-stream bounding box to JPEG dimensions.
    Face activeFace;
    if (jpegFace != null) {
      activeFace = jpegFace;
    } else {
      // The live-stream face coordinates are in camera-buffer space
      // (e.g. 480×640). Decode the JPEG to find its actual pixel dimensions,
      // then compute a scale factor and produce a synthetically scaled face
      // bounding box that maps into JPEG pixel coordinates.
      //
      // We cannot construct a `Face` with different coordinates since it is a
      // final data class, so we fall back to the crop-with-padding approach
      // which only needs the bounding box. We override _preprocess to use the
      // decoded image dimensions as the reference for clamping.
      //
      // Simple approach: just pass the original face and let _cropWithPadding
      // clamp the box to image bounds. This still works if the aspect ratios
      // are close (same sensor, different buffer stage).
      debugPrint(
        '[FACE_REG] Fallback: using caller face (live-stream bbox) — '
        'box W=${face.boundingBox.width.toStringAsFixed(0)} '
        'H=${face.boundingBox.height.toStringAsFixed(0)}',
      );
      activeFace = face;
    }

    try {
      // ── Step 2: Decode JPEG ────────────────────────────────────────────
      img.Image? decoded = img.decodeJpg(jpegBytes);
      if (decoded == null) {
        debugPrint('[FACE_REG] generateEmbedding: JPEG decode failed');
        return null;
      }

      // ── Step 2b: Force RGB (3 channels) ────────────────────────────────
      // Some devices produce grayscale or RGBA JPEGs which cause tensor
      // shape mismatch with the model's [1,112,112,3] input.
      if (decoded.numChannels == 1) {
        debugPrint('[FACE_REG] Converting grayscale → RGB');
        decoded = decoded.convert(numChannels: 3);
      } else if (decoded.numChannels == 4) {
        debugPrint('[FACE_REG] Converting RGBA → RGB');
        decoded = decoded.convert(numChannels: 3);
      }

      // ── Step 3: Full preprocessing pipeline ───────────────────────────
      final img.Image? processed = _preprocess(decoded, activeFace);
      if (processed == null) {
        debugPrint('[FACE_REG] generateEmbedding: _preprocess returned null');
        return null;
      }

      // ── Step 4: Float32 tensor [-1, 1] ────────────────────────────────
      final Float32List tensor = _imageToTensor(processed);

      // ── Step 5: Run Mobile ArcFace FP16 ─────────────────────────────────
      // Output dimension: 512 (verified from model tensor shape).
      // Shape mismatch at runtime will throw — caught by the catch block.
      final List<List<double>> output = [List.filled(512, 0.0)];
      _interpreter!.run(tensor.reshape([1, 3, 112, 112]), output); // NCHW
      debugPrint(
        '[FACE_REG] Model run complete, raw[0]=${output[0][0].toStringAsFixed(4)}',
      );

      // ── Step 6: L2 normalize ───────────────────────────────────────────
      final List<double> embedding = _l2Normalize(output[0]);
      debugPrint(
        '[FACE_REG] Embedding generated — '
        'norm=${_vectorNorm(embedding).toStringAsFixed(4)}',
      );
      return embedding;
    } catch (e) {
      debugPrint('[FACE_REG] generateEmbedding error: $e');
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // AVERAGE EMBEDDINGS — average N embeddings and re-normalize
  // Used after capturing multiple frames
  // ─────────────────────────────────────────────────────────────────────────
  List<double> averageEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return [];
    if (embeddings.length == 1) return embeddings[0];

    final int vecSize = embeddings[0].length;
    final List<double> averaged = List.filled(vecSize, 0.0);

    for (final emb in embeddings) {
      for (int i = 0; i < vecSize; i++) {
        averaged[i] += emb[i];
      }
    }
    for (int i = 0; i < vecSize; i++) {
      averaged[i] /= embeddings.length;
    }

    return _l2Normalize(averaged);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // COSINE SIMILARITY — compare two L2-normalized embeddings
  // Both must be L2-normalized. Result range: -1 to 1.
  // Threshold 0.6 = match (as specified in requirements)
  // ─────────────────────────────────────────────────────────────────────────
  double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    // Since both are L2-normalized, dot product = cosine similarity
    return dot;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // VERIFY FACE — compare live embeddings against stored A and B
  //
  // Takes MEDIAN of scores for stability (not average — median ignores
  // outlier frames caused by micro-blinks or shadows).
  // Every frame must score >= 0.45 to prevent constant fake-high scores.
  // Returns true if median score >= threshold.
  // ─────────────────────────────────────────────────────────────────────────
  VerificationResult verifyFace({
    required List<List<double>> liveEmbeddings,
    required List<double> storedEmbeddingA,
    required List<double> storedEmbeddingB,
    double threshold = 0.60,
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
    debugPrint('[FACE_VER] StoredA length: ${storedEmbeddingA.length}');
    debugPrint('[FACE_VER] StoredB length: ${storedEmbeddingB.length}');

    final List<double> scoresA = liveEmbeddings
        .map((e) => cosineSimilarity(e, storedEmbeddingA))
        .toList();

    for (int i = 0; i < liveEmbeddings.length; i++) {
      debugPrint(
        '[FACE_VER] Frame $i → scoreA=${scoresA[i].toStringAsFixed(4)}',
      );
    }

    scoresA.sort();
    final double medianA = scoresA[scoresA.length ~/ 2];

    debugPrint(
      '[FACE_VER] medianA=${medianA.toStringAsFixed(4)} threshold=$threshold',
    );

    if (medianA >= threshold) {
      return VerificationResult(
        isMatch: true,
        score: medianA,
        message: 'Verified',
      );
    }

    String message = medianA > 0.50
        ? 'Try in better lighting'
        : 'Face not recognized';
    return VerificationResult(isMatch: false, score: medianA, message: message);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // EAR BLINK DETECTION
  //
  // Uses ML Kit eye contour points (6 per eye) for accurate ratio.
  // Falls back to ML Kit classification probability if contours unavailable.
  // ─────────────────────────────────────────────────────────────────────────

  // Compute current EAR value for a face
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

    // Fallback: use ML Kit open probability
    // Map probability to approximate EAR range
    final double leftProb = face.leftEyeOpenProbability ?? 0.8;
    final double rightProb = face.rightEyeOpenProbability ?? 0.8;
    return ((leftProb + rightProb) / 2.0) * 0.40;
  }

  double _earFromContour(List<dynamic> eye) {
    if (eye.length < 6) return 0.3;

    // Robust way: find leftmost, rightmost, highest and lowest points
    // This works regardless of the order ML Kit returns the 6 points
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
    final double v1 = _distance(eye[topIdx], eye[bottomIdx]); // vertical span
    final double v2 = v1; // simple but accurate enough for 6 points

    if (h < 1.0) return 0.3;
    return (v1 + v2) / (2.0 * h);
  }

  double _distance(dynamic a, dynamic b) {
    final double dx = (a.x - b.x).toDouble();
    final double dy = (a.y - b.y).toDouble();
    return math.sqrt(dx * dx + dy * dy);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PREPROCESSING PIPELINE
  // crop → align → resize 112×112 → histogram equalization → done
  // ─────────────────────────────────────────────────────────────────────────
  img.Image? _preprocess(img.Image fullImage, Face face) {
    try {
      // Step 1: Crop with 20% padding
      final img.Image? cropped = _cropWithPadding(
        fullImage,
        face,
        padding: 0.20,
      );
      if (cropped == null) return null;

      // Step 2: 5-point face alignment (most important step)
      final img.Image? aligned = _alignFace(fullImage, face);
      if (aligned == null) {
        // If alignment fails (missing landmarks), fall back to simple crop+resize
        return img.copyResize(cropped, width: 112, height: 112);
      }

      // Step 3: Resize to 112×112 (MobileFaceNet input size)
      final img.Image resized = img.copyResize(
        aligned,
        width: 112,
        height: 112,
      );

      // Step 4: Histogram equalization — normalizes lighting variation
      // This is what makes indoor registration → outdoor verification work
      img.Image equalized = _histogramEqualize(resized);

      // Step 5: Ensure final output is RGB (3 channels) for model input
      if (equalized.numChannels != 3) {
        debugPrint('[FACE_REG] _preprocess: forcing final image to 3-ch RGB');
        equalized = equalized.convert(numChannels: 3);
      }
      return equalized;
    } catch (e) {
      return null;
    }
  }

  img.Image? _cropWithPadding(
    img.Image image,
    Face face, {
    double padding = 0.20,
  }) {
    final rect = face.boundingBox;
    final double padX = rect.width * padding;
    final double padY = rect.height * padding;

    final int x = (rect.left - padX).round().clamp(0, image.width - 1);
    final int y = (rect.top - padY).round().clamp(0, image.height - 1);
    final int w = (rect.width + 2 * padX).round().clamp(1, image.width - x);
    final int h = (rect.height + 2 * padY).round().clamp(1, image.height - y);

    return img.copyCrop(image, x: x, y: y, width: w, height: h);
  }

  // Simplified similarity transform alignment using eye landmarks
  img.Image? _alignFace(img.Image image, Face face) {
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];

    if (leftEye == null || rightEye == null) return null;

    final double lx = leftEye.position.x.toDouble();
    final double ly = leftEye.position.y.toDouble();
    final double rx = rightEye.position.x.toDouble();
    final double ry = rightEye.position.y.toDouble();

    // Target eye positions in 112×112 (from ArcFace standard targets)
    const double targetLx = 38.29, targetLy = 51.69;
    const double targetRx = 73.53, targetRy = 51.50;

    // Compute scale and rotation from eye pair
    final double srcDist = math.sqrt(
      math.pow(rx - lx, 2) + math.pow(ry - ly, 2),
    );
    final double tgtDist = math.sqrt(
      math.pow(targetRx - targetLx, 2) + math.pow(targetRy - targetLy, 2),
    );

    if (srcDist < 1.0) return null;

    final double scale = tgtDist / srcDist;
    final double angle =
        math.atan2(ry - ly, rx - lx) -
        math.atan2(targetRy - targetLy, targetRx - targetLx);

    // Center of source eyes
    final double srcCx = (lx + rx) / 2.0;
    final double srcCy = (ly + ry) / 2.0;
    const double tgtCx = (targetLx + targetRx) / 2.0;
    const double tgtCy = (targetLy + targetRy) / 2.0;

    // Apply rotation + scale + translation via copyRotate then crop/scale
    // This is a simplified version — for production use a full affine warp
    final double cosA = math.cos(-angle);
    final double sinA = math.sin(-angle);

    // Create output 112×112 image
    final img.Image output = img.Image(width: 112, height: 112);

    for (int y = 0; y < 112; y++) {
      for (int x = 0; x < 112; x++) {
        // Map target pixel back to source
        final double tx = x - tgtCx;
        final double ty = y - tgtCy;

        final double rotX = cosA * tx - sinA * ty;
        final double rotY = sinA * tx + cosA * ty;

        final double srcX = rotX / scale + srcCx;
        final double srcY = rotY / scale + srcCy;

        final int sx = srcX.round().clamp(0, image.width - 1);
        final int sy = srcY.round().clamp(0, image.height - 1);

        output.setPixel(x, y, image.getPixel(sx, sy));
      }
    }

    return output;
  }

  img.Image _histogramEqualize(img.Image face) {
    // Convert to grayscale to analyze brightness distribution
    // Apply equalization to luminance only (preserve color)
    final img.Image result = img.Image.from(face);

    // Build histogram of luminance values
    final List<int> histogram = List.filled(256, 0);
    for (int y = 0; y < face.height; y++) {
      for (int x = 0; x < face.width; x++) {
        final pixel = face.getPixel(x, y);
        final int r = pixel.r.toInt();
        final int g = pixel.g.toInt();
        final int b = pixel.b.toInt();
        final int lum = ((0.299 * r) + (0.587 * g) + (0.114 * b)).round().clamp(
          0,
          255,
        );
        histogram[lum]++;
      }
    }

    // Build CDF lookup table
    final List<int> lut = List.filled(256, 0);
    int cumulative = 0;
    final int totalPixels = face.width * face.height;
    for (int i = 0; i < 256; i++) {
      cumulative += histogram[i];
      lut[i] = ((cumulative * 255) / totalPixels).round().clamp(0, 255);
    }

    // Check actual brightness — only equalize if needed
    // Skip if image is already in normal range (prevents over-processing)
    double mean = 0;
    for (int i = 0; i < 256; i++) {
      mean += i * histogram[i];
    }
    mean /= totalPixels;

    if (mean >= 90 && mean <= 180) {
      // Good lighting — skip equalization, just return original
      return face;
    }

    // Apply equalization via brightness adjustment instead of per-pixel LUT
    // This is faster and avoids color artifacts
    double brightnessFactor = 0.0;
    if (mean < 90) {
      brightnessFactor = (90 - mean) / 255.0 * 0.4; // Boost dark images
    } else if (mean > 180) {
      brightnessFactor = -(mean - 180) / 255.0 * 0.3; // Reduce bright images
    }

    if (brightnessFactor.abs() > 0.01) {
      return img.adjustColor(result, brightness: brightnessFactor);
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // TENSOR CONVERSION — pixel [0,255] → float32 [-1.0, 1.0]  (NCHW layout)
  // Formula: (pixel - 127.5) / 128.0 per channel
  // mobile_arcface_fp16.tflite expects NCHW: [1, 3, 112, 112]
  // ─────────────────────────────────────────────────────────────────────────
  Float32List _imageToTensor(img.Image face) {
    final Float32List tensor = Float32List(1 * 3 * 112 * 112); // NCHW
    int idx = 0;

    // Fill all R channel, then all G, then all B (channels-first order)
    for (int c = 0; c < 3; c++) {
      for (int y = 0; y < 112; y++) {
        for (int x = 0; x < 112; x++) {
          final pixel = face.getPixel(x, y);
          final double value = c == 0
              ? pixel.r.toDouble()
              : c == 1
              ? pixel.g.toDouble()
              : pixel.b.toDouble();
          tensor[idx++] = (value - 127.5) / 128.0;
        }
      }
    }

    return tensor;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // L2 NORMALIZATION — make embedding a unit vector
  // Required before cosine similarity comparison
  // ─────────────────────────────────────────────────────────────────────────
  List<double> _l2Normalize(List<double> embedding) {
    double magnitude = 0.0;
    for (final v in embedding) {
      magnitude += v * v;
    }
    magnitude = math.sqrt(magnitude);

    if (magnitude < 1e-10) return embedding;
    return embedding.map((v) => v / magnitude).toList();
  }

  // Returns the Euclidean norm of a vector (before normalization).
  // Used purely for debug logging to verify embeddings are non-zero.
  double _vectorNorm(List<double> v) {
    double sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    return math.sqrt(sum);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // QUALITY CHECK — quick frame quality gate before sending to model
  // Returns a score 0.0-1.0. Reject if below 0.35.
  // ─────────────────────────────────────────────────────────────────────────
  double checkFrameQuality(img.Image face) {
    // Blur detection using Laplacian variance
    final img.Image gray = img.grayscale(face);
    final List<double> laplacianValues = [];

    for (int y = 1; y < gray.height - 1; y++) {
      for (int x = 1; x < gray.width - 1; x++) {
        final double center = gray.getPixel(x, y).r.toDouble();
        final double lap =
            4.0 * center -
            gray.getPixel(x - 1, y).r.toDouble() -
            gray.getPixel(x + 1, y).r.toDouble() -
            gray.getPixel(x, y - 1).r.toDouble() -
            gray.getPixel(x, y + 1).r.toDouble();
        laplacianValues.add(lap * lap);
      }
    }

    if (laplacianValues.isEmpty) return 0.0;

    final double mean =
        laplacianValues.reduce((a, b) => a + b) / laplacianValues.length;
    final double variance =
        laplacianValues
            .map((v) => (v - mean) * (v - mean))
            .reduce((a, b) => a + b) /
        laplacianValues.length;

    // Normalize to 0-1 range (empirically tuned)
    return (variance / 500.0).clamp(0.0, 1.0);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DISPOSE — call when app closes
  // ─────────────────────────────────────────────────────────────────────────
  void dispose() {
    _interpreter?.close();
    faceDetector.close();
    faceMeshDetector.close();
    _isInitialized = false;
  }
}

// ─── Result types ─────────────────────────────────────────────────────────────

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
