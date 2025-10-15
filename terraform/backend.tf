# terraform/backend.tf

terraform {
  backend "s3" {
    bucket         = "object-detector-tfstate-707010175184-us-east-1" 
    key            = "global/ecs/terraform.tfstate"    # A path for the state file inside the bucket
    region         = "us-east-1"
    dynamodb_table = "terraform-state-locks"           
    encrypt        = true
  }
}
