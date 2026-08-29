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

  // Feature Flag for Quality-Weighted Fusion
  static const bool kUseWeightedFusion = true;

  // Private Expando to associate qualities with embedding list references internally
  final Expando<double> _embeddingQualities = Expando<double>('embeddingQualities');


  // Last fusion statistics
  double lastAverageSimilarity = 0.0;
  double lastEmbeddingVariance = 0.0;
  double lastFusionQuality = 0.0;
  double lastFusionConfidence = 0.0;

  /// Base URL of the FastAPI face service.
  /// Read from .env `FACE_API_URL`, defaults to Android-emulator loopback.
  late final String _apiUrl;

  bool _isInitialized = false;

  // Session Counters
  static int _regCounter = 0;
  static int _verCounter = 0;
  static int _calCounter = 0;

  static String newRegSessionId() => 'REG_${(++_regCounter).toString().padLeft(4, '0')}';
  static String newVerSessionId() => 'VER_${(++_verCounter).toString().padLeft(4, '0')}';
  static String newCalSessionId() => 'CAL_${(++_calCounter).toString().padLeft(4, '0')}';

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
        debugPrint('[FACE_LANDMARK] Embedding Generation Success: false');
        // Log quality info even on failure
        final List<dynamic>? qualityList = json['quality'] as List<dynamic>?;
        if (qualityList != null && qualityList.isNotEmpty) {
          final q = qualityList[0] as Map<String, dynamic>;
          final double rawQualityScore = (q['quality_score'] as num?)?.toDouble() ?? 0.0;
          final double blurScore = (q['blur_score'] as num?)?.toDouble() ?? 0.0;
          final double faceArea = (q['face_area'] as num?)?.toDouble() ?? 0.0;
          final double yaw = (q['yaw'] as num?)?.toDouble() ?? 0.0;
          final double pitch = (q['pitch'] as num?)?.toDouble() ?? 0.0;
          final List<dynamic>? reasons = q['reasons'] as List<dynamic>?;

          debugPrint('[FACE_LANDMARK] Quality Score: $rawQualityScore');
          debugPrint('[FACE_LANDMARK] Blur Score: $blurScore');
          debugPrint('[FACE_LANDMARK] Face Area: $faceArea');
          debugPrint('[FACE_LANDMARK] Yaw: $yaw');
          debugPrint('[FACE_LANDMARK] Pitch: $pitch');
          if (reasons != null && reasons.isNotEmpty) {
            debugPrint('[FACE_LANDMARK] Quality Reasons: ${reasons.join(', ')}');
          }
        }
        return null;
      }

      final List<double> embedding = (embeddings[0] as List)
          .map((e) => (e as num).toDouble())
          .toList();

      debugPrint('[FACE_LANDMARK] Embedding Generation Success: true');
      debugPrint('[FACE_LANDMARK] Embedding Length: ${embedding.length}');

      // Log quality diagnostics from backend
      double rawQualityScore = 0.0;
      final List<dynamic>? qualityList = json['quality'] as List<dynamic>?;
      if (qualityList != null && qualityList.isNotEmpty) {
        final q = qualityList[0] as Map<String, dynamic>;
        rawQualityScore = (q['quality_score'] as num?)?.toDouble() ?? 0.0;
        final double blurScore = (q['blur_score'] as num?)?.toDouble() ?? 0.0;
        final double faceArea = (q['face_area'] as num?)?.toDouble() ?? 0.0;
        final double yaw = (q['yaw'] as num?)?.toDouble() ?? 0.0;
        final double pitch = (q['pitch'] as num?)?.toDouble() ?? 0.0;
        final List<dynamic>? reasons = q['reasons'] as List<dynamic>?;

        debugPrint('[FACE_LANDMARK] Quality Score: $rawQualityScore');
        debugPrint('[FACE_LANDMARK] Blur Score: $blurScore');
        debugPrint('[FACE_LANDMARK] Face Area: $faceArea');
        debugPrint('[FACE_LANDMARK] Yaw: $yaw');
        debugPrint('[FACE_LANDMARK] Pitch: $pitch');
        if (reasons != null && reasons.isNotEmpty) {
          debugPrint('[FACE_LANDMARK] Quality Reasons: ${reasons.join(', ')}');
        }
      }

      _embeddingQualities[embedding] = rawQualityScore;

      return embedding;
    } catch (e) {
      debugPrint('[FACE_LANDMARK] generateEmbedding error: $e');
      return null;
    }
  }

  Future<List<BatchEmbeddingResult>> generateEmbeddingBatch({
    required List<Uint8List> jpegBytesList,
    List<Map<String, double>>? localStatsList,
    String? sessionId,
    String? prefix,
    List<double>? storedA,
    List<double>? storedB,
    List<double>? storedC,
    List<double>? storedMaster,
    List<List<double>>? storedTemplates,
    double? threshold,
    List<Map<String, dynamic>>? clientRejectedLogs,
  }) async {
    if (!_isInitialized) await initialize();

    final stopwatch = Stopwatch()..start();
    final String logPrefix = prefix ?? 'FACE_LANDMARK';
    final String sId = sessionId ?? 'BATCH';

    void log(String msg) {
      if (logPrefix == 'FACE_REG') {
        FaceLogger.reg(sId, msg);
      } else if (logPrefix == 'FACE_VER') {
        FaceLogger.ver(sId, msg);
      } else if (logPrefix == 'FACE_CAL') {
        FaceLogger.cal(sId, msg);
      } else {
        debugPrint('[$logPrefix][$sId] $msg');
      }
    }

    try {
      log('Batch Started');
      log('  Frames = ${jpegBytesList.length}');

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

      if (storedA != null) request.fields['stored_a'] = jsonEncode(storedA);
      if (storedB != null) request.fields['stored_b'] = jsonEncode(storedB);
      if (storedC != null) request.fields['stored_c'] = jsonEncode(storedC);
      if (storedMaster != null) request.fields['stored_master'] = jsonEncode(storedMaster);
      if (storedTemplates != null) request.fields['stored_templates'] = jsonEncode(storedTemplates);
      if (threshold != null) request.fields['threshold'] = threshold.toString();
      if (clientRejectedLogs != null) {
        request.fields['client_rejected_logs'] = jsonEncode(clientRejectedLogs);
      }

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );

      final response = await http.Response.fromStream(streamedResponse);

      stopwatch.stop();
      log('API Duration: ${stopwatch.elapsedMilliseconds}ms');
      debugPrint('[FACE_LANDMARK] API Duration: ${stopwatch.elapsedMilliseconds}ms');

      if (response.statusCode != 200) {
        log('API Error — HTTP ${response.statusCode}');
        return List.generate(
          jpegBytesList.length,
          (_) => BatchEmbeddingResult(
            embedding: null,
            qualityPassed: false,
            rejectionReason: 'API error ${response.statusCode}',
            blurScore: 0.0,
            faceArea: 0.0,
            yaw: 0.0,
            pitch: 0.0,
            rawQualityScore: 0.0,
            apiFailed: true,
          ),
        );
      }

      final Map<String, dynamic> json = jsonDecode(response.body);
      final List<dynamic> embeddings = json['embeddings'];
      final List<dynamic>? qualityList = json['quality'] as List<dynamic>?;
      final bool? backendMatch = json['match'] as bool?;
      final double? backendFinalScore = (json['final_score'] as num?)?.toDouble();
      final bool livenessPassed = json['liveness_passed'] as bool? ?? true;

      final List<BatchEmbeddingResult> result = [];
      for (int i = 0; i < embeddings.length; i++) {
        List<double>? emb;
        if (embeddings[i] != null) {
          emb = (embeddings[i] as List)
              .map((e) => (e as num).toDouble())
              .toList();
        }

        bool qualityPassed = false;
        String? rejectionReason;
        double blurScore = 0.0;
        double faceArea = 0.0;
        double yaw = 0.0;
        double pitch = 0.0;
        double rawQualityScore = 0.0;

        if (qualityList != null && i < qualityList.length) {
          final q = qualityList[i] as Map<String, dynamic>;
          qualityPassed = q['passed'] as bool? ?? false;
          blurScore = (localStatsList != null && i < localStatsList.length)
              ? (localStatsList[i]['sharpness'] ?? 0.0)
              : 0.0;
          faceArea = (q['face_area'] as num?)?.toDouble() ?? 0.0;
          yaw = (q['yaw'] as num?)?.toDouble() ?? 0.0;
          pitch = (q['pitch'] as num?)?.toDouble() ?? 0.0;
          rawQualityScore = (q['quality_score'] as num?)?.toDouble() ?? 0.0;

          final List<dynamic>? reasons = q['reasons'] as List<dynamic>?;
          if (reasons != null && reasons.isNotEmpty) {
            rejectionReason = reasons.join(', ');
          }
        }

        if (emb == null && rejectionReason == null) {
          rejectionReason = 'no_face_detected';
        }

        if (emb != null) {
          _embeddingQualities[emb] = rawQualityScore;
        }

        result.add(
          BatchEmbeddingResult(
            embedding: emb,
            qualityPassed: qualityPassed,
            rejectionReason: rejectionReason,
            blurScore: blurScore,
            faceArea: faceArea,
            yaw: yaw,
            pitch: pitch,
            rawQualityScore: rawQualityScore,
            match: backendMatch,
            finalScore: backendFinalScore,
            livenessPassed: livenessPassed,
          ),
        );

        final int frameNum = i + 1;
        final int qScore = rawQualityScore.clamp(0.0, 100.0).toInt();
        if (emb != null && qualityPassed) {
          log('Frame $frameNum');
          log('  Quality = $qScore');
          log('  Passed  = true');
        } else {
          final String reason = rejectionReason ?? 'no_face_detected';
          log('Frame $frameNum');
          log('  Passed = false');
          log('  Reason = $reason');
          log('  Score  = $qScore');
        }

        debugPrint('[FACE_LANDMARK] Frame $frameNum:');
        debugPrint('[FACE_LANDMARK]   Embedding Generation Success: ${emb != null}');
        if (emb != null) {
          debugPrint('[FACE_LANDMARK]   Embedding Length: ${emb.length}');
        }
        debugPrint('[FACE_LANDMARK]   Quality Score: $rawQualityScore');
        debugPrint('[FACE_LANDMARK]   Blur Score: $blurScore');
        debugPrint('[FACE_LANDMARK]   Face Area: $faceArea');
        debugPrint('[FACE_LANDMARK]   Yaw: $yaw');
        debugPrint('[FACE_LANDMARK]   Pitch: $pitch');
        if (rejectionReason != null) {
          debugPrint('[FACE_LANDMARK]   Quality Reasons: $rejectionReason');
        }
      }

      final int accepted = result
          .where((e) => e.embedding != null && e.qualityPassed)
          .length;
      final int rejected = jpegBytesList.length - accepted;
      final double avgQuality = result.isEmpty
          ? 0.0
          : result.map((e) => e.rawQualityScore).reduce((a, b) => a + b) /
                result.length;
      log('Batch Summary');
      log('  Accepted        = $accepted');
      log('  Rejected        = $rejected');
      log('  Average Quality = ${avgQuality.toStringAsFixed(1)}');
      return result;
    } catch (e) {
      stopwatch.stop();
      log('API Failed — ${e.runtimeType}: $e');
      return List.generate(
        jpegBytesList.length,
        (_) => BatchEmbeddingResult(
          embedding: null,
          qualityPassed: false,
          rejectionReason: e.toString(),
          blurScore: 0.0,
          faceArea: 0.0,
          yaw: 0.0,
          pitch: 0.0,
          rawQualityScore: 0.0,
          apiFailed: true,
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

  /// Combines frontal, left, and right embeddings into a 3-element list for multi-pose registration storage.
  List<List<double>> createMultiEmbeddingArray({
    required List<double> front,
    required List<double> left,
    required List<double> right,
  }) {
    return [front, left, right];
  }

  // ─── AVERAGE EMBEDDINGS ─────────────────────────────────────────────────
  // Works with any embedding dimension (192 or 512).
  // ────────────────────────────────────────────────────────────────────────
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
  // Simple 1:1 cosine similarity check against storedMasterEmbedding.
  // ────────────────────────────────────────────────────────────────────────
  VerificationResult verifyFace({
    required List<List<double>> liveEmbeddings,
    required List<double> storedMasterEmbedding,
    double threshold = 0.70,
  }) {
    if (liveEmbeddings.isEmpty) {
      return const VerificationResult(
        isMatch: false,
        score: 0.0,
        message: 'No frames captured',
      );
    }

    // Calculate the simple average of live embeddings
    final List<double> averagedLive = averageEmbeddings(liveEmbeddings);
    if (averagedLive.isEmpty) {
      return const VerificationResult(
        isMatch: false,
        score: 0.0,
        message: 'Failed to process live face',
      );
    }

    // Calculate cosine similarity
    final double similarity = cosineSimilarity(averagedLive, storedMasterEmbedding);
    final double margin = similarity - threshold;
    final bool isMatch = similarity >= threshold;

    debugPrint('[FACE_LANDMARK] Similarity=${similarity.toStringAsFixed(4)}');
    debugPrint('[FACE_LANDMARK] Threshold=${threshold.toStringAsFixed(4)}');
    debugPrint('[FACE_LANDMARK] Margin=${margin.toStringAsFixed(4)}');
    debugPrint('[FACE_LANDMARK] Decision=${isMatch ? "PASS" : "FAIL"}');

    if (isMatch) {
      return VerificationResult(
        isMatch: true,
        score: similarity,
        message: 'Verified',
      );
    }

    return VerificationResult(
      isMatch: false,
      score: similarity,
      message: 'Face not recognized',
    );
  }

  // ─── VERIFY MULTI-TEMPLATE FACE ───────────────────────────────────────
  // Compares averaged live embedding against all stored pose templates.
  // ────────────────────────────────────────────────────────────────────────
  MultiTemplateVerificationResult verifyMultiTemplate({
    required List<List<double>> liveEmbeddings,
    required Map<String, List<double>> storedPoseTemplates,
    double threshold = 0.70,
  }) {
    if (liveEmbeddings.isEmpty || storedPoseTemplates.isEmpty) {
      return const MultiTemplateVerificationResult(
        isMatch: false,
        bestScore: 0.0,
        bestPose: 'none',
        scores: {},
      );
    }

    final List<double> averagedLive = averageEmbeddings(liveEmbeddings);
    if (averagedLive.isEmpty) {
      return const MultiTemplateVerificationResult(
        isMatch: false,
        bestScore: 0.0,
        bestPose: 'none',
        scores: {},
      );
    }

    double bestScore = -1.0;
    String bestPose = 'none';
    final Map<String, double> scores = {};

    storedPoseTemplates.forEach((poseKey, storedVec) {
      final double score = cosineSimilarity(averagedLive, storedVec);
      scores[poseKey] = score;
      if (score > bestScore) {
        bestScore = score;
        bestPose = poseKey;
      }
    });

    final bool isMatch = bestScore >= threshold;

    debugPrint('[FACE_LANDMARK] Multi-Template Matching Results:');
    debugPrint('  Live Vector Length: ${averagedLive.length}');
    scores.forEach((poseKey, score) {
      final int vecLen = storedPoseTemplates[poseKey]?.length ?? 0;
      debugPrint('  $poseKey score: ${score.toStringAsFixed(4)} (length: $vecLen)');
    });
    debugPrint('  Best Score: ${bestScore.toStringAsFixed(4)} ($bestPose)');
    debugPrint('  Threshold: ${threshold.toStringAsFixed(4)}');
    debugPrint('  Decision: ${isMatch ? "PASS" : "FAIL"}');

    return MultiTemplateVerificationResult(
      isMatch: isMatch,
      bestScore: bestScore,
      bestPose: bestPose,
      scores: scores,
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
    await prefs.remove('emb_up');
    await prefs.remove('emb_down');
    await prefs.remove('emb_master');
    await prefs.remove('emb_stored_templates');
    await prefs.remove('emb_pose_templates');
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

class FaceLogger {
  static void reg(String sessionId, String message) =>
      debugPrint('[FACE_REG][$sessionId] $message');

  static void ver(String sessionId, String message) =>
      debugPrint('[FACE_VER][$sessionId] $message');

  static void cal(String sessionId, String message) =>
      debugPrint('[FACE_CAL][$sessionId] $message');

  static void separator(String sessionId, String prefix) =>
      debugPrint('[$prefix][$sessionId] ═' * 40);
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

class MultiTemplateVerificationResult {
  final bool isMatch;
  final double bestScore;
  final String bestPose;
  final Map<String, double> scores;

  const MultiTemplateVerificationResult({
    required this.isMatch,
    required this.bestScore,
    required this.bestPose,
    required this.scores,
  });
}

class BatchEmbeddingResult {
  final List<double>? embedding;
  final bool qualityPassed;
  final String? rejectionReason;
  final double blurScore;
  final double faceArea;
  final double yaw;
  final double pitch;
  final double rawQualityScore;

  /// True when the API request itself failed (network error, timeout, HTTP 5xx).
  /// False when the backend responded successfully (even if quality was rejected).
  /// The registration screen uses this to distinguish network failures from
  /// quality failures — only quality failures should restart camera capture.
  final bool apiFailed;
  final bool? match;
  final double? finalScore;
  final bool livenessPassed;

  double get qualityScore => rawQualityScore;

  BatchEmbeddingResult({
    required this.embedding,
    required this.qualityPassed,
    this.rejectionReason,
    required this.blurScore,
    required this.faceArea,
    required this.yaw,
    required this.pitch,
    required this.rawQualityScore,
    this.apiFailed =
        false, // defaults false — normal quality results are never API failures
    this.match,
    this.finalScore,
    this.livenessPassed = true,
  });
}

class WeightedEmbedding {
  final List<double> embedding;
  final double quality;

  const WeightedEmbedding({
    required this.embedding,
    required this.quality,
  });
}
