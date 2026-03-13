# --- DATA SOURCES ---

# Looks up the VPC's details including its CIDR block
data "aws_vpc" "main" {
  id = var.vpc_id
}

# Get the route table for EACH public subnet
data "aws_route_table" "public" {
  for_each = toset(var.public_subnet_ids)

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

# Unique list of all public route table IDs
locals {
  public_route_table_ids = distinct([for rt in data.aws_route_table.public : rt.id])
}

# CloudFront origin-facing managed prefix list (used to restrict inbound to CloudFront IPs only)
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}


# --- SECURITY GROUPS ---

# Security Group for the ECS EC2 instances
resource "aws_security_group" "ecs_instances" {
  name        = "${var.app_name}-ecs-instances-sg"
  description = "Security group for ECS EC2 instances"
  vpc_id      = var.vpc_id

  # Allow SSH from specific IPs (for debugging)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["130.63.188.157/32"]
  }

  # Allow HTTP traffic from CloudFront only on the app port
  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  # Allow all outbound traffic - required for ECR image pulls, ECS agent, etc.
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


# --- ELASTIC IP ---
# Static IP for the ECS EC2 instance so CloudFront has a fixed origin.
# Cost: $0.005/hr while unassociated (~$3.57/month) vs ALB fixed charge ($16.43/month).
resource "aws_eip" "app" {
  domain = "vpc"

  tags = {
    Name        = "${var.app_name}-eip"
    Environment = var.environment
  }
}


data "aws_network_acls" "public" {
  filter {
    name   = "association.subnet-id"
    values = var.public_subnet_ids
  }
}

locals {
  public_network_acl_ids = data.aws_network_acls.public.ids
}

# --- NACL RULES ---
resource "aws_network_acl_rule" "allow_ephemeral_inbound" {
  for_each = toset(local.public_network_acl_ids)

  network_acl_id = each.value
  rule_number    = 101
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "allow_public_https_inbound" {
  for_each = toset(local.public_network_acl_ids)

  network_acl_id = each.value
  rule_number    = 90
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
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

# Gateway Endpoint for S3 (free, speeds up ECR image layer pulls)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  route_table_ids   = local.public_route_table_ids
  vpc_endpoint_type = "Gateway"
}
