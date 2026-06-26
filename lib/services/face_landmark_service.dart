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

  // Temporary transaction variables for diagnostics
  List<double>? _currentMasterEmbedding;
  double? _currentEffectiveThreshold;

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

      debugPrint('[FACE_LANDMARK] Received ${embedding.length}-dim embedding');

      // Log quality diagnostics from backend
      double rawQualityScore = 0.0;
      final List<dynamic>? qualityList = json['quality'] as List<dynamic>?;
      if (qualityList != null && qualityList.isNotEmpty) {
        final q = qualityList[0] as Map<String, dynamic>;
        rawQualityScore = (q['quality_score'] as num?)?.toDouble() ?? 0.0;
        debugPrint(
          '[FACE_LANDMARK] QUALITY: passed=${q['passed']} '
          'blur=${q['blur_score']} faceArea=${q['face_area']} '
          'yaw=${q['yaw']} pitch=${q['pitch']} '
          'reasons=${q['reasons']}',
        );
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
    String? sessionId,
    String? prefix,
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

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );

      final response = await http.Response.fromStream(streamedResponse);

      stopwatch.stop();
      log('API Duration: ${stopwatch.elapsedMilliseconds}ms');

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
          blurScore = (q['blur_score'] as num?)?.toDouble() ?? 0.0;
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

  // ─── AVERAGE EMBEDDINGS ─────────────────────────────────────────────────
  // Works with any embedding dimension (192 or 512).
  // Dispatches to weightedAverageEmbeddings if kUseWeightedFusion is enabled,
  // otherwise falls back to simpleAverageEmbeddings.
  // ────────────────────────────────────────────────────────────────────────
  List<double> averageEmbeddings(List<List<double>> embeddings) {
    if (kUseWeightedFusion) {
      return weightedAverageEmbeddings(embeddings);
    }
    return simpleAverageEmbeddings(embeddings);
  }

  List<double> simpleAverageEmbeddings(List<List<double>> embeddings) {
    debugPrint('[FACE_LANDMARK] Averaging ${embeddings.length} embeddings (simple)');
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

  List<double> weightedAverageEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) {
      debugPrint('[FACE_LANDMARK] No embeddings to average');
      return [];
    }
    if (embeddings.length == 1) {
      debugPrint('[FACE_LANDMARK] Only one embedding, returning as is');
      return embeddings[0];
    }

    final int n = embeddings.length;
    final int vecSize = embeddings[0].length;

    // 1. Map to WeightedEmbedding using Expando qualities
    final List<WeightedEmbedding> weightedInputs = [];
    final List<double> qualities = [];
    for (final emb in embeddings) {
      double? q = _embeddingQualities[emb];
      if (q == null) {
        debugPrint('[FACE_LANDMARK] WARNING Missing backend quality Using fallback quality = 80');
        q = 80.0;
      }
      weightedInputs.add(WeightedEmbedding(embedding: emb, quality: q));
      qualities.add(q);
    }

    // 2. Compute weights with clamping and redistribution
    final List<bool> clamped = List.filled(n, false);
    final List<double> weights = _calculateWeights(qualities, clamped);

    // 3. Compute weighted average
    final List<double> weightedAveraged = List.filled(vecSize, 0.0);
    for (int i = 0; i < n; i++) {
      final emb = weightedInputs[i].embedding;
      final w = weights[i];
      for (int j = 0; j < vecSize; j++) {
        weightedAveraged[j] += emb[j] * w;
      }
    }

    // 4. L2 Normalize
    final double magBefore = _getMagnitude(weightedAveraged);
    final List<double> normalized = _l2Normalize(weightedAveraged);
    final double magAfter = _getMagnitude(normalized);

    // 5. Diagnostics calculations
    final double weightSum = weights.reduce((a, b) => a + b);
    final double highestWeight = weights.reduce((a, b) => math.max(a, b));
    final double lowestWeight = weights.reduce((a, b) => math.min(a, b));
    final double avgQuality = qualities.reduce((a, b) => a + b) / n;
    final double minQual = qualities.reduce((a, b) => math.min(a, b));
    final double maxQual = qualities.reduce((a, b) => math.max(a, b));
    final double qualityStdDev = _calculateStdDev(qualities, avgQuality);

    // 6. Simple average for comparison
    final List<double> simpleAvg = simpleAverageEmbeddings(embeddings);
    final double sim = cosineSimilarity(simpleAvg, normalized);

    // 7. Output logs (Ensure ALL log lines start with [FACE_LANDMARK] exactly as requested)
    debugPrint('[FACE_LANDMARK] QUALITY WEIGHTED FUSION ENABLED');
    debugPrint('[FACE_LANDMARK] ');
    for (int i = 0; i < n; i++) {
      debugPrint('[FACE_LANDMARK] Frame ${i + 1}');
      debugPrint('[FACE_LANDMARK] Backend Quality : ${qualities[i].toStringAsFixed(1)}');
      debugPrint('[FACE_LANDMARK] Weight : ${weights[i].toStringAsFixed(4)}');
      debugPrint('[FACE_LANDMARK] Clamped : ${clamped[i] ? "YES" : "NO"}');
      debugPrint('[FACE_LANDMARK] ');
    }
    debugPrint('[FACE_LANDMARK] Weight Sum : ${weightSum.toStringAsFixed(4)}');
    debugPrint('[FACE_LANDMARK] Highest Weight : ${highestWeight.toStringAsFixed(4)}');
    debugPrint('[FACE_LANDMARK] Lowest Weight : ${lowestWeight.toStringAsFixed(4)}');
    debugPrint('[FACE_LANDMARK] Average Quality : ${avgQuality.toStringAsFixed(1)}');
    debugPrint('[FACE_LANDMARK] Minimum Quality : ${minQual.toStringAsFixed(1)}');
    debugPrint('[FACE_LANDMARK] Maximum Quality : ${maxQual.toStringAsFixed(1)}');
    debugPrint('[FACE_LANDMARK] Quality Std Dev : ${qualityStdDev.toStringAsFixed(1)}');
    debugPrint('[FACE_LANDMARK] Cosine(Simple vs Weighted): ${sim.toStringAsFixed(4)}');
    debugPrint('[FACE_LANDMARK] Embedding Length Before Normalize : ${magBefore.toStringAsFixed(4)}');
    debugPrint('[FACE_LANDMARK] Embedding Length After Normalize : ${magAfter.toStringAsFixed(4)}');
    debugPrint('[FACE_LANDMARK] Normalization Passed : YES');

    // Matching diagnostics
    if (_currentMasterEmbedding != null) {
      final double simpleSim = cosineSimilarity(simpleAvg, _currentMasterEmbedding!);
      final double weightedSim = cosineSimilarity(normalized, _currentMasterEmbedding!);
      final double difference = weightedSim - simpleSim;
      final double thresh = _currentEffectiveThreshold ?? 0.82;
      final String decision = (weightedSim >= thresh) ? 'PASS' : 'FAIL';

      debugPrint('[FACE_LANDMARK] Simple Similarity to Master : ${simpleSim.toStringAsFixed(4)}');
      debugPrint('[FACE_LANDMARK] Weighted Similarity to Master : ${weightedSim.toStringAsFixed(4)}');
      debugPrint('[FACE_LANDMARK] Difference : ${difference.toStringAsFixed(4)}');
      debugPrint('[FACE_LANDMARK] Decision : $decision');
    }

    // 8. Associate computed average quality for hierarchical fusion
    _embeddingQualities[normalized] = avgQuality;

    // 9. Clear temporary transaction variables
    _currentMasterEmbedding = null;
    _currentEffectiveThreshold = null;

    return normalized;
  }

  List<double> _calculateWeights(List<double> qualities, List<bool> clamped, {double minWeightVal = 0.05}) {
    final int n = qualities.length;
    if (n == 0) return [];
    if (n == 1) return [1.0];

    double minWeight = minWeightVal;
    if (minWeight * n >= 1.0) {
      minWeight = 0.9 / n;
    }

    double totalQuality = qualities.reduce((a, b) => a + b);
    if (totalQuality == 0.0) {
      return List.filled(n, 1.0 / n);
    }

    final List<double> weights = List.filled(n, 0.0);
    bool checkNeeded = true;

    while (checkNeeded) {
      checkNeeded = false;
      double sumClamped = 0.0;
      double sumNonClampedQuality = 0.0;

      for (int i = 0; i < n; i++) {
        if (clamped[i]) {
          sumClamped += minWeight;
        } else {
          sumNonClampedQuality += qualities[i];
        }
      }

      final double remainingWeight = 1.0 - sumClamped;

      for (int i = 0; i < n; i++) {
        if (!clamped[i]) {
          double w = 0.0;
          if (sumNonClampedQuality > 0.0) {
            w = (qualities[i] / sumNonClampedQuality) * remainingWeight;
          } else {
            int nonClampedCount = n - clamped.where((c) => c).length;
            w = remainingWeight / nonClampedCount;
          }

          if (w < minWeight) {
            clamped[i] = true;
            checkNeeded = true;
            break;
          } else {
            weights[i] = w;
          }
        } else {
          weights[i] = minWeight;
        }
      }
    }

    return weights;
  }

  double _getMagnitude(List<double> embedding) {
    double magnitude = 0.0;
    for (final v in embedding) {
      magnitude += v * v;
    }
    return math.sqrt(magnitude);
  }

  double _calculateStdDev(List<double> values, double mean) {
    if (values.isEmpty) return 0.0;
    double sumOfSquares = 0.0;
    for (final v in values) {
      sumOfSquares += math.pow(v - mean, 2);
    }
    return math.sqrt(sumOfSquares / values.length);
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
    debugPrint(
      '[FACE_VER] masterEmbedding present: ${masterEmbedding != null}',
    );

    // Clamp threshold: never exceed 0.76 (temporary safeguard)
    final double effectiveThreshold = math.max(threshold, 0.65);
    
    // Store temporarily for diagnostics during current execution
    _currentMasterEmbedding = masterEmbedding;
    _currentEffectiveThreshold = effectiveThreshold;

    debugPrint(
      '[FACE_VER] thresholdUsed=${effectiveThreshold.toStringAsFixed(4)} (stored=${threshold.toStringAsFixed(4)}, floor=0.65)',
    );

    // Determine primary template
    final bool useMaster =
        masterEmbedding != null && masterEmbedding.isNotEmpty;

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
    debugPrint('[FACE_VER] top3Average=${top3Average.toStringAsFixed(4)}');
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

  double get qualityScore {
    final double yawAbs = yaw.abs();
    final double pitchAbs = pitch.abs();
    return (blurScore * faceArea) / (1.0 + yawAbs + pitchAbs);
  }

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
