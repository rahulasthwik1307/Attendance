// lib/utils/calibration_template_builder.dart
//
// Utility that mirrors the registration fusion architecture for calibration.
// Produces a stable live template by applying the same weighted-fusion +
// outlier-rejection algorithm used in face_registration_screen.dart via
// FaceLandmarkService.averageEmbeddings().
//
// Design principles:
//   - No duplicate fusion algorithms.  All fusion is delegated to
//     FaceLandmarkService.averageEmbeddings() which dispatches to
//     weightedAverageEmbeddings() (pairwise similarity, outlier rejection,
//     quality-weighted blend, L2 normalisation).
//   - Dynamic group splitting — group sizes computed from the accepted
//     embedding count at runtime so the builder works for any N >= 3.
//   - Dynamic identity weights — normalised to sum exactly 1.0 based on
//     which stored templates are actually present; gracefully handles
//     missing A / B / C / Master combinations.
//   - Structured result objects — diagnostics are carried in typed classes
//     rather than scattered state variables, enabling clean logging from
//     the caller.

import '../services/face_landmark_service.dart';

// --- Group sizes -------------------------------------------------------------

class CalibrationGroupSizes {
  final int a;
  final int b;
  final int c;

  const CalibrationGroupSizes({
    required this.a,
    required this.b,
    required this.c,
  });

  @override
  String toString() => 'A=$a, B=$b, C=$c';
}

// --- Fused live template -----------------------------------------------------

class CalibrationLiveTemplate {
  /// Group A fused embedding (first ceil(N/3) accepted frames).
  final List<double> liveA;

  /// Group B fused embedding (next ceil(N/3) accepted frames).
  final List<double> liveB;

  /// Group C fused embedding (remaining frames).
  final List<double> liveC;

  /// Master embedding fused from liveA, liveB, liveC.
  /// This is compared against the stored registration templates for the
  /// identity decision, mirroring how the registration master is built.
  final List<double> liveMaster;

  /// The group sizes used during this fusion.
  final CalibrationGroupSizes groupSizes;

  /// Fusion quality of the liveMaster (0-100); sourced from
  /// FaceLandmarkService.lastFusionQuality after the master fusion call.
  final double fusionQuality;

  /// Fusion confidence of the liveMaster (0.0-1.0).
  final double fusionConfidence;

  /// Mean intra-frame cosine similarity during master fusion.
  final double fusionSimilarity;

  /// Variance of accepted embeddings relative to the fused master.
  final double fusionVariance;

  const CalibrationLiveTemplate({
    required this.liveA,
    required this.liveB,
    required this.liveC,
    required this.liveMaster,
    required this.groupSizes,
    required this.fusionQuality,
    required this.fusionConfidence,
    required this.fusionSimilarity,
    required this.fusionVariance,
  });
}

// --- Identity result ---------------------------------------------------------

class CalibrationIdentityResult {
  /// Whether the identity check passed the threshold.
  final bool passed;

  /// Weighted identity score computed from template-to-template comparisons.
  final double identityScore;

  // Per-template cosine similarities — each live sub-template compared against
  // its corresponding stored registration sub-template (template ↔ template).

  /// Similarity of liveMaster to stored Master template (0.0 if absent).
  final double simMaster;

  /// Similarity of liveA to stored Embedding A (0.0 if absent).
  final double simA;

  /// Similarity of liveB to stored Embedding B (0.0 if absent).
  final double simB;

  /// Similarity of liveC to stored Embedding C (0.0 if absent).
  final double simC;

  // Per-template weights (dynamic, normalised to sum 1.0)

  final double weightMaster;
  final double weightA;
  final double weightB;
  final double weightC;

  // Template availability flags

  final bool hasMaster;
  final bool hasA;
  final bool hasB;
  final bool hasC;

  /// The stable live template produced during this session.
  final CalibrationLiveTemplate liveTemplate;

  const CalibrationIdentityResult({
    required this.passed,
    required this.identityScore,
    required this.simMaster,
    required this.simA,
    required this.simB,
    required this.simC,
    required this.weightMaster,
    required this.weightA,
    required this.weightB,
    required this.weightC,
    required this.hasMaster,
    required this.hasA,
    required this.hasB,
    required this.hasC,
    required this.liveTemplate,
  });

