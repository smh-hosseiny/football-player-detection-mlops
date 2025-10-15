import argparse
import shutil
from datetime import datetime
from pathlib import Path

import mlflow
import mlflow.pytorch
import torch
import yaml
from ultralytics import YOLO


def on_fit_epoch_end(trainer):
    """Callback to log metrics after each epoch"""
    metrics = trainer.metrics
    epoch = trainer.epoch

    # Log training losses
    if hasattr(trainer, "loss_items"):
        mlflow.log_metric("train/box_loss", float(trainer.loss_items[0]), step=epoch)
        mlflow.log_metric("train/cls_loss", float(trainer.loss_items[1]), step=epoch)
        mlflow.log_metric("train/dfl_loss", float(trainer.loss_items[2]), step=epoch)

    # Log validation metrics
    if metrics:
        mlflow.log_metric(
            "metrics/mAP50", float(metrics.get("metrics/mAP50(B)", 0)), step=epoch
        )
        mlflow.log_metric(
            "metrics/mAP50-95", float(metrics.get("metrics/mAP50-95(B)", 0)), step=epoch
        )


class YOLOTrainer:
    def __init__(self, config_path: str):
        with open(config_path, "r") as f:
            self.config = yaml.safe_load(f)

        init_weights = Path("src/models/best.pt")
        arch = self.config["model"]["architecture"]

        if init_weights.exists():
            self.model = YOLO(str(init_weights))
            print(f"Using initialization weights: {init_weights}")
        else:
            self.model = YOLO(arch)
            print(f"Using architecture: {arch}")

    def train(self):
        init_val_score = None
        init_weights = Path("src/models/best.pt")

        # ✅ Step 1: Evaluate the initial checkpoint if it exists
        if init_weights.exists():
            print("Evaluating initial checkpoint before training...")
            init_metrics = self.model.val(data=self.config["data"]["yaml_path"])
            init_val_score = init_metrics.box.map
            print(f"Initial checkpoint mAP50-95: {init_val_score:.4f}")

        try:
            # Directly train with log_mlflow enabled for automatic MLflow logging
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
                val=True,
            )

            # ✅ Step 3: Locate the new best.pt
            new_best_path = Path(results.save_dir) / "weights" / "best.pt"
            final_best_path = Path("src/models/best.pt")

            new_val_score = None
            if new_best_path.exists():
                # Evaluate the new best model
                new_model = YOLO(str(new_best_path))
                new_metrics = new_model.val(data=self.config["data"]["yaml_path"])
                new_val_score = new_metrics.box.map
                print(f"\nNew best mAP50-95: {new_val_score:.4f}")

            # ✅ Step 4: Compare and decide which to keep
            if new_val_score is not None and (
                init_val_score is None or new_val_score >= init_val_score
            ):
                # New model is better or no init checkpoint
                shutil.copy(new_best_path, final_best_path)
                print(f"✅ Replaced global best.pt with new model ({new_val_score:.4f})")
            elif init_val_score is not None:
                # Initial checkpoint is better — keep it
                print(
                    f"⚠️ Keeping existing best.pt (initial was \
                    better: {init_val_score:.4f})"
                )

            # Log the chosen best.pt file to MLflow
            try:
                mlflow.pytorch.log_model(
                    pytorch_model=torch.load(final_best_path)[
                        "model"
                    ],  # load final chosen model
                    artifact_path="model",
                    registered_model_name=self.config["model"]["name"],
                )
                print("✅ Final model logged to MLflow.")
            except Exception as e:
                print(f"Failed to log model: {e}")

            return results

        except Exception as e:
            print(f"Training failed: {e}")
            mlflow.end_run(status="FAILED")
            raise

    def evaluate(self):
        return self.model.val(data=self.config["data"]["yaml_path"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train YOLO model with a config file")
    parser.add_argument(
        "--config",
        type=str,
        required=True,
        help="Path to the training configuration YAML file",
    )
    args = parser.parse_args()

    trainer = YOLOTrainer(config_path=args.config)
    train_results = trainer.train()
    val_metrics = trainer.evaluate()
    print(f"Validation mAP50-95: {val_metrics.box.map:.4f}")
