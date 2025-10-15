#!/bin/bash
set -e  # stop on first error

docker build -t yolo-trainer:latest -f docker/Dockerfile.training .