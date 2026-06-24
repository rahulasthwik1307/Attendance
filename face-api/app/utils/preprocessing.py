"""
Image preprocessing utilities for face embedding quality.

Applied IDENTICALLY for both registration and verification frames
on the server side, ensuring consistent embeddings across lighting
conditions.

- Mild CLAHE on luminance channel (helps in dark/cloudy rooms)
- Blur quality gate (Laplacian variance)
- Face-size quality gate (minimum bounding-box area)
- Pose quality gate (extreme yaw/pitch rejection)
"""

from __future__ import annotations

import cv2
import numpy as np


# ── Illumination normalization ─────────────────────────────────────────────

def normalize_illumination(bgr: np.ndarray) -> np.ndarray:
    """
    Apply mild CLAHE on the L channel (LAB space) to reduce the
    impact of dim / uneven lighting while preserving colour.

    Parameters are intentionally conservative:
      clipLimit=1.5  (gentle — avoids amplifying noise)
      tileGridSize=8×8
    """
    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB)
    l_ch, a_ch, b_ch = cv2.split(lab)

    clahe = cv2.createCLAHE(clipLimit=1.5, tileGridSize=(8, 8))
    l_eq = clahe.apply(l_ch)

    merged = cv2.merge([l_eq, a_ch, b_ch])
    result = cv2.cvtColor(merged, cv2.COLOR_LAB2BGR)
    return result


# ── Quality gates ──────────────────────────────────────────────────────────

class QualityInfo:
    """Result of quality checks for one image."""

    __slots__ = ("passed", "reasons", "blur_score", "face_area", "yaw", "pitch")

    def __init__(self):
        self.passed: bool = True
        self.reasons: list[str] = []
        self.blur_score: float = 0.0
        self.face_area: float = 0.0
        self.yaw: float = 0.0
        self.pitch: float = 0.0

    def to_dict(self) -> dict:
        return {
            "passed": self.passed,
            "reasons": self.reasons,
            "blur_score": round(self.blur_score, 2),
            "face_area": round(self.face_area, 2),
            "yaw": round(self.yaw, 2),
            "pitch": round(self.pitch, 2),
        }


def check_blur(bgr: np.ndarray, threshold: float = 30.0) -> tuple[bool, float]:
    """
    Laplacian-variance blur detection.
    Returns (is_sharp_enough, variance_score).

    A score < threshold means the image is too blurry.
    threshold=30 is lenient — catches only severely blurred frames.
    """
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    variance = cv2.Laplacian(gray, cv2.CV_64F).var()
    return variance >= threshold, float(variance)


def check_face_size(face, image_shape: tuple, min_fraction: float = 0.02) -> tuple[bool, float]:
    """
    Reject faces whose bounding-box area is too small relative to
    the image.  min_fraction=0.02 means face must occupy at least 2%
    of image area.
    """
    h, w = image_shape[:2]
    image_area = h * w
    bbox = face.bbox  # [x1, y1, x2, y2]
    face_area = (bbox[2] - bbox[0]) * (bbox[3] - bbox[1])
    fraction = face_area / image_area if image_area > 0 else 0
    return fraction >= min_fraction, float(fraction)


def check_pose(face, max_yaw: float = 40.0, max_pitch: float = 30.0) -> tuple[bool, float, float]:
    """
    Reject extreme head poses using InsightFace's pose estimation.
    Generous limits — only catches very sideways/tilted faces.
    """
    pose = getattr(face, "pose", None)
    if pose is None or len(pose) < 2:
        # If InsightFace didn't provide pose, pass by default
        return True, 0.0, 0.0

    yaw = float(pose[1])    # left-right rotation
    pitch = float(pose[0])  # up-down rotation

    ok = abs(yaw) <= max_yaw and abs(pitch) <= max_pitch
    return ok, yaw, pitch
