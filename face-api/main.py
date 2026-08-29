"""
Face Recognition API — InsightFace buffalo_l

Entry point for the FastAPI service.
Loads the InsightFace model once at startup and exposes:
  GET  /health      — liveness probe
  POST /api/embed   — generate ArcFace 512-dim embeddings from images
"""

import os

from contextlib import asynccontextmanager
from fastapi import FastAPI

from app.services.face_service import face_service
from app.routes.face import router as face_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load the InsightFace model at startup, clean up on shutdown."""
    providers = os.getenv("ONNX_PROVIDERS", "CPUExecutionProvider").split(",")
    face_service.init_model(
        model_name="buffalo_l",
        root=".",
        providers=providers,
        det_size=(640, 640),
    )
    yield
    # Shutdown — nothing to clean up (ONNX sessions release automatically)


app = FastAPI(
    title="Attendance Face API",
    version="1.0.0",
    lifespan=lifespan,
)

# ── Routes ─────────────────────────────────────────────────────────────────
app.include_router(face_router)


@app.get("/health")
async def health():
    """Liveness / readiness probe."""
    return {"status": "ok", "model": "buffalo_l"}
