import asyncio
import io
import json
import logging
import os
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, List

import cv2
import numpy as np
import torch
from fastapi import (
    FastAPI,
    File,
    HTTPException,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
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

TEMP_VIDEO_PREFIX = "temp_"
TEMP_VIDEO_SUFFIX = ".mp4"


def session_path(session_id: str) -> str:
    """Derive temp file path from session ID."""
    return f"{TEMP_VIDEO_PREFIX}{session_id}{TEMP_VIDEO_SUFFIX}"


@app.on_event("startup")
async def start_session_cleanup():
    """Periodically clean up stale temp video files."""

    async def cleanup_loop():
        while True:
            await asyncio.sleep(300)
            now = time.time()
            import glob

            for path in glob.glob(f"{TEMP_VIDEO_PREFIX}*{TEMP_VIDEO_SUFFIX}"):
                try:
                    if now - os.path.getmtime(path) > 600:
                        os.remove(path)
                        logger.info(f"Cleaned up stale temp file {path}")
                except OSError:
                    pass

    asyncio.create_task(cleanup_loop())


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


@app.post("/api/upload_video")
async def upload_video(file: UploadFile = File(...)):
    """Upload video and return session metadata for WebSocket streaming."""
    session_id = uuid.uuid4().hex
    temp_filename = session_path(session_id)

    contents = await file.read()
    with open(temp_filename, "wb") as f:
        f.write(contents)

    cap = cv2.VideoCapture(temp_filename)
    if not cap.isOpened():
        os.remove(temp_filename)
        raise HTTPException(status_code=400, detail="Cannot open video file")

    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps = cap.get(cv2.CAP_PROP_FPS)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()

    return JSONResponse(
        content={
            "session_id": session_id,
            "total_frames": total_frames,
            "fps": fps,
            "width": width,
            "height": height,
        }
    )


@app.websocket("/ws/predict_video")
async def ws_predict_video(websocket: WebSocket):
    """Stream video detections frame-by-frame over WebSocket."""
    await websocket.accept()
    session_id = None
    temp_path = None

    try:
        # Wait for the "start" message from client
        raw = await websocket.receive_text()
        msg = json.loads(raw)

        if msg.get("action") != "start" or "session_id" not in msg:
            await websocket.send_json(
                {
                    "type": "error",
                    "message": "Expected {action: 'start', session_id: '...'}",
                }
            )
            await websocket.close()
            return

        session_id = msg["session_id"]
        frame_skip = max(1, int(msg.get("frame_skip", 1)))

        # Derive temp file path from session ID (works across workers)
        temp_path = session_path(session_id)
        if not os.path.exists(temp_path):
            await websocket.send_json(
                {
                    "type": "error",
                    "message": f"Session {session_id} not found. Upload video first.",
                }
            )
            await websocket.close()
            return
        cap = cv2.VideoCapture(temp_path)
        if not cap.isOpened():
            await websocket.send_json(
                {"type": "error", "message": "Cannot open video file"}
            )
            await websocket.close()
            return

        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = cap.get(cv2.CAP_PROP_FPS)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

        # Send start confirmation
        await websocket.send_json(
            {
                "type": "start",
                "session_id": session_id,
                "total_frames": total_frames,
                "fps": fps,
                "width": width,
                "height": height,
                "frame_skip": frame_skip,
            }
        )

        # Process frames
        frame_index = 0
        frames_processed = 0
        total_inference_ms = 0.0
        last_detections = []
        last_inference_ms = 0.0
        cancelled = False
        start_time = time.time()

        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                break

            is_keyframe = frame_index % frame_skip == 0

            if is_keyframe:
                loop = asyncio.get_event_loop()
                results = await loop.run_in_executor(
                    detector.executor, detector._run_inference, frame
                )
                processed = detector._process_results(results)
                last_detections = processed["detections"]
                last_inference_ms = processed["inference_time_ms"]
                total_inference_ms += last_inference_ms
                frames_processed += 1

            progress = (frame_index + 1) / total_frames if total_frames > 0 else 0

            await websocket.send_json(
                {
                    "type": "frame_result",
                    "frame_index": frame_index,
                    "detections": last_detections,
                    "is_keyframe": is_keyframe,
                    "inference_time_ms": last_inference_ms if is_keyframe else 0,
                    "progress": round(progress, 4),
                }
            )

            frame_index += 1

            # Non-blocking check for cancellation
            try:
                incoming = await asyncio.wait_for(
                    websocket.receive_text(), timeout=0.001
                )
                client_msg = json.loads(incoming)
                if client_msg.get("action") == "cancel":
                    cancelled = True
                    break
                elif client_msg.get("action") == "update_frame_skip":
                    frame_skip = max(1, int(client_msg.get("frame_skip", frame_skip)))
            except asyncio.TimeoutError:
                pass

        cap.release()

        # Send completion message
        elapsed = (time.time() - start_time) * 1000
        await websocket.send_json(
            {
                "type": "complete",
                "cancelled": cancelled,
                "total_frames_processed": frames_processed,
                "total_frames_sent": frame_index,
                "total_time_ms": round(elapsed, 1),
                "avg_inference_ms": round(
                    total_inference_ms / max(frames_processed, 1), 1
                ),
            }
        )

    except WebSocketDisconnect:
        logger.info(f"WebSocket disconnected for session {session_id}")
    except Exception as e:
        logger.exception(f"WebSocket error for session {session_id}")
        try:
            await websocket.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)


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
