"""
Face API routes — embedding generation endpoint.

POST /api/embed
  Accepts multipart/form-data with 1–9 image files (field: "images").
  Returns JSON with 512-dim L2-normalised ArcFace embeddings
  plus per-frame quality diagnostics.
"""

from __future__ import annotations

import cv2
import numpy as np
from fastapi import APIRouter, File, UploadFile, HTTPException

from app.services.face_service import face_service

router = APIRouter(prefix="/api", tags=["face"])


@router.post("/embed")
async def embed(images: list[UploadFile] = File(...)):
    """
    Generate ArcFace embeddings for uploaded face images.

    Parameters
    ----------
    images : list[UploadFile]
        1–9 JPEG image files.

    Returns
    -------
    dict
        {
            "embeddings": [ [512 floats] | null, ... ],
            "faces_detected": [ int, ... ],
            "quality": [ { passed, reasons, blur_score, face_area, yaw, pitch }, ... ]
        }
    """
    if not images:
        raise HTTPException(status_code=400, detail="No images provided")

    if len(images) > 9:
        raise HTTPException(status_code=400, detail="Maximum 9 images per request")

    # Decode all images to BGR numpy arrays
    bgr_images: list[np.ndarray] = []

    for idx, upload in enumerate(images):
        raw = await upload.read()
        if not raw:
            raise HTTPException(
                status_code=400,
                detail=f"Image {idx} is empty",
            )

        # Decode JPEG/PNG bytes → BGR via OpenCV
        arr = np.frombuffer(raw, dtype=np.uint8)
        img = cv2.imdecode(arr, cv2.IMREAD_COLOR)

        if img is None:
            raise HTTPException(
                status_code=400,
                detail=f"Image {idx} could not be decoded",
            )

        print(f"Image {idx}: {img.shape}")

        # Auto-rotate landscape images to portrait.
        # Flutter sends YUV frames converted to JPEG in landscape orientation
        # (e.g. 1280x720). InsightFace alignment quality degrades on sideways
        # faces because the 5-point landmark model was trained on upright faces.
        # Rotating to portrait before processing significantly improves
        # embedding consistency across different positions and lighting.
        h, w = img.shape[:2]
        if w > h:
            # Landscape — rotate 90° counter-clockwise to get portrait
            img = cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)

        bgr_images.append(img)

    # Generate embeddings via InsightFace (with preprocessing + quality gates)
    results = face_service.get_embeddings(bgr_images)

    # Build response
    embeddings_out: list[list[float] | None] = []
    faces_detected: list[int] = []
    quality_out: list[dict] = []

    for res in results:
        if res.embedding is not None:
            embeddings_out.append(res.embedding.tolist())
            faces_detected.append(1)
        else:
            embeddings_out.append(None)
            faces_detected.append(0)
        quality_out.append(res.quality.to_dict())

    return {
        "embeddings": embeddings_out,
        "faces_detected": faces_detected,
        "quality": quality_out,
    }