  /// Human-readable decision label.
  String get decision => passed ? 'PASS' : 'FAIL';
}

// --- Builder -----------------------------------------------------------------

class CalibrationTemplateBuilder {
  // Private constructor — this is a pure-static utility class.
  CalibrationTemplateBuilder._();

  // Dynamic group split
  //
  // Distributes N accepted embeddings into 3 groups as evenly as possible.
  // Remainder frames go to earlier groups so the last group is never larger
  // than the first two.
  //
  // Distribution formula (standard "round-robin remainder"):
  //   base = N div 3  (integer division)
  //   rem  = N mod 3
  //   s1   = base + 1  if rem >= 1,  else base
  //   s2   = base + 1  if rem >= 2,  else base
  //   s3   = N - s1 - s2
  //
  // Examples:
  //   N = 8  -> [3, 3, 2]  (matches the originally intended split)
  //   N = 9  -> [3, 3, 3]
  //   N = 15 -> [5, 5, 5]  (identical to registration)
  //   N = 7  -> [3, 2, 2]
  //   N = 6  -> [2, 2, 2]
  //   N = 4  -> [2, 1, 1]
  //   N = 3  -> [1, 1, 1]
  static CalibrationGroupSizes computeGroupSizes(int n) {
    // Safety guard: n < 3 should never occur in normal calibration flow
    // because the minimum accepted-frame gate is enforced upstream.
    final int safe = n < 3 ? 3 : n;
    final int base = safe ~/ 3;
    final int rem  = safe % 3;
    final int s1   = base + (rem >= 1 ? 1 : 0);
    final int s2   = base + (rem >= 2 ? 1 : 0);
    final int s3   = safe - s1 - s2;
    return CalibrationGroupSizes(a: s1, b: s2, c: s3);
  }

  // Live template fusion
  //
  // Mirrors the registration pipeline:
  //   accepted embeddings -> split into 3 groups -> fuse each group ->
  //   Live A / Live B / Live C -> fuse into Live Master.
  //
  // All fusion is delegated to FaceLandmarkService.averageEmbeddings()
  // (no duplicate algorithm - reuses the same weighted fusion + outlier
  // rejection + L2 normalisation as registration).
  //
  // The Expando in FaceLandmarkService records each group output's quality so
  // the subsequent master-fusion call can quality-weight liveA/B/C correctly.
  //
  // Fusion diagnostics (quality, confidence, similarity, variance) are
  // captured from FaceLandmarkService after the final master fusion call.
  static CalibrationLiveTemplate buildLiveTemplate({
    required List<List<double>> acceptedEmbeddings,
    required FaceLandmarkService landmarkService,
  }) {
    final CalibrationGroupSizes sizes =
        computeGroupSizes(acceptedEmbeddings.length);

    final List<List<double>> groupA =
        acceptedEmbeddings.sublist(0, sizes.a);
    final List<List<double>> groupB =
        acceptedEmbeddings.sublist(sizes.a, sizes.a + sizes.b);
    final List<List<double>> groupC =
        acceptedEmbeddings.sublist(sizes.a + sizes.b);

    // Fuse each group using the same weighted fusion as registration.
    final List<double> liveA = landmarkService.averageEmbeddings(groupA);
    final List<double> liveB = landmarkService.averageEmbeddings(groupB);
    final List<double> liveC = landmarkService.averageEmbeddings(groupC);

    // Build Live Master from the three sub-templates (mirrors registration master).
    final List<double> liveMaster =
        landmarkService.averageEmbeddings([liveA, liveB, liveC]);

    // Capture fusion diagnostics set by the master fusion call.
    return CalibrationLiveTemplate(
      liveA:            liveA,
      liveB:            liveB,
      liveC:            liveC,
      liveMaster:       liveMaster,
      groupSizes:       sizes,
      fusionQuality:    landmarkService.lastFusionQuality,
      fusionConfidence: landmarkService.lastFusionConfidence,
      fusionSimilarity: landmarkService.lastAverageSimilarity,
      fusionVariance:   landmarkService.lastEmbeddingVariance,
    );
  }

