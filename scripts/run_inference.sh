#!/bin/bash

set -e


docker run --rm  --runtime=nvidia --gpus all \
  -p 8000:8000 \
  -v "$PWD/src/data/football_players_detection:/app/src/data/football_players_detection" \
  -v "$PWD/src/models:/app/src/models" \
  -v "$PWD/runs_detect:/app/runs_detect" \
  yolo-inference:latest 
