"""
InsightFace buffalo_l wrapper service.

Singleton that loads the model once at startup and provides
embedding generation from raw image bytes.

Pipeline per image:
  1. Mild CLAHE illumination normalization (LAB L-channel)
  2. InsightFace face detection + alignment
  3. Quality gates (blur, face size, pose)
  4. ArcFace embedding extraction (512-dim)
  5. L2 normalization
"""

import numpy as np
from insightface.app import FaceAnalysis

from app.utils.preprocessing import (
    normalize_illumination,
    check_blur,
    check_face_size,
    check_pose,
    QualityInfo,
)


class EmbeddingResult:
    """Result for a single image: embedding + quality diagnostics."""

    __slots__ = ("embedding", "quality")

    def __init__(self, embedding: np.ndarray | None, quality: QualityInfo):
        self.embedding = embedding
        self.quality = quality


class FaceService:
    """Wraps InsightFace FaceAnalysis as a reusable singleton."""

    def __init__(self):
        self._app: FaceAnalysis | None = None

    # ── Startup ────────────────────────────────────────────────────────────

    def init_model(
        self,
        model_name: str = "buffalo_l",
        root: str = ".",
        providers: list[str] | None = None,
        det_size: tuple[int, int] = (640, 640),
    ) -> None:
        """Load the InsightFace model pack.  Call once at app startup."""
        if self._app is not None:
            return  # already loaded

        if providers is None:
            providers = ["CPUExecutionProvider"]

        self._app = FaceAnalysis(
            name=model_name,
            root=root,
            providers=providers,
        )
        self._app.prepare(ctx_id=0, det_size=det_size)
        print(f"[FaceService] Model '{model_name}' loaded  (providers={providers})")

    # ── Core API ───────────────────────────────────────────────────────────

    def get_embeddings(
        self, images: list[np.ndarray]
    ) -> list[EmbeddingResult]:
        """
        Generate L2-normalised ArcFace embeddings for a batch of BGR images.

        For each image:
          1. Apply mild CLAHE illumination normalization
          2. Run InsightFace detection + alignment
          3. Run quality gates (blur, face size, pose)
          4. Extract + L2-normalize embedding

        Parameters
        ----------
        images : list[np.ndarray]
            List of BGR images (OpenCV format, uint8).

        Returns
        -------
        list[EmbeddingResult]
            Each result contains the embedding (or None) plus quality info.
        """
        if self._app is None:
            raise RuntimeError("FaceService.init_model() has not been called")

        results: list[EmbeddingResult] = []

        for img in images:
            qi = QualityInfo()

            # ── 1. Blur check on raw image ────────────────────────────────
            blur_ok, blur_score = check_blur(img, threshold=30.0)
            qi.blur_score = blur_score
            if not blur_ok:
                qi.passed = False
                qi.reasons.append(f"blur={blur_score:.1f}<30")
                print(f"[FaceService] QUALITY GATE: blur rejected (score={blur_score:.1f})")

            # ── 2. Mild illumination normalization ────────────────────────
            # Applied ALWAYS (registration + verification) for consistency
            normalized = normalize_illumination(img)

            # ── 3. InsightFace detection + alignment ──────────────────────
            faces = self._app.get(normalized)

            if not faces:
                qi.passed = False
                qi.reasons.append("no_face_detected")
                results.append(EmbeddingResult(None, qi))
                continue

            # Pick the largest face (by bounding-box area)
            best = max(
                faces,
                key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]),
            )

            # ── 4. Face size gate ─────────────────────────────────────────
            size_ok, face_frac = check_face_size(best, normalized.shape, min_fraction=0.02)
            qi.face_area = face_frac
            if not size_ok:
                qi.passed = False
                qi.reasons.append(f"face_too_small={face_frac:.3f}<0.02")
                print(f"[FaceService] QUALITY GATE: face too small ({face_frac:.3f})")

            # ── 5. Pose gate ──────────────────────────────────────────────
            pose_ok, yaw, pitch = check_pose(best, max_yaw=40.0, max_pitch=30.0)
            qi.yaw = yaw
            qi.pitch = pitch
            if not pose_ok:
                qi.passed = False
                qi.reasons.append(f"extreme_pose yaw={yaw:.1f} pitch={pitch:.1f}")
                print(f"[FaceService] QUALITY GATE: extreme pose (yaw={yaw:.1f}, pitch={pitch:.1f})")

            # ── 6. If any hard gate failed, still return embedding ────────
            # We return the embedding even if quality gates failed so the
            # caller can decide whether to use it.  The quality info lets
            # the Flutter side log why a frame was weak.
            emb = best.embedding  # raw 512-dim float32

            # L2 normalise
            norm = np.linalg.norm(emb)
            if norm > 1e-10:
                emb = emb / norm

            results.append(EmbeddingResult(emb, qi))

        return results


# Module-level singleton — imported by routes
face_service = FaceService()
