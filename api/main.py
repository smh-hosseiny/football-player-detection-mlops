from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import torch
import cv2
import numpy as np
from PIL import Image
import io
import time
from prometheus_client import Counter, Histogram, generate_latest
import logging
from typing import List, Dict
import asyncio
import os
from concurrent.futures import ThreadPoolExecutor

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Prometheus metrics
prediction_counter = Counter('predictions_total', 'Total predictions made')
prediction_latency = Histogram('prediction_latency_seconds', 'Prediction latency')
model_errors = Counter('model_errors_total', 'Total model errors')

app = FastAPI(title="Object Detection API", version="1.0.0")

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class ObjectDetector:
    def __init__(self, model_path: str, device: str = 'cpu'):
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
                self.executor,
                self._run_inference,
                image
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
                        'bbox': box.xyxy[0].tolist(),
                        'confidence': float(box.conf[0]),
                        'class': int(box.cls[0]),
                        'class_name': self.model.names[int(box.cls[0])]
                    }
                    detections.append(detection)
        
        return {
            'detections': detections,
            'num_objects': len(detections),
            'inference_time_ms': results[0].speed['inference']
        }



# Initialize model
detector = ObjectDetector(
    model_path='src/models/best.pt',
    device='cuda' if torch.cuda.is_available() else 'cpu'
)

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy", "device": detector.device}


@app.post("/predict")
async def predict(file: UploadFile = File(...)):
    """Main prediction endpoint"""
    start_time = time.time()
    
    # Validate file
    if not file.content_type.startswith('image/'):
        raise HTTPException(status_code=400, detail="File must be an image")
    
    # Read and process image
    contents = await file.read()
    image = Image.open(io.BytesIO(contents))
    image_np = np.array(image)
    
    # Get predictions
    results = await detector.predict(image_np)
    
    # Add metadata
    results['processing_time_ms'] = (time.time() - start_time) * 1000
    results['image_size'] = image.size
    
    return JSONResponse(content=results)

@app.get("/metrics")
async def metrics():
    """Prometheus metrics endpoint"""
    return generate_latest()

@app.post("/batch_predict")
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
        result['filename'] = file.filename
        results.append(result)
    
    return JSONResponse(content={'results': results})



@app.post("/predict_video")
async def predict_video(file: UploadFile = File(...)):
    if not file.content_type.startswith('video/'):
        raise HTTPException(status_code=400, detail="File must be a video")
    contents = await file.read()

    # Save the uploaded video to a temporary file
    with open("temp_video.mp4", "wb") as f:
        f.write(contents)

    cap = cv2.VideoCapture("temp_video.mp4")
    video_detections = []
    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break
        results = await detector.predict(frame)  # Same as image, but per frame
        video_detections.append(results['detections'])
    cap.release()
    os.remove("temp_video.mp4")
    return JSONResponse(content={'video_detections': video_detections})

@app.get("/")
async def root():
    return {"message": "YOLO API is running!"}
