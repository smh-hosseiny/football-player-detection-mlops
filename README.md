# MLOps Project: Real-Time Football Player Detection

![YOLOv11](https://img.shields.io/badge/Model-YOLOv11-blue)
![FastAPI](https://img.shields.io/badge/API-FastAPI-green)
![Docker](https://img.shields.io/badge/Container-Docker-blue)
![Terraform](https://img.shields.io/badge/IaC-Terraform-purple)
![AWS](https://img.shields.io/badge/Cloud-AWS-orange)
![GitHub Actions](https://img.shields.io/badge/CI/CD-GitHub_Actions-lightgrey)
![Prometheus](https://img.shields.io/badge/Monitoring-Prometheus-red)
![Grafana](https://img.shields.io/badge/Monitoring-Grafana-orange)

<!-- Teaser Prediction Video -->
<p align="center">
  <img src="assets/pred.gif" width="75%" />
</p>

---

This repository contains a production-ready MLOps pipeline for detecting football players in images and videos using **YOLOv11**.

**Stack**: FastAPI backend, Terraform infrastructure on AWS (ECS), GitHub Actions CI/CD, Prometheus/Grafana monitoring.

The live application can be accessed at: **[https://api.playersdetect.com](https://api.playersdetect.com)**


## Part 1: Local Development & Setup

This phase focuses on training the model and testing the application locally.

### Step 1: Environment Setup

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/smh-hosseiny/football-player-detection-mlops.git
   cd football-player-detection-mlops
   ```

2. **Install Dependencies**: Set up a Conda environment and install dependencies.
   ```bash
   conda create -n football-detector python=3.9 -y
   conda activate football-detector
   pip install -r requirements.txt
   pip install -r requirements-dev.txt
   ```

### Step 2: Data Preparation

Place your custom football player dataset in `src/data/football_players_detection/`. Ensure the `data.yaml` file points to the correct `train`, `validation`, and `test` directories, as specified in `configs/training_config.yaml`.

Download the [football-players-detection dataset](https://universe.roboflow.com/roboflow-jvuqo/football-players-detection-3zvbc) using:
   ```bash
   bash scripts/download_training.sh
   ```

### Step 3: Experiment Tracking with MLflow

The `docker-compose.yml` file includes an MLflow server for experiment tracking.

1. **Run Training**:
   ```bash
   bash scripts/build_training.sh
   bash scripts/train_docker.sh
   ```

2. **Access MLflow UI**: Open `http://localhost:5000` in your browser.

   The training script will:
   - Load the YOLOv11 model.
   - Train on your custom dataset.
   - Evaluate the new model against `src/models/best.pt` and keep the better one.
   - Log parameters, metrics, and the final model artifact to the MLflow server.

### Step 4: Run the API Locally

Test the inference API on `http://localhost:8000`. You can interact with the web UI, where you can upload images or videos to see detections.

**Option A: Docker Container**
```bash
bash scripts/build_inference.sh
bash scripts/run_inference.sh
```

**Option B: Direct with uvicorn** (no Docker required)
```bash
uvicorn api.main:app --host 127.0.0.1 --port 8000 --reload
```


#### Video Streaming Inference

Video processing uses WebSocket streaming with instant playback as frames are processed. Adjustable sliders control frame skipping (1-10) and confidence threshold in real-time.

## Part 2: Infrastructure as Code (IaC) with Terraform

Terraform provisions the AWS infrastructure: ECS on EC2 with Auto Scaling, CloudFront + ACM + Route53 for HTTPS, ECR, and EventBridge Scheduler for automatic start/stop.

Cost optimization is mainly schedule-based (service runs 1 hour/day). Spot is supported but currently optional and disabled by default for reliability.

### Current AWS Setup

`api.playersdetect.com` -> Route 53 -> CloudFront (TLS) -> `origin.playersdetect.com` -> Elastic IP -> ECS EC2 host (`g4dn.xlarge`) -> FastAPI on `:8000`.

Health check:

```bash
curl -sS https://api.playersdetect.com/health
```

For deeper architecture notes, see `docs/aws-infrastructure.md`.

### Deploy

1. **Configure AWS Credentials**: Ensure the AWS CLI is configured with the necessary permissions.
   ```bash
   aws configure
   ```

2. **Setup Terraform Backend**: The `backend.tf` file uses an S3 bucket for state management. Create the S3 bucket (`object-detector-tfstate-<AWS_ACCOUNT_ID>-us-east-1`) and a DynamoDB table (`terraform-state-locks`) for state locking.

3. **Initialize Terraform**:
   ```bash
   cd terraform
   terraform init
   ```

4. **Plan and Apply**:
   ```bash
   terraform plan
   terraform apply
   ```

   This creates the ECR repository, ECS cluster, CloudFront/Route53 resources, and associated networking and IAM roles.

## Part 3: CI/CD with GitHub Actions

The CI/CD pipeline automates testing, building, and deployment on every push to the `main` branch.

### Workflow Breakdown (`.github/workflows/ci/cd/infrastructure.yml`)

- **Trigger**: Runs on push to the `main` branch.
- **Lint & Test**: Uses `flake8` for linting and `pytest` for unit tests to ensure code quality.
- **Configure AWS Credentials**: Authenticates with AWS using an OIDC-based IAM role.
- **Login to ECR**: Logs the Docker client into the Amazon ECR registry.
- **Build, Tag, and Push**: Builds the inference Docker image and pushes it to ECR.
- **Deploy with Terraform**: Applies Terraform changes to update infrastructure and the ECS service with the new Docker image.

### Setup

1. Create an IAM role for GitHub Actions with OIDC trust policy (`token.actions.githubusercontent.com`) and ECR/ECS permissions.
2. Every push to `main` automatically runs tests, builds the Docker image, pushes to ECR, and deploys to ECS.

## Part 4: Monitoring with Prometheus and Grafana

The API exposes a `/metrics` endpoint with `predictions_total` and `prediction_latency_seconds` metrics.

```bash
docker-compose up -d prometheus grafana
```

Access Prometheus at `http://localhost:9090` and Grafana at `http://localhost:3000`.
