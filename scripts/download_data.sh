#!/bin/bash

set -e

# Define final destination
DEST_DIR="src/data/football_players_detection"

if [ -d "$DEST_DIR" ] && [ "$(ls -A "$DEST_DIR")" ]; then
    echo "Dataset already exists in $DEST_DIR, skipping download."
    exit 0
fi

# Make sure destination exists
mkdir -p $DEST_DIR

# Download dataset using Python and Roboflow API
python3 <<EOF
from roboflow import Roboflow
from pathlib import Path

rf = Roboflow(api_key="UxApJs5oZUkmngdc3qdV")
project = rf.workspace("roboflow-jvuqo").project("football-players-detection-3zvbc")
dataset = project.version(4).download("yolov8")
# Move the downloaded files to DEST_DIR if needed:
import shutil
path_dataset = Path("football-players-detection-4")
dst = Path("$DEST_DIR")
# Copy relevant files and folders
for item in path_dataset.iterdir():
    if item.name == "data.yaml" or item.is_dir():
        shutil.move(str(item), str(dst/item.name))
EOF

echo "Dataset downloaded to $DEST_DIR"
