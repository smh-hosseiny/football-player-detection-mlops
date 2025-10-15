import argparse

import yaml
from ultralytics import YOLO


def evaluate_model(model_path: str, data_yaml: str, device: str = "cuda"):
    # Load the trained YOLO model from weights
    model = YOLO(model_path)

    # Run validation on the dataset specified by data YAML file
    results = model.val(data=data_yaml, device=device)

    # Access metrics like mAP50-95, precision, recall, etc.
    print(f"Validation precision: {results.box.p.mean():.4f}")
    print(f"Validation recall: {results.box.r.mean():.4f}")
    print(f"Validation mAP50: {results.box.map50:.4f}")
    print(f"Validation mAP50-95: {results.box.map:.4f}")

    for i, p in enumerate(results.box.p):
        print(f"Class {i} precision: {p:.4f}")

    # Results object contains more info (confusions, stats, plots, etc.)
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Evaluate YOLO model using test config YAML"
    )
    parser.add_argument("--config", required=True, help="Path to test config YAML file")

    args = parser.parse_args()

    # Load config YAML
    with open(args.config, "r") as f:
        config = yaml.safe_load(f)

    model_path = config["model"]["weights"]
    data_yaml = config["data"]["test_yaml_path"]
    device = config.get("device", "cuda")

    evaluate_model(model_path, data_yaml, device)
