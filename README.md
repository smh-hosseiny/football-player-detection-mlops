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
  <video src="https://github.com/user-attachments/assets/b33a4232-2851-43f5-8084-97237d77bed4" controls width="75%">
    Your browser does not support the video tag.
  </video>
</p>

---

This repository contains a full-stack, production-ready MLOps pipeline for detecting football players in images and videos. It leverages state-of-the-art tools to automate the entire lifecycle of a machine learning model, from training and experiment tracking to deployment and monitoring.

The system uses a **YOLOv11** model for high-performance object detection, served via a scalable **FastAPI** backend. The infrastructure is defined as code using **Terraform** and deployed on **AWS**. A **CI/CD pipeline** with **GitHub Actions** automates the build, test, and deployment process to a containerized environment on **Amazon ECS**. **Prometheus** and **Grafana** provide robust monitoring of model performance and system health.

The live application can be accessed at: **[https://api.playersdetect.com](https://api.playersdetect.com)**

## Project Tech Stack

- **Model**: YOLOv11 (via ultralytics)
- **Experiment Tracking**: MLflow
- **API**: FastAPI
- **Containerization**: Docker
- **Cloud Provider**: AWS
- **Infrastructure as Code (IaC)**: Terraform
- **CI/CD**: GitHub Actions
- **Deployment**: AWS ECS on EC2
- **Monitoring**: Prometheus & Grafana

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

Test the inference API on `http://localhost:8000` using the inference Docker container or directly via `uvicorn`.

1. **Build and Run the API Container**:
   ```bash
   bash scripts/build_inference.sh
   bash scripts/run_inference.sh
   ```

   Alternatively, run the API directly:
   ```bash
   uvicorn api.main:app --host 127.0.0.1 --port 8000 --reload
   ```

2. **Test the API**: Access `http://localhost:8000` to interact with the web UI, where you can upload images or videos to see detections.

## Part 2: Infrastructure as Code (IaC) with Terraform

The Terraform configuration automates the provisioning of AWS resources for a scalable and secure deployment.

### Key Cost-Saving Strategies

- **Compute**: The `aws_ecs_task_definition` uses 1024 CPU and 1536 MB memory, optimized for the YOLOv11 model on CPU. The `aws_launch_template` uses `t3a.small` instances (AMD-based, cost-effective).
- **Spot Instances**: The Auto Scaling Group (`aws_autoscaling_group`) is configured to support EC2 Spot Instances, which can save up to 90% on compute costs. Add a `spot_options` block to the `aws_launch_template` for further savings.
- **Networking**: Private subnets are used for ECS tasks, and public subnets for the Application Load Balancer (ALB), ensuring security without additional costs.

### Steps to Deploy Infrastructure

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

   This creates the ECR repository, ECS cluster, ALB, and associated networking and IAM roles.

## Part 3: CI/CD with GitHub Actions

The CI/CD pipeline automates testing, building, and deployment on every push to the `main` branch.

### Workflow Breakdown (`.github/workflows/ci/cd/infrastructure.yml`)

- **Trigger**: Runs on push to the `main` branch.
- **Lint & Test**: Uses `flake8` for linting and `pytest` for unit tests to ensure code quality.
- **Configure AWS Credentials**: Authenticates with AWS using an OIDC-based IAM role.
- **Login to ECR**: Logs the Docker client into the Amazon ECR registry.
- **Build, Tag, and Push**: Builds the inference Docker image and pushes it to ECR.
- **Deploy with Terraform**: Applies Terraform changes to update infrastructure and the ECS service with the new Docker image.

### Setup Steps

1. **Create the Workflow File**: Ensure `ci/cd/infrastructure.yml` is in the `.github/workflows/` directory.

2. **Configure AWS OIDC and IAM Role**:
   - In AWS IAM, create a role that GitHub Actions can assume via OIDC (`token.actions.githubusercontent.com`).
   - Attach permissions, such as:
     - `AmazonEC2ContainerRegistryPowerUser` (for ECR).
     - `AmazonECSFullAccess` or a custom ECS deploy policy.
   - Update the trust policy to allow your GitHub repository (using repo:<OWNER>/<REPO>:ref:refs/heads/main) to assume this role
   - The workflow will authenticate using the IAM role via the aws-actions/configure-aws-credentials action with role-to-assume.

3. **Automatic CI/CD**: Every push to the `main` branch will now automatically:
   - Run tests and linting.
   - Build and push the Docker image to ECR.
   - Deploy to ECS using the assumed IAM role.

## Part 4: Monitoring with Prometheus and Grafana

Monitoring is a key MLOps practice, and the application is instrumented with Prometheus and Grafana for real-time insights into performance and health.

### Prometheus Metrics

The FastAPI app (`api/main.py`) exposes a `/metrics` endpoint with the following metrics:
- `predictions_total`: Total number of predictions made.
- `prediction_latency_seconds`: Histogram of prediction times.

### Grafana Dashboard

The `docker-compose.yml` includes services for Prometheus and Grafana to visualize metrics locally.

1. **Start Monitoring Services**:
   ```bash
   docker-compose up -d prometheus grafana
   ```

2. **Access Prometheus**: Open `http://localhost:9090` to view raw metrics.


