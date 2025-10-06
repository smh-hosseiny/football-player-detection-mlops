#!/bin/bash

set -e

docker run --rm --runtime=nvidia --gpus all \
  --shm-size=2g \
  -v "$PWD/src/data/football_players_detection:/app/src/data/football_players_detection" \
  -v "$PWD/src/models:/app/src/models" \
  -v "$PWD/runs_detect:/app/runs_detect" \
  -e CUDA_VISIBLE_DEVICES=0 \
  yolo-trainer \
  python src/training/train.py --config configs/training_config.yaml
