#!/bin/bash
set -e  # stop on first error

docker build -t yolo-inference:latest -f docker/Dockerfile.inference .
