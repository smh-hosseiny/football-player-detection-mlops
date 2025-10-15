# terraform/variables.tf

variable "app_name" {
  type        = string
  description = "The name of the application, used to prefix resource names."
  default     = "object-detector"
}

variable "environment" {
  type        = string
  description = "The deployment environment (e.g., staging, production)."
  default     = "staging"
}

variable "aws_region" {
  type        = string
  description = "The AWS region to deploy resources in."
  default     = "us-east-1"
}

variable "vpc_id" {
  type        = string
  description = "The ID of the VPC to deploy resources into."
  default     = "vpc-00ace309c9dcc098b"  
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "A list of private subnet IDs for the ECS instances and tasks."
  default     = ["subnet-0067b77c2592e3d84", "subnet-0d1598a5445333793", "subnet-002944b664578d535"]
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "A list of public subnet IDs for the Application Load Balancer."
  default     = ["subnet-0d5eaa544e51c34c0", "subnet-0caa0559ba4705d81"]  
}