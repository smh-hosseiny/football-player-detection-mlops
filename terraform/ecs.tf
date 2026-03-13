# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.app_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name        = "${var.app_name}-cluster"
    Environment = var.environment
  }
}


data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/gpu/recommended/image_id"
}

# Launch Template (GPU-ready; Spot optional via variable)
resource "aws_launch_template" "ecs" {
  name_prefix            = "${var.app_name}-ecs-"
  image_id               = data.aws_ssm_parameter.ecs_ami.value
  instance_type          = var.ecs_instance_type
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ecs_instances.id]
    delete_on_termination       = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(<<-EOF
#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

# Configure ECS agent
mkdir -p /etc/ecs
echo "ECS_CLUSTER=${aws_ecs_cluster.main.name}" > /etc/ecs/ecs.config
echo "ECS_ENABLE_GPU_SUPPORT=true" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE=true" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_CONTAINER_METADATA=true" >> /etc/ecs/ecs.config

# Start Docker and ECS agent with retries (avoids boot-time race conditions).
systemctl enable docker
systemctl start docker
systemctl enable ecs
for i in $(seq 1 12); do
  systemctl restart ecs || true
  sleep 5
  if curl -fsS http://localhost:51678/v1/metadata >/dev/null; then
    echo "ECS agent metadata endpoint is healthy"
    break
  fi
  echo "ECS agent not ready yet (attempt $i/12)"
done

# Associate Elastic IP so CloudFront has a stable origin (IMDSv2)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
for i in $(seq 1 10); do
  if aws ec2 associate-address \
      --instance-id "$INSTANCE_ID" \
      --allocation-id "${aws_eip.app.allocation_id}" \
      --region "${var.region}"; then
    echo "EIP associated successfully"
    break
  fi
  echo "EIP association attempt $i failed, retrying in 5s..."
  sleep 5
done
EOF
  )

  dynamic "instance_market_options" {
    for_each = var.enable_spot_instances ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price          = var.spot_max_price
        spot_instance_type = "one-time"
      }
    }
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 50
      volume_type = "gp3"
    }
  }


  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.app_name}-ecs-instance"
      Environment = var.environment
      Billing     = var.enable_spot_instances ? "spot-friendly" : "on-demand"
    }
  }
}


resource "aws_autoscaling_group" "ecs" {
  name                      = "${var.app_name}-asg"
  vpc_zone_identifier       = var.public_subnet_ids
  min_size                  = 0
  max_size                  = 1
  desired_capacity          = 0
  health_check_type         = "EC2"
  health_check_grace_period = 300

  protect_from_scale_in     = false
  wait_for_capacity_timeout = "0"

  launch_template {
    id      = aws_launch_template.ecs.id
    version = tostring(aws_launch_template.ecs.latest_version)
  }

  # Tag instances
  tag {
    key                 = "cluster"
    value               = aws_ecs_cluster.main.name
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = "${var.app_name}-asg"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }


  # Add the launch template to the depends_on list
  depends_on = [
    aws_iam_instance_profile.ecs_instance,
    aws_launch_template.ecs
  ]
}


# ECS Capacity Provider (attach to ASG)
resource "aws_ecs_capacity_provider" "main" {
  name = "${var.app_name}-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "DISABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 91
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
    }
  }
}

# Associate Capacity Provider with Cluster
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]

  depends_on = [aws_ecs_cluster.main, aws_ecs_capacity_provider.main]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 100
    base              = 1
  }
}

# ECS Instance Role
resource "aws_iam_role" "ecs_instance" {
  name = "${var.app_name}-ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecs_instance_cloudwatch" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ecs_instance_ssm" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow the instance to associate the Elastic IP on startup.
# Also include minimal read-only APIs used for on-instance diagnostics via SSM.
resource "aws_iam_role_policy" "ecs_instance_eip" {
  name = "${var.app_name}-eip-policy"
  role = aws_iam_role.ecs_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AssociateAddress",
          "ec2:DescribeInstances",
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "ecs:ListContainerInstances",
          "ecs:DescribeContainerInstances",
          "ecs:DescribeClusters"
        ]
        Resource = "*"
      }
    ]
  })
}


resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${var.app_name}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance.name
}

# ECS Task Execution Role
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.app_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Task Role
resource "aws_iam_role" "ecs_task" {
  name = "${var.app_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.app_name}"
  retention_in_days = 7 # Cost-efficient log retention
}

# ECS Task Definition (optimized for YOLO11n)
resource "aws_ecs_task_definition" "app" {
  family                   = var.app_name
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  cpu                      = "3500"
  memory                   = "14000"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = var.app_name
    image = "${aws_ecr_repository.app.repository_url}:latest"

    portMappings = [{
      containerPort = 8000
      hostPort      = 8000
      protocol      = "tcp"
    }]

    resourceRequirements = [
      { type = "GPU", value = "1" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"  = aws_cloudwatch_log_group.ecs.name
        "awslogs-region" = var.aws_region
      }
    }

    environment = [
      { name = "ENVIRONMENT", value = var.environment }
    ]

    # Minimal privileges (remove SYS_ADMIN unless required)
    linuxParameters = {
      initProcessEnabled = false
    }
  }])

  tags = {
    Name        = var.app_name
    Environment = var.environment
  }
}


# ECS Service
resource "aws_ecs_service" "app" {
  name            = "${var.app_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 0

  # Keep min healthy at 0 for single-host GPU rollouts, while max must remain
  # >100 because ECS Availability Zone Rebalancing is enabled for this service.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 100
    base              = 1 # Ensure at least 1 task runs
  }

  force_new_deployment = true

  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  tags = {
    Name        = "${var.app_name}-service"
    Environment = var.environment
  }
}


