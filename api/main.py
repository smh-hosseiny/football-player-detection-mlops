import asyncio
import io
import logging
import os
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, List

import cv2
import numpy as np
import torch
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.requests import Request
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from PIL import Image
from prometheus_client import Counter, Histogram, generate_latest

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Prometheus metrics
prediction_counter = Counter("predictions_total", "Total predictions made")
prediction_latency = Histogram("prediction_latency_seconds", "Prediction latency")
model_errors = Counter("model_errors_total", "Total model errors")

app = FastAPI(title="Object Detection API", version="1.0.0")

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount("/static", StaticFiles(directory="static"), name="static")


class ObjectDetector:
    def __init__(self, model_path: str, device: str = "cpu"):
        self.device = device
        self.model = self.load_model(model_path)
        self.executor = ThreadPoolExecutor(max_workers=4)

    def load_model(self, model_path: str):
        """Load YOLOv11 model"""
        from ultralytics import YOLO

        model = YOLO(model_path)
        model.to(self.device)
        logger.info(f"Model loaded on {self.device}")
        return model

    @prediction_latency.time()
    async def predict(self, image: np.ndarray) -> Dict:
        """Run inference on image"""
        prediction_counter.inc()

        try:
            # Run inference in thread pool to avoid blocking
            loop = asyncio.get_event_loop()
            results = await loop.run_in_executor(
                self.executor, self._run_inference, image
            )

            return self._process_results(results)

        except Exception as e:
            model_errors.inc()
            logger.error(f"Prediction error: {str(e)}")
            raise HTTPException(status_code=500, detail=str(e))

    def _run_inference(self, image: np.ndarray):
        """Actual inference logic"""
        return self.model(image)

    def _process_results(self, results) -> Dict:
        """Process YOLO results to JSON format"""
        detections = []

        for r in results:
            boxes = r.boxes
            if boxes is not None:
                for box in boxes:
                    detection = {
                        "bbox": box.xyxy[0].tolist(),
                        "confidence": float(box.conf[0]),
                        "class": int(box.cls[0]),
                        "class_name": self.model.names[int(box.cls[0])],
                    }
                    detections.append(detection)

        return {
            "detections": detections,
            "num_objects": len(detections),
            "inference_time_ms": results[0].speed["inference"],
        }


# Initialize model
detector = ObjectDetector(
    model_path="src/models/best.pt",
    device="cuda" if torch.cuda.is_available() else "cpu",
)


@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy", "device": detector.device}


@app.post("/api/predict")
async def predict(file: UploadFile = File(...)):
    start_time = time.time()
    try:
        contents = await file.read()
        image = Image.open(io.BytesIO(contents))
        image_np = np.array(image)
        results = await detector.predict(image_np)
        results["processing_time_ms"] = (time.time() - start_time) * 1000
        results["image_size"] = image.size
        return JSONResponse(content=results)
    except Exception as e:
        logger.exception("Error in /predict")
        return JSONResponse(content={"error": str(e)}, status_code=500)


@app.post("/api/predict_video")
async def predict_video(file: UploadFile = File(...)):
    # Create unique temp file
    temp_filename = f"temp_{uuid.uuid4().hex}.mp4"

    # Save uploaded video
    contents = await file.read()
    with open(temp_filename, "wb") as f:
        f.write(contents)

    cap = cv2.VideoCapture(temp_filename)
    # ✨ GET THE REAL FPS FROM THE VIDEO FILE
    fps = cap.get(cv2.CAP_PROP_FPS)

    video_detections = []

    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break

        results = await detector.predict(frame)
        video_detections.append(results["detections"])

    cap.release()
    os.remove(temp_filename)

    # ✨ SEND THE FPS BACK TO THE FRONTEND
    return JSONResponse(content={"video_detections": video_detections, "fps": fps})


@app.get("/metrics")
async def metrics():
    """Prometheus metrics endpoint"""
    return generate_latest()


@app.post("/api/batch_predict")
async def batch_predict(files: List[UploadFile] = File(...)):
    """Batch prediction endpoint"""
    if len(files) > 10:
        raise HTTPException(status_code=400, detail="Maximum 10 images per batch")

    results = []
    for file in files:
        contents = await file.read()
        image = Image.open(io.BytesIO(contents))
        image_np = np.array(image)

        result = await detector.predict(image_np)
        result["filename"] = file.filename
        results.append(result)

    return JSONResponse(content={"results": results})


templates = Jinja2Templates(directory="static")


@app.get("/")
async def read_index(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})
