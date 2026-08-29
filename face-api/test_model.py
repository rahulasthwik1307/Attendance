import os
import cv2
import numpy as np
from insightface.app import FaceAnalysis

try:
    print("=" * 60)
    print("Current Directory:", os.getcwd())
    print("=" * 60)

    # Verify files exist
    reg_path = "test-images/registration.jpg"
    ver_path = "test-images/verification5.jpg"

    print("Registration Exists:", os.path.exists(reg_path))
    print("Verification Exists:", os.path.exists(ver_path))

    if not os.path.exists(reg_path):
        raise FileNotFoundError(f"File not found: {reg_path}")

    if not os.path.exists(ver_path):
        raise FileNotFoundError(f"File not found: {ver_path}")

    print("\nLoading InsightFace model...\n")

    # Load model from local models folder
    app = FaceAnalysis(
        name="buffalo_l",
        root=".",
        providers=["CPUExecutionProvider"]
    )

    app.prepare(
        ctx_id=0,
        det_size=(640, 640)
    )

    print("Model loaded successfully.\n")

    # Load images
    reg_img = cv2.imread(reg_path)
    ver_img = cv2.imread(ver_path)

    if reg_img is None:
        raise ValueError(f"Could not read {reg_path}")

    if ver_img is None:
        raise ValueError(f"Could not read {ver_path}")

    print("Images loaded successfully.\n")

    # Detect faces
    reg_faces = app.get(reg_img)
    ver_faces = app.get(ver_img)

    print(f"Faces found in registration: {len(reg_faces)}")
    print(f"Faces found in verification: {len(ver_faces)}")

    if len(reg_faces) == 0:
        raise ValueError("No face detected in registration image")

    if len(ver_faces) == 0:
        raise ValueError("No face detected in verification image")

    # Get first face embedding
    reg_emb = reg_faces[0].embedding
    ver_emb = ver_faces[0].embedding

    print(f"\nRegistration Embedding Length: {len(reg_emb)}")
    print(f"Verification Embedding Length: {len(ver_emb)}")

    # Cosine similarity
    similarity = np.dot(reg_emb, ver_emb) / (
        np.linalg.norm(reg_emb) * np.linalg.norm(ver_emb)
    )

    print("\n" + "=" * 60)
    print(f"Similarity Score: {similarity:.6f}")
    print("=" * 60)

    # Simple interpretation
    if similarity > 0.75:
        print("Likely SAME PERSON")
    else:
        print("Likely DIFFERENT PERSON")

except Exception as e:
    print("\nERROR:")
    print(str(e))