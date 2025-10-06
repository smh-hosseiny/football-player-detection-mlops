#!/bin/bash

# -----------------------------
# Train YOLO model + visualize MLflow results
# -----------------------------

# Exit immediately if a command exits with a non-zero status
set -e

# Name of your conda environment
ENV_NAME="idisc"

# Path to your training script and config
TRAIN_SCRIPT="./training/train.py"
CONFIG_FILE="../configs/training_config.yaml"

# Port for MLflow UI
MLFLOW_PORT=5000

echo "🚀 Activating conda environment: $ENV_NAME"
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$ENV_NAME"

# Optional: clear previous MLflow runs if you want a fresh start
# rm -rf ./mlruns

echo "📊 Starting MLflow UI on http://127.0.0.1:$MLFLOW_PORT ..."
mlflow ui --port $MLFLOW_PORT --backend-store-uri file:./mlruns &
MLFLOW_PID=$!

sleep 2

echo "🏋️ Starting YOLO training using config: $CONFIG_FILE"
python "$TRAIN_SCRIPT" --config "$CONFIG_FILE"

echo "✅ Training finished!"
echo "🌐 View MLflow dashboard at: http://127.0.0.1:$MLFLOW_PORT"

# Wait for user to stop MLflow manually
wait $MLFLOW_PID