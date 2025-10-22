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
  # We are moving to a public subnet, so this will no longer be used.
  default     = []
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "A list of public subnet IDs for the resources."
  default     = ["subnet-0d5eaa544e51c34c0"]  
}
