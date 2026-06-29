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
    List<Map<String, double>>? localStatsList,
    String? sessionId,
    String? prefix,
    List<double>? storedA,
    List<double>? storedB,
    List<double>? storedC,
    List<double>? storedMaster,
    double? threshold,
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
      if (threshold != null) request.fields['threshold'] = threshold.toString();

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
      debugPrint('[FACE_EMBEDDING] No embeddings to average');
      return [];
    }
    if (embeddings.length == 1) {
      debugPrint('[FACE_EMBEDDING] Only one embedding, returning as is');
      lastAverageSimilarity = 1.0;
      lastEmbeddingVariance = 0.0;
      lastFusionQuality = _embeddingQualities[embeddings[0]] ?? 80.0;
      lastFusionConfidence = lastFusionQuality / 100.0;
      return embeddings[0];
    }

    final int n = embeddings.length;
    final int vecSize = embeddings[0].length;

    // 1. Build Pairwise Similarity Matrix
    final List<List<double>> simMatrix = List.generate(n, (_) => List.filled(n, 1.0));
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        final double sim = cosineSimilarity(embeddings[i], embeddings[j]);
        simMatrix[i][j] = sim;
        simMatrix[j][i] = sim;
      }
    }

    // Print Similarity Matrix
    debugPrint('[FACE_EMBEDDING] Pairwise Similarity Matrix:');
    for (int i = 0; i < n; i++) {
      final row = simMatrix[i].map((s) => s.toStringAsFixed(4)).join('  ');
      debugPrint('[FACE_EMBEDDING]   Row ${i + 1}: [ $row ]');
    }

    // 2. Compute mean similarities for outlier analysis
    final List<double> meanSims = List.filled(n, 0.0);
    double totalSimSum = 0.0;
    int simCount = 0;
    for (int i = 0; i < n; i++) {
      double sum = 0.0;
      for (int j = 0; j < n; j++) {
        if (i != j) {
          sum += simMatrix[i][j];
          totalSimSum += simMatrix[i][j];
          simCount++;
        }
      }
      meanSims[i] = sum / (n - 1);
    }
    final double overallMeanSim = simCount > 0 ? totalSimSum / simCount : 1.0;

    // Calculate Median and MAD (Median Absolute Deviation)
    final List<double> sortedSims = List.from(meanSims)..sort();
    final double median = sortedSims[n ~/ 2];
    
    final List<double> deviations = meanSims.map((s) => (s - median).abs()).toList();
    final List<double> sortedDeviations = List.from(deviations)..sort();
    final double mad = sortedDeviations[n ~/ 2];

    // Calculate Mean and StdDev for fallback
    final double mean = meanSims.reduce((a, b) => a + b) / n;
    double sumSqDiff = 0.0;
    for (int i = 0; i < n; i++) {
      sumSqDiff += math.pow(meanSims[i] - mean, 2);
    }
    final double stdDev = math.sqrt(sumSqDiff / n);

    // 3. Outlier Rejection
    final List<int> acceptedIndices = [];
    final List<int> rejectedIndices = [];
    String rejectionReason = "None";

    for (int i = 0; i < n; i++) {
      bool isOutlier = false;
      if (n > 2) {
        if (mad > 0.001) {
          final double threshold = median - 2.0 * mad;
          if (meanSims[i] < threshold) {
            isOutlier = true;
            rejectionReason = "MAD outlier (similarity ${meanSims[i].toStringAsFixed(4)} < limit ${threshold.toStringAsFixed(4)})";
          }
        } else if (stdDev > 0.001) {
          final double threshold = mean - 1.5 * stdDev;
          if (meanSims[i] < threshold) {
            isOutlier = true;
            rejectionReason = "StdDev outlier (similarity ${meanSims[i].toStringAsFixed(4)} < limit ${threshold.toStringAsFixed(4)})";
          }
        }
      } else {
        // With n=2, reject the lower quality one if similarity is extremely low (< 0.75)
        if (simMatrix[0][1] < 0.75) {
          final q0 = _embeddingQualities[embeddings[0]] ?? 80.0;
          final q1 = _embeddingQualities[embeddings[1]] ?? 80.0;
          if (i == 0 && q0 < q1) {
            isOutlier = true;
            rejectionReason = "Extremely low pairwise similarity (<0.75) and lower quality than Frame 2";
          }
          if (i == 1 && q1 < q0) {
            isOutlier = true;
            rejectionReason = "Extremely low pairwise similarity (<0.75) and lower quality than Frame 1";
          }
        }
      }

      if (isOutlier) {
        rejectedIndices.add(i);
      } else {
        acceptedIndices.add(i);
      }
    }

    // Fallback: if all rejected, keep the highest quality one
    if (acceptedIndices.isEmpty) {
      int bestIdx = 0;
      double maxQ = -1.0;
      for (int i = 0; i < n; i++) {
        final q = _embeddingQualities[embeddings[i]] ?? 80.0;
        if (q > maxQ) {
          maxQ = q;
          bestIdx = i;
        }
      }
      acceptedIndices.add(bestIdx);
      rejectedIndices.remove(bestIdx);
    }

    // Print Outlier logs
    debugPrint('[FACE_EMBEDDING] Outlier Rejection Summary:');
    debugPrint('[FACE_EMBEDDING]   Median Similarity  : ${median.toStringAsFixed(4)}');
    debugPrint('[FACE_EMBEDDING]   MAD                : ${mad.toStringAsFixed(4)}');
    debugPrint('[FACE_EMBEDDING]   Mean Similarity    : ${mean.toStringAsFixed(4)}');
    debugPrint('[FACE_EMBEDDING]   Std Dev            : ${stdDev.toStringAsFixed(4)}');
    debugPrint('[FACE_EMBEDDING]   Accepted Indices   : ${acceptedIndices.map((idx) => 'Frame ${idx + 1}').join(', ')}');
    debugPrint('[FACE_EMBEDDING]   Rejected Indices   : ${rejectedIndices.isEmpty ? 'None' : rejectedIndices.map((idx) => 'Frame ${idx + 1}').join(', ')}');
    if (rejectedIndices.isNotEmpty) {
      debugPrint('[FACE_EMBEDDING]   Rejection Reason   : $rejectionReason');
    }

    // 4. Quality-Weighted Average of accepted indices
    final List<List<double>> filteredEmbeddings = [];
    final List<double> filteredQualities = [];
    for (final idx in acceptedIndices) {
      final emb = embeddings[idx];
      filteredEmbeddings.add(emb);
      filteredQualities.add(_embeddingQualities[emb] ?? 80.0);
    }

    final int m = filteredEmbeddings.length;
    final List<bool> clamped = List.filled(m, false);
    final List<double> weights = _calculateWeights(filteredQualities, clamped);

    final List<double> weightedAveraged = List.filled(vecSize, 0.0);
    for (int i = 0; i < m; i++) {
      final emb = filteredEmbeddings[i];
      final w = weights[i];
      for (int j = 0; j < vecSize; j++) {
        weightedAveraged[j] += emb[j] * w;
      }
    }

    final List<double> normalized = _l2Normalize(weightedAveraged);

    // 5. Compute embedding variance (variance of accepted embeddings similarities to fused embedding)
    final List<double> simsToFused = [];
    for (int i = 0; i < m; i++) {
      simsToFused.add(cosineSimilarity(filteredEmbeddings[i], normalized));
    }
    final double meanSimToFused = simsToFused.reduce((a, b) => a + b) / m;
    double varSum = 0.0;
    for (final sim in simsToFused) {
      varSum += math.pow(sim - meanSimToFused, 2);
    }
    final double embeddingVariance = m > 1 ? varSum / m : 0.0;

    // Final Fusion Quality
    double finalFusionQuality = 0.0;
    for (int i = 0; i < m; i++) {
      finalFusionQuality += filteredQualities[i] * weights[i];
    }
    final double fusionConfidence = finalFusionQuality / 100.0;

    // Set diagnostics properties
    lastAverageSimilarity = overallMeanSim;
    lastEmbeddingVariance = embeddingVariance;
    lastFusionQuality = finalFusionQuality;
    lastFusionConfidence = fusionConfidence;

    // Print logs
    debugPrint('[FACE_EMBEDDING] FUSION DIAGNOSTICS:');
    for (int i = 0; i < m; i++) {
      debugPrint('[FACE_EMBEDDING]   Accepted Frame ${acceptedIndices[i] + 1} | Quality Weight: ${weights[i].toStringAsFixed(4)}');
    }
    debugPrint('[FACE_EMBEDDING]   Final Weighted Similarity : ${meanSimToFused.toStringAsFixed(4)}');
    debugPrint('[FACE_EMBEDDING]   Embedding Variance        : ${embeddingVariance.toStringAsFixed(6)}');
    debugPrint('[FACE_EMBEDDING]   Final Fusion Quality      : ${finalFusionQuality.toStringAsFixed(1)}');
    debugPrint('[FACE_EMBEDDING]   Fusion Confidence         : ${fusionConfidence.toStringAsFixed(4)}');

    _embeddingQualities[normalized] = finalFusionQuality;

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

    double adaptiveThreshold = threshold;
    if (lastFusionQuality < 75.0) {
      double ratio = (75.0 - lastFusionQuality).clamp(0.0, 75.0) / 75.0;
      adaptiveThreshold -= 0.04 * ratio;
    }
    if (lastEmbeddingVariance < 0.005) {
      adaptiveThreshold -= 0.02;
    } else if (lastEmbeddingVariance > 0.02) {
      adaptiveThreshold += 0.02;
    }
    final double effectiveThreshold = adaptiveThreshold.clamp(0.75, 0.85);

    debugPrint('[FACE_VER] thresholdUsed=${effectiveThreshold.toStringAsFixed(4)} (stored=${threshold.toStringAsFixed(4)}, adaptive=$adaptiveThreshold)');

    // ── 1. Run Fused Embedding Generation ──
    final List<double> fusedLive = weightedAverageEmbeddings(liveEmbeddings);

    // Determine templates presence
    final bool useMaster = masterEmbedding != null && masterEmbedding.isNotEmpty;

    // ── 2. Run Comparative Matching Diagnostics (FACE_MATCH) ──
    final double sA = cosineSimilarity(fusedLive, storedEmbeddingA);
    final double sB = cosineSimilarity(fusedLive, storedEmbeddingB);
    final double sC = cosineSimilarity(fusedLive, storedEmbeddingC);
    final double sMaster = useMaster ? cosineSimilarity(fusedLive, masterEmbedding) : 0.0;

    final double wMaster = useMaster ? 0.50 : 0.0;
    final double wA = useMaster ? 0.1666 : 0.3333;
    final double wB = useMaster ? 0.1666 : 0.3333;
    final double wC = useMaster ? 0.1666 : 0.3333;

    final double cMaster = sMaster * wMaster;
    final double cA = sA * wA;
    final double cB = sB * wB;
    final double cC = sC * wC;

    final double matchFinalScore = cMaster + cA + cB + cC;

    // Build fallback average of A/B/C
    final int dim = storedEmbeddingA.length;
    final List<double> avgStored = _l2Normalize(
      List.generate(
        dim,
        (i) => (storedEmbeddingA[i] + storedEmbeddingB[i] + storedEmbeddingC[i]) / 3.0,
      ),
    );

    // Existing Top-3 matching algorithm logic
    final List<double> masterScores = [];
    final List<double> abcMeanScores = [];
    for (int i = 0; i < liveEmbeddings.length; i++) {
      final live = liveEmbeddings[i];
      final double frameA = cosineSimilarity(live, storedEmbeddingA);
      final double frameB = cosineSimilarity(live, storedEmbeddingB);
      final double frameC = cosineSimilarity(live, storedEmbeddingC);
      final double frameAvg = cosineSimilarity(live, avgStored);
      final double abcMean = (frameA + frameB + frameC + frameAvg) / 4.0;
      abcMeanScores.add(abcMean);

      final double mScore = useMaster ? cosineSimilarity(live, masterEmbedding) : abcMean;
      masterScores.add(mScore);

      debugPrint(
        '[FACE_VER] Frame $i → masterScore=${mScore.toStringAsFixed(4)} '
        'sA=${frameA.toStringAsFixed(4)} sB=${frameB.toStringAsFixed(4)} '
        'sC=${frameC.toStringAsFixed(4)} sAvg=${frameAvg.toStringAsFixed(4)} '
        'abcMean=${abcMean.toStringAsFixed(4)}',
      );
    }

    final List<double> sorted = List<double>.from(masterScores)..sort((a, b) => b.compareTo(a));
    final int topN = math.min(3, sorted.length);
    final double top3Average = sorted.sublist(0, topN).reduce((a, b) => a + b) / topN;

    final String matchDecision = (top3Average >= effectiveThreshold) ? 'PASS' : 'FAIL';

    debugPrint('[FACE_MATCH] ═══ MATCHING DIAGNOSTICS ═══');
    debugPrint('[FACE_MATCH] Template A | Similarity: ${sA.toStringAsFixed(4)} | Weight: ${wA.toStringAsFixed(4)} | Contribution: ${cA.toStringAsFixed(4)}');
    debugPrint('[FACE_MATCH] Template B | Similarity: ${sB.toStringAsFixed(4)} | Weight: ${wB.toStringAsFixed(4)} | Contribution: ${cB.toStringAsFixed(4)}');
    debugPrint('[FACE_MATCH] Template C | Similarity: ${sC.toStringAsFixed(4)} | Weight: ${wC.toStringAsFixed(4)} | Contribution: ${cC.toStringAsFixed(4)}');
    if (useMaster) {
      debugPrint('[FACE_MATCH] Master     | Similarity: ${sMaster.toStringAsFixed(4)} | Weight: ${wMaster.toStringAsFixed(4)} | Contribution: ${cMaster.toStringAsFixed(4)}');
    } else {
      debugPrint('[FACE_MATCH] Master     | Similarity: N/A | Weight: 0.0000 | Contribution: 0.0000');
    }
    debugPrint('[FACE_MATCH] Final Score: ${top3Average.toStringAsFixed(4)} (weighted sum = ${matchFinalScore.toStringAsFixed(4)})');
    debugPrint('[FACE_MATCH] Threshold  : ${effectiveThreshold.toStringAsFixed(4)}');
    debugPrint('[FACE_MATCH] Decision   : $matchDecision');
    debugPrint('[FACE_MATCH] ════════════════════════════');

    // ── 3. Run Embedding Drift Diagnostics (FACE_EMBEDDING) ──
    final double driftScore = 1.0 - cosineSimilarity(liveEmbeddings.first, liveEmbeddings.last);
    final bool driftDetected = driftScore > 0.15;

    debugPrint('[FACE_EMBEDDING] Embedding Drift Diagnostics:');
    debugPrint('[FACE_EMBEDDING]   Similarity to Template A : ${sA.toStringAsFixed(4)}');
    debugPrint('[FACE_EMBEDDING]   Similarity to Template B : ${sB.toStringAsFixed(4)}');
    debugPrint('[FACE_EMBEDDING]   Similarity to Template C : ${sC.toStringAsFixed(4)}');
    if (useMaster) {
      debugPrint('[FACE_EMBEDDING]   Similarity to Master     : ${sMaster.toStringAsFixed(4)}');
    } else {
      debugPrint('[FACE_EMBEDDING]   Similarity to Master     : N/A');
    }
    debugPrint('[FACE_EMBEDDING]   Embedding Variance       : ${lastEmbeddingVariance.toStringAsFixed(6)}');
    debugPrint('[FACE_EMBEDDING]   Avg Intra-frame Sim      : ${lastAverageSimilarity.toStringAsFixed(4)}');
    debugPrint('[FACE_EMBEDDING]   Drift Score              : ${driftScore.toStringAsFixed(4)}');
    debugPrint('[FACE_EMBEDDING]   Drift Detected           : ${driftDetected ? "YES" : "NO"}');

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
