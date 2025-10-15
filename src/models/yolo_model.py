from datetime import datetime

import mlflow
import wandb
import yaml
from ultralytics import YOLO


class YOLOTrainer:
    def __init__(self, config_path):
        with open(config_path, "r") as f:
            self.config = yaml.safe_load(f)

        self.model = YOLO(self.config["model"]["architecture"])
        self.setup_experiment_tracking()

    def setup_experiment_tracking(self):
        # MLflow setup
        mlflow.set_tracking_uri(self.config["mlflow"]["tracking_uri"])
        mlflow.set_experiment(self.config["mlflow"]["experiment_name"])

        # W&B setup (optional, choose one)
        if self.config.get("wandb", {}).get("enabled", False):
            wandb.init(project=self.config["wandb"]["project"], config=self.config)

    def train(self):
        # Start MLflow run
        with mlflow.start_run():
            # Log parameters
            mlflow.log_params(
                {
                    "model_architecture": self.config["model"]["architecture"],
                    "batch_size": self.config["training"]["batch_size"],
                    "epochs": self.config["training"]["epochs"],
                    "learning_rate": self.config["training"]["learning_rate"],
                }
            )

            # Train model
            results = self.model.train(
                data=self.config["data"]["yaml_path"],
                epochs=self.config["training"]["epochs"],
                batch=self.config["training"]["batch_size"],
                imgsz=self.config["model"]["img_size"],
                lr0=self.config["training"]["learning_rate"],
                device=self.config["device"],
                project=self.config["output"]["project_dir"],
                name=f"run_{datetime.now().strftime('%Y%m%d_%H%M%S')}",
                save=True,
                save_period=10,
                val=True,
            )

            # Log metrics
            for metric_name, metric_value in results.results_dict.items():
                mlflow.log_metric(metric_name, metric_value)

            # Save and log model
            self.model.export(format="onnx")  # Export to ONNX for optimization

            mlflow.pytorch.log_model(
                pytorch_model=self.model.model,
                artifact_path="model",
                registered_model_name=self.config["model"]["name"],
            )

            # Log artifacts
            mlflow.log_artifacts(self.config["output"]["project_dir"])

            return results

    def evaluate(self, test_data_path):
        metrics = self.model.val(data=test_data_path)
        return metrics
