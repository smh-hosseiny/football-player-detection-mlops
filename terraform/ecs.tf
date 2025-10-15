# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.app_name}-cluster"
  
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  
  tags = {
    Name        = "${var.app_name}-cluster"
    Environment = var.environment
  }
}




# Data Source for ECS-Optimized CPU AMI
data "aws_ami" "ecs_optimized" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*"]  # <-- removed "-gpu"
  }
}

# Launch Template (CPU-only, Spot-ready)
resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.app_name}-ecs-"
  image_id      = data.aws_ami.ecs_optimized.id
  instance_type = "t3a.small"  # CPU-only instance

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 30
      volume_type = "gp3"
    }
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups            = [aws_security_group.ecs_tasks.id]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config
    EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.app_name}-ecs-instance"
      Environment = var.environment
      Billing     = "spot-friendly"
    }
  }
}


resource "aws_autoscaling_group" "ecs" {
  name                = "${var.app_name}-asg"
  vpc_zone_identifier = var.private_subnet_ids
  min_size            = 1
  max_size            = 4
  desired_capacity    = 1
  health_check_type   = "ELB"
  health_check_grace_period = 300

  protect_from_scale_in = true

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  # Tag instances
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
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 75    # Keep ASG ~75% utilized for cost efficiency
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
  retention_in_days = 7  # Cost-efficient log retention
}

# ECS Task Definition (optimized for YOLO11n)
resource "aws_ecs_task_definition" "app" {
  family                   = var.app_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = "1024"   # 1 vCPU 
  memory                   = "1536"   # (enough for YOLO11n <3GB)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = var.app_name
    image = "${aws_ecr_repository.app.repository_url}:latest"

    portMappings = [{
      containerPort = 8000
      protocol      = "tcp"
    }]
  
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"  = aws_cloudwatch_log_group.ecs.name
        "awslogs-region" = var.aws_region
      }
    }

    environment = [
      { name = "ENVIRONMENT", value = var.environment },
      { name = "CUDA_VISIBLE_DEVICES", value = "0" } # Use GPU 0 if available
    ]

    # Remove this for CPU-only instances
    # resourceRequirements = [
    #   {
    #     type  = "GPU"
    #     value = "1"
    #   }
    # ]

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
  desired_count   = 1  # Start with 1, scale-to-zero handles off-hours

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 100
    base              = 1  # Ensure at least 1 task runs
  }

  network_configuration {
    security_groups  = [aws_security_group.ecs_tasks.id]
    subnets          = var.private_subnet_ids
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.app_name
    container_port   = 8000
  }

  deployment_controller {
    type = "ECS"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = {
    Name        = "${var.app_name}-service"
    Environment = var.environment
  }

  depends_on = [aws_lb_listener.https, aws_lb_listener.http]
}


resource "aws_subnet" "private_a" {
  vpc_id            = var.vpc_id 
  cidr_block        = "10.0.101.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "my-app-private-us-east-1a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = var.vpc_id 
  cidr_block        = "10.0.102.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "my-app-private-us-east-1b"
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
  provider = aws.us-east-1
  domain_name       = "api.playersdetect.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "playersdetect-api-cert"
    Environment = var.environment
  }
}

# Route 53 Records for ACM Certificate Validation
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      value  = dvo.resource_record_value
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

# Route 53 Alias Record for ALB
resource "aws_route53_record" "alb" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.playersdetect.com"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# HTTPS Listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.app.certificate_arn
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# HTTP to HTTPS Redirect
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}