  // Weighted identity decision — Stable Template ↔ Stable Template
  //
  // Each live sub-template is compared ONLY against its corresponding stored
  // registration sub-template (same group index).  This mirrors how the
  // registration templates were originally built and eliminates the noise
  // introduced by comparing individual live frames against stored templates.
  //
  //   simA      = cosine(liveA,      storedA)
  //   simB      = cosine(liveB,      storedB)
  //   simC      = cosine(liveC,      storedC)
  //   simMaster = cosine(liveMaster, storedMaster)
  //
  // Weight policy (vote-based, renormalised dynamically):
  //   Master template → 3 votes  (highest influence, mirrors its role in reg)
  //   Each auxiliary  → 1 vote   (A, B, C)
  //   weight_i = votes_i / total_votes
  //
  // This ensures weights always sum to exactly 1.0 regardless of which
  // templates are present, and gracefully degrades when templates are missing.
  //
  // Examples (all present M+A+B+C, total=6):
  //   Master = 3/6 = 0.5000,  A = B = C = 1/6 ≈ 0.1667
  //
  // Partial examples:
  //   M+A+B only (total=5):  M=3/5=0.6000,  A=B=1/5=0.2000,  C=0.0
  //   M only     (total=3):  M=3/3=1.0000,  A=B=C=0.0
  //   A+B+C only (total=3):  A=B=C=1/3=0.3333, M=0.0
  static CalibrationIdentityResult computeIdentity({
    required CalibrationLiveTemplate liveTemplate,
    required List<double>? storedA,
    required List<double>? storedB,
    required List<double>? storedC,
    required List<double>? storedMaster,
    required FaceLandmarkService landmarkService,
    double identityThreshold = 0.75,
  }) {
    final bool hasMaster = storedMaster != null && storedMaster.isNotEmpty;
    final bool hasA      = storedA     != null && storedA.isNotEmpty;
    final bool hasB      = storedB     != null && storedB.isNotEmpty;
    final bool hasC      = storedC     != null && storedC.isNotEmpty;

    // Template-to-template comparisons — each live sub-template paired with
    // its corresponding stored sub-template.  Raw-frame comparisons are
    // intentionally absent; individual frame noise is already eliminated by
    // the fusion step above.
    final double simMaster = hasMaster
        ? landmarkService.cosineSimilarity(liveTemplate.liveMaster, storedMaster)
        : 0.0;
    final double simA = hasA
        ? landmarkService.cosineSimilarity(liveTemplate.liveA, storedA)
        : 0.0;
    final double simB = hasB
        ? landmarkService.cosineSimilarity(liveTemplate.liveB, storedB)
        : 0.0;
    final double simC = hasC
        ? landmarkService.cosineSimilarity(liveTemplate.liveC, storedC)
        : 0.0;

    // Dynamic vote allocation.
    const int masterVotes = 3;
    const int auxVotes    = 1;

    final int totalVotes =
        (hasMaster ? masterVotes : 0) +
        (hasA      ? auxVotes    : 0) +
        (hasB      ? auxVotes    : 0) +
        (hasC      ? auxVotes    : 0);

    // Normalised weights — sum to 1.0 exactly.
    final double wMaster =
        (totalVotes > 0 && hasMaster) ? masterVotes / totalVotes : 0.0;
    final double wA =
        (totalVotes > 0 && hasA)      ? auxVotes    / totalVotes : 0.0;
    final double wB =
        (totalVotes > 0 && hasB)      ? auxVotes    / totalVotes : 0.0;
    final double wC =
        (totalVotes > 0 && hasC)      ? auxVotes    / totalVotes : 0.0;

    // Weighted identity score — no frame-level averaging, no nested loops.
    final double identityScore = totalVotes > 0
        ? simMaster * wMaster + simA * wA + simB * wB + simC * wC
        : 0.0;

    return CalibrationIdentityResult(
      passed:        identityScore >= identityThreshold,
      identityScore: identityScore,
      simMaster:     simMaster,
      simA:          simA,
      simB:          simB,
      simC:          simC,
      weightMaster:  wMaster,
      weightA:       wA,
      weightB:       wB,
      weightC:       wC,
      hasMaster:     hasMaster,
      hasA:          hasA,
      hasB:          hasB,
      hasC:          hasC,
      liveTemplate:  liveTemplate,
    );
  }
}
