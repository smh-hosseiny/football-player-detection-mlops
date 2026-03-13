# terraform/ecr.tf

resource "aws_ecr_repository" "app" {
  name                 = var.app_name
  image_tag_mutability = "MUTABLE" # Use "IMMUTABLE" for stricter production environments

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true

  tags = {
    Name        = var.app_name
    Environment = var.environment
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images"
      selection = {
        tagStatus   = "untagged"
        countType   = "imageCountMoreThan"
        countNumber = 1
      }
      action = { type = "expire" }
    }]
  })
}