// lib/services/face_landmark_service.dart
//
// Generates face embeddings by calling a remote FastAPI service that runs
// InsightFace buffalo_l (ArcFace, 512-dim embeddings).
//
// Public API is identical to the old TFLite-based implementation so all
// screens continue to work without modification.

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'package:shared_preferences/shared_preferences.dart';

class FaceLandmarkService {
  static final FaceLandmarkService _instance = FaceLandmarkService._internal();
  factory FaceLandmarkService() => _instance;
  FaceLandmarkService._internal();

  /// Base URL of the FastAPI face service.
  /// Read from .env `FACE_API_URL`, defaults to Android-emulator loopback.
  late final String _apiUrl;

  bool _isInitialized = false;

  // Public API - matches old FaceMlService
  Future<void> initialize() async {
    if (_isInitialized) return;

    _apiUrl = dotenv.env['FACE_API_URL'] ?? 'http://10.0.2.2:8000';
    _isInitialized = true;
    debugPrint('[FACE_LANDMARK] Initialized — API URL: $_apiUrl');
  }

  // ─── GENERATE EMBEDDING ─────────────────────────────────────────────────
  //
  // Sends raw JPEG bytes to the FastAPI /api/embed endpoint.
  // Returns the 512-dim L2-normalised ArcFace embedding, or null on failure.
  //
  // Matches old method signature exactly — `face` parameter is kept for
  // backward compatibility but is NOT used (InsightFace does its own
  // detection + alignment server-side).
  // ────────────────────────────────────────────────────────────────────────
  Future<List<double>?> generateEmbedding({
    required Uint8List jpegBytes,
    required dynamic face, // kept for API compat — unused
  }) async {
    if (!_isInitialized) await initialize();

    try {
      debugPrint(
        '[FACE_LANDMARK] Sending ${jpegBytes.length} bytes to $_apiUrl/api/embed',
      );

      final uri = Uri.parse('$_apiUrl/api/embed');

      final request = http.MultipartRequest('POST', uri)
        ..files.add(
          http.MultipartFile.fromBytes(
            'images',
            jpegBytes,
            filename: 'frame.jpg',
          ),
        );

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 15),
      );

      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200) {
        debugPrint('[FACE_LANDMARK] STATUS=${response.statusCode}');
        debugPrint('[FACE_LANDMARK] HEADERS=${response.headers}');
        debugPrint(
          '[FACE_LANDMARK] BODY=${response.body.substring(0, response.body.length > 500 ? 500 : response.body.length)}',
        );
        return null;
      }

      final Map<String, dynamic> json = jsonDecode(response.body);
      final List<dynamic> embeddings = json['embeddings'];

      if (embeddings.isEmpty || embeddings[0] == null) {
        debugPrint('[FACE_LANDMARK] No face detected by API');
        // Log quality info even on failure
        final List<dynamic>? qualityList = json['quality'] as List<dynamic>?;
        if (qualityList != null && qualityList.isNotEmpty) {
          final q = qualityList[0] as Map<String, dynamic>;
          debugPrint(
            '[FACE_LANDMARK] QUALITY: passed=${q['passed']} '
            'blur=${q['blur_score']} reasons=${q['reasons']}',
          );
        }
        return null;
      }

      final List<double> embedding = (embeddings[0] as List)
          .map((e) => (e as num).toDouble())
          .toList();

      debugPrint(
        '[FACE_LANDMARK] Received ${embedding.length}-dim embedding',
      );

      // Log quality diagnostics from backend
      final List<dynamic>? qualityList = json['quality'] as List<dynamic>?;
      if (qualityList != null && qualityList.isNotEmpty) {
        final q = qualityList[0] as Map<String, dynamic>;
        debugPrint(
          '[FACE_LANDMARK] QUALITY: passed=${q['passed']} '
          'blur=${q['blur_score']} faceArea=${q['face_area']} '
          'yaw=${q['yaw']} pitch=${q['pitch']} '
          'reasons=${q['reasons']}',
        );
      }

      return embedding;
    } catch (e) {
      debugPrint('[FACE_LANDMARK] generateEmbedding error: $e');
      return null;
    }
  }

  // ─── GENERATE EMBEDDING BATCH ───────────────────────────────────────────
  //
  // Sends all JPEG frames in a single multipart POST to /api/embed.
  // Eliminates N-1 network round trips compared to calling generateEmbedding
  // individually. Returns a list of nullable embeddings — null for frames
  // where no face was detected by the backend.
  // ────────────────────────────────────────────────────────────────────────
  Future<List<List<double>?>> generateEmbeddingBatch({
    required List<Uint8List> jpegBytesList,
  }) async {
    // Delegate to the quality-aware version and strip quality data
    final results = await generateEmbeddingBatchWithQuality(
      jpegBytesList: jpegBytesList,
    );
    return results.map((r) => r.embedding).toList();
  }

  // ─── GENERATE EMBEDDING BATCH WITH QUALITY ──────────────────────────────
  //
  // Same as generateEmbeddingBatch but returns structured BatchEmbeddingResult
  // with quality scores for ranking and filtering.
  // ────────────────────────────────────────────────────────────────────────
  Future<List<BatchEmbeddingResult>> generateEmbeddingBatchWithQuality({
    required List<Uint8List> jpegBytesList,
  }) async {
    if (!_isInitialized) await initialize();

    try {
      debugPrint(
        '[FACE_LANDMARK] Batch sending ${jpegBytesList.length} frames to $_apiUrl/api/embed',
      );

      final Stopwatch sw = Stopwatch()..start();

      final uri = Uri.parse('$_apiUrl/api/embed');
      final request = http.MultipartRequest('POST', uri);

      for (int i = 0; i < jpegBytesList.length; i++) {
        request.files.add(
          http.MultipartFile.fromBytes(
            'images',
            jpegBytesList[i],
            filename: 'frame_$i.jpg',
          ),
        );
      }

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );

      final response = await http.Response.fromStream(streamedResponse);

      sw.stop();
      debugPrint('[CAPTURE] API Duration: ${sw.elapsedMilliseconds}ms');

      if (response.statusCode != 200) {
        debugPrint(
          '[FACE_LANDMARK] Batch API error ${response.statusCode}: ${response.body.substring(0, response.body.length > 300 ? 300 : response.body.length)}',
        );
        return List.generate(
          jpegBytesList.length,
          (_) => const BatchEmbeddingResult(
            embedding: null,
            qualityPassed: false,
            qualityScore: 0.0,
            rejectionReason: 'API error',
          ),
        );
      }

      final Map<String, dynamic> json = jsonDecode(response.body);
      final List<dynamic> embeddings = json['embeddings'];
      final List<dynamic>? qualityList = json['quality'] as List<dynamic>?;

      final List<BatchEmbeddingResult> result = [];
      for (int i = 0; i < embeddings.length; i++) {
        final Map<String, dynamic>? q = (qualityList != null && i < qualityList.length)
            ? qualityList[i] as Map<String, dynamic>
            : null;

        final bool passed = q?['passed'] as bool? ?? (embeddings[i] != null);
        final double blurScore = (q?['blur_score'] as num?)?.toDouble() ?? 0.0;
        final double faceArea = (q?['face_area'] as num?)?.toDouble() ?? 0.0;
        // Quality score: higher = better. Combine blur (inverted) + face area.
        // blur_score is typically 0-1 where lower is sharper; invert it.
        final double qualityScore = passed
            ? ((1.0 - blurScore.clamp(0.0, 1.0)) * 0.6 + faceArea.clamp(0.0, 1.0) * 0.4)
            : 0.0;

        if (embeddings[i] == null) {
          debugPrint('[CAPTURE] Frame Rejected | frame=$i reason=no_face_detected');
          result.add(BatchEmbeddingResult(
            embedding: null,
            qualityPassed: false,
            qualityScore: 0.0,
            rejectionReason: 'No face detected',
          ));
        } else if (!passed) {
          final List<dynamic>? reasons = q?['reasons'] as List<dynamic>?;
          final String reason = reasons?.join(', ') ?? 'Quality check failed';
          debugPrint('[CAPTURE] Frame Rejected | frame=$i reason=$reason');
          result.add(BatchEmbeddingResult(
            embedding: null,
            qualityPassed: false,
            qualityScore: 0.0,
            rejectionReason: reason,
          ));
        } else {
          final emb = (embeddings[i] as List)
              .map((e) => (e as num).toDouble())
              .toList();
          debugPrint('[CAPTURE] Frame Accepted | frame=$i qualityScore=${qualityScore.toStringAsFixed(3)}');
          result.add(BatchEmbeddingResult(
            embedding: emb,
            qualityPassed: true,
            qualityScore: qualityScore,
          ));
        }

        if (q != null) {
          debugPrint(
            '[FACE_LANDMARK] Batch frame $i QUALITY: passed=${q['passed']} '
            'blur=${q['blur_score']} faceArea=${q['face_area']} '
            'yaw=${q['yaw']} pitch=${q['pitch']}',
          );
        }
      }

      final int validCount = result.where((r) => r.embedding != null).length;
      debugPrint(
        '[FACE_LANDMARK] Batch complete: $validCount/${jpegBytesList.length} valid embeddings',
      );
      return result;
    } catch (e) {
      debugPrint('[FACE_LANDMARK] generateEmbeddingBatch error: $e');
      return List.generate(
        jpegBytesList.length,
        (_) => BatchEmbeddingResult(
          embedding: null,
          qualityPassed: false,
          qualityScore: 0.0,
          rejectionReason: e.toString(),
        ),
      );
    }
  }

  // ─── PING BACKEND ────────────────────────────────────────────────────────
  //
  // Hits /health to wake the Hugging Face Space before registration begins.
  // Call fire-and-forget during camera initialization so the model is warm
  // by the time the user finishes the blink challenge and captures frames.
  // ────────────────────────────────────────────────────────────────────────
  Future<void> pingBackend() async {
    if (!_isInitialized) await initialize();
    try {
      final uri = Uri.parse('$_apiUrl/health');
      await http.get(uri).timeout(const Duration(seconds: 10));
      debugPrint('[FACE_LANDMARK] Backend ping successful');
    } catch (e) {
      debugPrint('[FACE_LANDMARK] Backend ping failed (non-fatal): $e');
    }
  }

  // ─── AVERAGE EMBEDDINGS ─────────────────────────────────────────────────
  // Pure math — unchanged from old implementation.
  // Works with any embedding dimension (192 or 512).
  // ────────────────────────────────────────────────────────────────────────
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
      '[FACE_LANDMARK] Averaged embedding first 5: ${normalized.sublist(0, math.min(5, normalized.length)).map((v) => v.toStringAsFixed(4)).join(', ')}',
    );

    return normalized;
  }

  // ─── COSINE SIMILARITY ──────────────────────────────────────────────────
  // Pure math — unchanged.
  // ────────────────────────────────────────────────────────────────────────
  double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }

  // ─── VERIFY FACE ───────────────────────────────────────────────────────
  // Master-embedding primary scoring with top-3 aggregation.
  //
  // If masterEmbedding (face_embedding) is provided, it is used as the
  // primary comparison target.  A/B/C scores are logged as diagnostics.
  //
  // Aggregation: sort all frame scores descending → take best 3 → average.
  // Threshold: clamped to min(storedThreshold, 0.76).
  // ────────────────────────────────────────────────────────────────────────
  VerificationResult verifyFace({
    required List<List<double>> liveEmbeddings,
    required List<double> storedEmbeddingA,
    required List<double> storedEmbeddingB,
    required List<double> storedEmbeddingC,
    List<double>? masterEmbedding,
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
    debugPrint('[FACE_VER] masterEmbedding present: ${masterEmbedding != null}');

    // Clamp threshold: never exceed 0.76 (temporary safeguard)
    final double effectiveThreshold = math.max(threshold, 0.65);
    debugPrint('[FACE_VER] thresholdUsed=${effectiveThreshold.toStringAsFixed(4)} (stored=${threshold.toStringAsFixed(4)}, floor=0.65)');

    // Determine primary template
    final bool useMaster = masterEmbedding != null && masterEmbedding.isNotEmpty;

    // Build on-the-fly average of A/B/C for fallback / diagnostics
    final int dim = storedEmbeddingA.length;
    final List<double> avgStored = _l2Normalize(
      List.generate(
        dim,
        (i) =>
            (storedEmbeddingA[i] + storedEmbeddingB[i] + storedEmbeddingC[i]) /
            3.0,
      ),
    );

    // Score each live frame
    final List<double> masterScores = []; // primary: face_embedding
    final List<double> abcMeanScores = []; // diagnostic: mean(A,B,C,avg)

    for (int i = 0; i < liveEmbeddings.length; i++) {
      final live = liveEmbeddings[i];

      // Diagnostic A/B/C scores (always logged)
      final double sA = cosineSimilarity(live, storedEmbeddingA);
      final double sB = cosineSimilarity(live, storedEmbeddingB);
      final double sC = cosineSimilarity(live, storedEmbeddingC);
      final double sAvg = cosineSimilarity(live, avgStored);
      final double abcMean = (sA + sB + sC + sAvg) / 4.0;
      abcMeanScores.add(abcMean);

      // Primary master score
      final double mScore = useMaster
          ? cosineSimilarity(live, masterEmbedding)
          : abcMean; // fallback if no master
      masterScores.add(mScore);

      debugPrint(
        '[FACE_VER] Frame $i → masterScore=${mScore.toStringAsFixed(4)} '
        'sA=${sA.toStringAsFixed(4)} sB=${sB.toStringAsFixed(4)} '
        'sC=${sC.toStringAsFixed(4)} sAvg=${sAvg.toStringAsFixed(4)} '
        'abcMean=${abcMean.toStringAsFixed(4)}',
      );
    }

    // Top-3 aggregation: sort descending, take best 3, average
    final List<double> sorted = List<double>.from(masterScores)
      ..sort((a, b) => b.compareTo(a)); // descending
    final int topN = math.min(3, sorted.length);
    final double top3Average =
        sorted.sublist(0, topN).reduce((a, b) => a + b) / topN;

    debugPrint(
      '[FACE_VER] allScores=${sorted.map((s) => s.toStringAsFixed(4)).join(',')}',
    );
    debugPrint(
      '[FACE_VER] top3Average=${top3Average.toStringAsFixed(4)}',
    );
    debugPrint(
      '[FACE_VER] thresholdUsed=${effectiveThreshold.toStringAsFixed(4)}',
    );

    if (top3Average >= effectiveThreshold) {
      return VerificationResult(
        isMatch: true,
        score: top3Average,
        message: 'Verified',
      );
    }

    final String message = top3Average > 0.20
        ? 'Try in better lighting'
        : 'Face not recognized';
    return VerificationResult(
      isMatch: false,
      score: top3Average,
      message: message,
    );
  }

  // ─── L2 NORMALIZE (public for screen-level adaptive updates) ────────────
  List<double> l2Normalize(List<double> embedding) => _l2Normalize(embedding);

  List<double> _l2Normalize(List<double> embedding) {
    double magnitude = 0.0;
    for (final v in embedding) {
      magnitude += v * v;
    }
    magnitude = math.sqrt(magnitude);
    if (magnitude < 1e-10) return embedding;
    return embedding.map((v) => v / magnitude).toList();
  }

  // ─── CLEAR EMBEDDINGS CACHE ─────────────────────────────────────────────
  Future<void> clearEmbeddingsCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('emb_a');
    await prefs.remove('emb_b');
    await prefs.remove('emb_c');
    await prefs.remove('emb_master');
    await prefs.remove('emb_student_id');
    await prefs.remove('emb_cached_at');
    debugPrint('[FACE_LANDMARK] Cleared embeddings cache');
  }

  // ─── DISPOSE ────────────────────────────────────────────────────────────
  void dispose() {
    // No-op — nothing to close (no TFLite interpreter)
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

/// Structured result for each frame in a batch embedding request.
/// Contains the embedding (if face detected), quality pass/fail,
/// quality score for ranking, and rejection reason if applicable.
class BatchEmbeddingResult {
  final List<double>? embedding;
  final bool qualityPassed;
  final double qualityScore; // Higher = better quality, for ranking
  final String? rejectionReason;

  const BatchEmbeddingResult({
    this.embedding,
    this.qualityPassed = true,
    this.qualityScore = 1.0,
    this.rejectionReason,
  });
}
