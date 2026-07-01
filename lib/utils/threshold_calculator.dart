import 'dart:math' as math;

class ThresholdResult {
  final double threshold;   // personalized threshold, clamped [0.60, 0.88]
  final double meanSim;     // mean similarity across all templates
  final double stdDev;      // standard deviation
  final bool isValid;       // false if NaN/Infinity/insufficient data
  final String? failReason;

  ThresholdResult({
    required this.threshold,
    required this.meanSim,
    required this.stdDev,
    required this.isValid,
    this.failReason,
  });
}

class ThresholdCalculator {
  static const double kThresholdStdMultiplier = 1.5;

  static ThresholdResult calculate({
    required List<List<double>> liveEmbeddings,
    List<double>? embeddingA,
    List<double>? embeddingB,
    List<double>? embeddingC,
    List<double>? masterEmbedding,
    required double Function(List<double>, List<double>) cosineSimilarity,
  }) {
    if (liveEmbeddings.isEmpty) {
      return ThresholdResult(
        threshold: 0.75,
        meanSim: 0.0,
        stdDev: 0.0,
        isValid: false,
        failReason: 'No live embeddings provided.',
      );
    }

    final templates = [embeddingA, embeddingB, embeddingC, masterEmbedding]
        .whereType<List<double>>()
        .toList();

    if (templates.isEmpty) {
      return ThresholdResult(
        threshold: 0.75,
        meanSim: 0.0,
        stdDev: 0.0,
        isValid: false,
        failReason: 'No stored templates available.',
      );
    }

    final scores = <double>[];
    for (final live in liveEmbeddings) {
      for (final temp in templates) {
        scores.add(cosineSimilarity(live, temp));
      }
    }

    // Refinement 3: Validate sufficient calibration data before generating the threshold
    if (liveEmbeddings.length < 6 || scores.length < 6) {
      return ThresholdResult(
        threshold: 0.75,
        meanSim: 0.0,
        stdDev: 0.0,
        isValid: false,
        failReason: 'Insufficient calibration data. Got ${liveEmbeddings.length} frames and ${scores.length} similarity scores, but need at least 6 of each.',
      );
    }

    final double mean = scores.reduce((a, b) => a + b) / scores.length;
    final double variance = scores.map((s) => math.pow(s - mean, 2)).reduce((a, b) => a + b) / scores.length;
    final double stdDev = math.sqrt(variance);
    final double threshold = (mean - kThresholdStdMultiplier * stdDev).clamp(0.60, 0.88);

    final bool isValid = !threshold.isNaN &&
        !threshold.isInfinite &&
        !mean.isNaN &&
        !mean.isInfinite &&
        !stdDev.isNaN &&
        !stdDev.isInfinite;

    return ThresholdResult(
      threshold: threshold,
      meanSim: mean,
      stdDev: stdDev,
      isValid: isValid,
      failReason: isValid ? null : 'Calculation resulted in NaN or Infinity.',
    );
  }
}
