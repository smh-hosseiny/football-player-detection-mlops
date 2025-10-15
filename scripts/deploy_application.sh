#!/bin/bash

set -e

# Configuration
AWS_REGION=${AWS_REGION:-us-east-1}
INFRA_OUTPUTS="../infrastructure_outputs.json"
IMAGE_NAME="yolo-inference"
IMAGE_TAG=${IMAGE_TAG:-latest}

# Validate required tools
for cmd in aws docker jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ $cmd is not installed. Please install it first."
        exit 1
    fi
done

# Check if infrastructure outputs file exists
if [ ! -f "$INFRA_OUTPUTS" ]; then
    echo "❌ Infrastructure outputs file ($INFRA_OUTPUTS) not found. Run Terraform deployment first."
    exit 1
fi

# Extract values from Terraform outputs
ECR_REPOSITORY=$(jq -r '.ecr_repository_url.value' $INFRA_OUTPUTS)
CLUSTER_NAME=$(jq -r '.ecs_cluster_name.value' $INFRA_OUTPUTS)
SERVICE_NAME=$(jq -r '.ecs_service_name.value' $INFRA_OUTPUTS)
TASK_FAMILY="object-detector"

if [ -z "$ECR_REPOSITORY" ] || [ -z "$CLUSTER_NAME" ] || [ -z "$SERVICE_NAME" ]; then
    echo "❌ Failed to extract required values from $INFRA_OUTPUTS."
    exit 1
fi

echo "🚀 Deploying application version ${IMAGE_TAG} to ECS..."

# Authenticate Docker to ECR
echo "🔐 Authenticating Docker to ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPOSITORY

# Tag and push the Docker image
echo "📦 Tagging and pushing Docker image ${IMAGE_NAME}:${IMAGE_TAG} to ${ECR_REPOSITORY}:${IMAGE_TAG}..."
docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${ECR_REPOSITORY}:${IMAGE_TAG}
docker push ${ECR_REPOSITORY}:${IMAGE_TAG}

# Get the current task definition
echo "📋 Fetching current task definition..."
TASK_DEFINITION=$(aws ecs describe-task-definition \
    --task-definition ${TASK_FAMILY} \
    --region ${AWS_REGION} \
    --query 'taskDefinition' \
    --output json)

# Update the task definition with new image
echo "🔄 Updating task definition with new image..."
NEW_TASK_DEF=$(echo $TASK_DEFINITION | jq \
    --arg IMAGE "${ECR_REPOSITORY}:${IMAGE_TAG}" \
    --arg NAME "$TASK_FAMILY" \
    '.containerDefinitions[] | select(.name == $NAME) | .image = $IMAGE | . + {environment: (.environment // []) + [{"name": "CUDA_VISIBLE_DEVICES", "value": "0"}]} | del(.healthCheck.command) | del(.logConfiguration.options["awslogs-stream-prefix"]) | . as $container | $TASK_DEFINITION | .containerDefinitions = [$container] | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

# Register new task definition
echo "📝 Registering new task definition..."
NEW_TASK_ARN=$(aws ecs register-task-definition \
    --region ${AWS_REGION} \
    --cli-input-json "$NEW_TASK_DEF" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

echo "✅ New task definition registered: ${NEW_TASK_ARN}"

# Update the ECS service with new task definition
echo "🔄 Updating ECS service..."
aws ecs update-service \
    --region ${AWS_REGION} \
    --cluster ${CLUSTER_NAME} \
    --service ${SERVICE_NAME} \
    --task-definition ${NEW_TASK_ARN} \
    --force-new-deployment

echo "⏳ Waiting for service to stabilize..."
aws ecs wait services-stable \
    --region ${AWS_REGION} \
    --cluster ${CLUSTER_NAME} \
    --services ${SERVICE_NAME}

# Verify deployment
RUNNING_TASKS=$(aws ecs describe-services \
    --region ${AWS_REGION} \
    --cluster ${CLUSTER_NAME} \
    --services ${SERVICE_NAME} \
    --query 'services[0].runningCount' \
    --output text)

if [ "$RUNNING_TASKS" -lt 1 ]; then
    echo "❌ Deployment failed: No tasks running."
    exit 1
fi

echo "✅ Deployment successful! Service status: ${RUNNING_TASKS} task(s) running"

# Output ALB DNS name for verification
ALB_DNS=$(jq -r '.alb_dns_name.value' $INFRA_OUTPUTS)
echo "🌐 Application available at: http://${ALB_DNS}"