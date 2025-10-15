#!/bin/bash

set -e

# Create network if not already present
if ! docker network ls | grep -q mlops_network; then
    docker network create mlops_network
fi

# Stop & remove existing mlflow container if it exists
if [ "$(docker ps -aq -f name=mlflow-server)" ]; then
    docker stop mlflow-server >/dev/null 2>&1 || true
    docker rm mlflow-server >/dev/null 2>&1 || true
fi

# Start MLflow server container in detached mode
docker run -d --name mlflow-server --network mlops_network \
  -p 5000:5000 \
  -v "$PWD/mlruns:/mlruns" \
  python:3.9-slim \
  bash -c "pip install mlflow && mlflow server --host 0.0.0.0 --port 5000 --backend-store-uri file:/mlruns"


# Run training container with MLflow tracking URI pointing to MLflow server
docker run --rm --runtime=nvidia --gpus all  --network mlops_network \
  --shm-size=2g \
  -v "$PWD/src/data/football_players_detection:/app/src/data/football_players_detection" \
  -v "$PWD/src/models:/app/src/models" \
  -v "$PWD/runs_detect:/app/runs_detect" \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e MLFLOW_TRACKING_URI=http://172.17.0.1:5000 \
  yolo-trainer \
  python src/training/train.py --config configs/training_config.yaml

docker stop mlflow-server
echo "Training complete and MLflow server stopped."

echo "Removing excess log/artifact folders: mlruns, runs_detect, wandb, src/wandb, src/runs_detect ..."
sudo rm -rf mlruns runs_detect wandb src/wandb src/runs_detect

# Stop and remove MLflow server container
docker rm mlflow-server

echo "Training complete, excess experiment files removed, and MLflow server stopped."