# Route 53 Hosted Zone
data "aws_route53_zone" "main" {
  name         = "playersdetect.com"
  private_zone = false
}

# Output the zone ID and nameservers
output "route53_zone_id" {
  description = "Route53 hosted zone ID"
  value       = data.aws_route53_zone.main.zone_id
}


output "route53_nameservers" {
  description = "Route53 nameservers - configure these at your domain registrar"
  value       = data.aws_route53_zone.main.name_servers
}


# Re-add this block temporarily
provider "aws" {
  alias  = "us-east-1" # Use the alias if you had one, otherwise just the region.
  region = "us-east-1"
}

# ACM Certificate for api.playersdetect.com
resource "aws_acm_certificate" "app" {
  provider          = aws.us-east-1
  domain_name       = "api.playersdetect.com"
  validation_method = "DNS"

  tags = {
    Name        = "playersdetect-api-cert"
    Environment = var.environment
  }
}

# Route 53 Records for ACM Certificate Validation
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.value]
}

# ACM Certificate Validation
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]

  timeouts {
    create = "15m"
  }
  depends_on = [
    aws_acm_certificate.app,
    aws_route53_record.acm_validation
  ]
}

# Route 53 Alias Record pointing to CloudFront
resource "aws_route53_record" "alb" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.playersdetect.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}

# Route 53 A record for the EIP (CloudFront requires a domain name, not a raw IP)
resource "aws_route53_record" "origin" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "origin.playersdetect.com"
  type    = "A"
  ttl     = 60
  records = [aws_eip.app.public_ip]
}

# --- CLOUDFRONT DISTRIBUTION ---
# Replaces the ALB as the public HTTPS endpoint. CloudFront terminates TLS and
# forwards HTTP traffic to the ECS instance on port 8000 via the Elastic IP.
resource "aws_cloudfront_distribution" "app" {
  origin {
    domain_name = aws_route53_record.origin.fqdn
    origin_id   = "ECS-EC2-Origin"
    # Fail fast when origin is intentionally offline outside schedule.
    connection_attempts = 1
    connection_timeout  = 2

    custom_origin_config {
      http_port                = 8000
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 5
      origin_keepalive_timeout = 5
    }
  }

  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.app_name} - CloudFront distribution"

  aliases = ["api.playersdetect.com"]

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "ECS-EC2-Origin"

    # CachingDisabled: passes all requests to origin (required for API + WebSocket)
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    # AllViewer: forwards all headers/cookies/query strings (needed for WebSocket Upgrade header)
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

    viewer_protocol_policy = "redirect-to-https"
  }

  # When ECS/EC2 is intentionally stopped outside schedule, the origin can return
  # different 5xx errors (for example 502/504). Normalize those to 503 so clients
  # get a consistent "service temporarily unavailable" response.
  custom_error_response {
    error_code            = 500
    response_code         = 503
    response_page_path    = "/503.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 502
    response_code         = 503
    response_page_path    = "/503.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 503
    response_code         = 503
    response_page_path    = "/503.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 504
    response_code         = 503
    response_page_path    = "/503.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.app.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name        = "${var.app_name}-cf"
    Environment = var.environment
  }

  depends_on = [aws_acm_certificate_validation.app]
}


# --- SCHEDULER IAM ROLE ---
# Allows the scheduler to update your ECS Service
resource "aws_iam_role" "scheduler" {
  name = "${var.app_name}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "scheduler_ecs" {
  name = "${var.app_name}-scheduler-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecs:UpdateService"
        Resource = aws_ecs_service.app.id # Specific to your service
      }
    ]
  })
}

# --- STOP SCHEDULE (1 PM Toronto Time) ---
resource "aws_scheduler_schedule" "stop_ecs" {
  name       = "${var.app_name}-stop-nightly"
  group_name = "default"
  state      = var.enable_scheduling ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  # Cron: Minute 0, Hour 12 (12:45 PM), Every Day
  schedule_expression = "cron(45 12  * * ? *)"

  # NATIVE TIMEZONE SUPPORT! No UTC math needed.
  schedule_expression_timezone = "America/Toronto"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      Cluster      = aws_ecs_cluster.main.name
      Service      = aws_ecs_service.app.name
      DesiredCount = 0 # Scale down to 0
    })
  }
}

# --- START SCHEDULE (12:30 PM Toronto Time) ---
resource "aws_scheduler_schedule" "start_ecs" {
  name       = "${var.app_name}-start-morning"
  group_name = "default"
  state      = var.enable_scheduling ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  # Cron: Minute 30, Hour 12 (12:30 PM), Every Day
  schedule_expression          = "cron(30 12 * * ? *)"
  schedule_expression_timezone = "America/Toronto"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      Cluster      = aws_ecs_cluster.main.name
      Service      = aws_ecs_service.app.name
      DesiredCount = 1 # Wake up!
    })
  }
}

# --- ASG SCHEDULED SCALING ---
# Explicit ASG schedules to guarantee the EC2 instance starts/stops on time,
# rather than relying solely on capacity provider managed scaling.

resource "aws_autoscaling_schedule" "scale_up" {
  count                  = var.enable_scheduling ? 1 : 0
  scheduled_action_name  = "${var.app_name}-asg-scale-up"
  autoscaling_group_name = aws_autoscaling_group.ecs.name
  recurrence             = "30 12 * * *"
  time_zone              = "America/Toronto"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 1
}

resource "aws_autoscaling_schedule" "scale_down" {
  count                  = var.enable_scheduling ? 1 : 0
  scheduled_action_name  = "${var.app_name}-asg-scale-down"
  autoscaling_group_name = aws_autoscaling_group.ecs.name
  recurrence             = "0 13 * * *"
  time_zone              = "America/Toronto"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 0
}
