import torch
from ultralytics import YOLO
import mlflow
import mlflow.pytorch
from pathlib import Path
import yaml
from datetime import datetime
import argparse
import shutil


def on_fit_epoch_end(trainer):
    """Callback to log metrics after each epoch"""
    metrics = trainer.metrics
    epoch = trainer.epoch
    
    # Log training losses
    if hasattr(trainer, 'loss_items'):
        mlflow.log_metric("train/box_loss", float(trainer.loss_items[0]), step=epoch)
        mlflow.log_metric("train/cls_loss", float(trainer.loss_items[1]), step=epoch)
        mlflow.log_metric("train/dfl_loss", float(trainer.loss_items[2]), step=epoch)
    
    # Log validation metrics
    if metrics:
        mlflow.log_metric("metrics/mAP50", float(metrics.get('metrics/mAP50(B)', 0)), step=epoch)
        mlflow.log_metric("metrics/mAP50-95", float(metrics.get('metrics/mAP50-95(B)', 0)), step=epoch)



class YOLOTrainer:
    def __init__(self, config_path: str):
        with open(config_path, 'r') as f:
            self.config = yaml.safe_load(f)

        init_weights = Path("src/models/best.pt")
        arch = self.config['model']['architecture']
        
        if init_weights.exists():
            self.model = YOLO(str(init_weights))
            print(f"Using initialization weights: {init_weights}")
        else:
            self.model = YOLO(arch)
            print(f"Using architecture: {arch}")



    def train(self):
        # Make sure tracking URI and experiment are set once in setup_tracking()      
        try:
            # Directly train with log_mlflow enabled for automatic MLflow logging
            results = self.model.train(
                data=self.config['data']['yaml_path'],
                epochs=self.config['training']['epochs'],
                batch=self.config['training']['batch_size'],
                imgsz=self.config['model']['img_size'],
                lr0=self.config['training']['learning_rate'],
                device=self.config['device'],
                project=self.config['output']['project_dir'],
                name=f"run_{datetime.now().strftime('%Y%m%d_%H%M%S')}",
                save=True,
                val=True,
            )

            best_path = Path(results.save_dir) / "weights" / "best.pt"
            target_path = Path("../models/best.pt")

            # Create the target directory if it doesn't exist
            target_path.parent.mkdir(parents=True, exist_ok=True)

            # Copy the file
            if best_path.exists():
                shutil.copy(best_path, target_path)
                print(f"✅ best.pt copied to: {target_path}")
            else:
                print(f"❌ best.pt not found at {best_path}")

            
            # You can still export and log the model manually outside the autologging context
            onnx_path = None
            try:
                onnx_path = self.model.export(format='onnx', dynamic=True)
            except Exception as e:
                print(f"Failed to export ONNX model: {e}")

            if onnx_path and Path(onnx_path).exists():
                mlflow.log_artifact(str(onnx_path))

            # Log final trained model manually, registering it if needed
            try:
                mlflow.pytorch.log_model(
                    pytorch_model=self.model.model,
                    artifact_path="model",
                    registered_model_name=self.config['model']['name']
                )
            except Exception as e:
                print(f"Failed to log model: {e}")

            return results

        except Exception as e:
            print(f"Training failed: {e}")
            mlflow.end_run(status='FAILED')
            raise


    def evaluate(self):
        return self.model.val(data=self.config['data']['yaml_path'])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train YOLO model with a config file")
    parser.add_argument(
        "--config",
        type=str,
        required=True,
        help="Path to the training configuration YAML file"
    )
    args = parser.parse_args()

    trainer = YOLOTrainer(config_path=args.config)
    train_results = trainer.train()
    val_metrics = trainer.evaluate()
    print(f"Validation mAP50-95: {val_metrics.box.map:.4f}")
