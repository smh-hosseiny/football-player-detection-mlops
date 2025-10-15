import mlflow
from ultralytics import YOLO

mlflow.set_tracking_uri("http://localhost:5000")  # Run `mlflow ui` locally first
mlflow.set_experiment("object-detection")

with mlflow.start_run():
    model = YOLO("yolov8n.pt")
    mlflow.log_params({"epochs": 50, "imgsz": 640})

    results = model.train(data="dataset.yaml", epochs=50)
    mlflow.log_metric("mAP", results.box.map)

    mlflow.pytorch.log_model(model, "model")
