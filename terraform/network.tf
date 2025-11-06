# --- DATA SOURCES ---
# (Moved to the top for clarity)

# This was the missing piece.
# This looks up your VPC's details, including its IP range (CIDR block).
data "aws_vpc" "main" {
  id = var.vpc_id
}

# 1. Get the route table for EACH public subnet
data "aws_route_table" "public" {
  for_each = toset(var.public_subnet_ids)

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

# 2. Get a *unique list* of all the route table IDs we just found
locals {
  public_route_table_ids = distinct([for rt in data.aws_route_table.public : rt.id])
}


# --- SECURITY GROUPS ---

# Security Group for the Application Load Balancer
resource "aws_security_group" "alb" {
  name        = "${var.app_name}-alb-sg"
  description = "Allow inbound HTTP/HTTPS traffic to the ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-alb-sg"
  }
}

# Security Group for the ECS EC2 instances
resource "aws_security_group" "ecs_instances" {
  name        = "${var.app_name}-ecs-instances-sg"
  description = "Security group for ECS EC2 instances"
  vpc_id      = var.vpc_id

  # Allow SSH from specific IPs (optional, for debugging)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["130.63.188.157/32"]
  }

  # THIS IS THE FIX for the "Request timed out" / health check.
  # It allows traffic from the ALB.
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.alb.id]
  }

  # Allow all outbound traffic - critical for pulling images from ECR
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-ecs-instances-sg"
  }
}


# --- VPC ENDPOINT INFRASTRUCTURE ---

# A new Security Group for all your VPC Endpoints
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.app_name}-vpc-endpoints-sg"
  description = "Allow instances to access VPC endpoints"
  vpc_id      = var.vpc_id

  # THIS IS THE FIX for the "pull access denied" error.
  # It allows all services inside your VPC (like DNS) to talk to the endpoints.
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    # This now correctly uses the data source we added at the top
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-vpc-endpoints-sg"
  }
}


# --- LOAD BALANCER ---
# Application Load Balancer (ALB)
resource "aws_lb" "main" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false

  tags = {
    Name = "${var.app_name}-alb"
  }
}

# Target Group for the ECS Service
resource "aws_lb_target_group" "app" {
  name        = "${var.app_name}-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance" # Correct for 'bridge' mode
  deregistration_delay = 30

  health_check {
    path                = "/health" # You confirmed this exists
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.app_name}-tg"
  }
}

data "aws_network_acls" "public" {
  filter {
    name   = "association.subnet-id"
    values = var.public_subnet_ids # The data source accepts the full list
  }
}

locals {
  public_network_acl_ids = data.aws_network_acls.public.ids
}

# --- NACL FIX (replace your old resource with this) ---
resource "aws_network_acl_rule" "allow_ephemeral_inbound" {
  for_each = toset(local.public_network_acl_ids) # <-- Loop over all found NACLs

  network_acl_id = each.value 
  rule_number = 101
  egress      = false
  protocol    = "tcp"
  rule_action = "allow"
  cidr_block  = "0.0.0.0/0"
  from_port   = 1024
  to_port     = 65535
}


# --- NACL FIX (for the Public Subnet) ---
resource "aws_network_acl_rule" "allow_public_https_inbound" {
  # Use the same 'for_each' as your other NACL rules
  for_each = toset(local.public_network_acl_ids)

  network_acl_id = each.value
  rule_number    = 90 # A new number, e.g., 90
  egress         = false # false = INBOUND
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0" # From anywhere on the internet
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "allow_public_http_inbound" {
  for_each = toset(local.public_network_acl_ids)

  network_acl_id = each.value
  rule_number    = 91
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}



# --- VPC ENDPOINT INFRASTRUCTURE ---

# Gateway Endpoint for S3 (for image layers)
# This fixes the main timeout error
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  route_table_ids   = local.public_route_table_ids
  vpc_endpoint_type = "Gateway"
}

# Interface Endpoint for STS (Authentication)
# This fixes authentication errors
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = var.public_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
}

# Interface Endpoint for ECR API (Authentication)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = var.public_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
}

# Interface Endpoint for ECR Docker Registry (Manifest pull)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = var.public_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
}