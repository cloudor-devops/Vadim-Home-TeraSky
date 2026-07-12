terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95" # capped < 6.0 by the EKS module v20
    }
  }

  # Production: remote state per environment, e.g.
  # backend "s3" {
  #   bucket       = "terasky-tfstate-<env>"
  #   key          = "eks/terraform.tfstate"
  #   region       = "eu-west-1"
  #   use_lockfile = true   # S3 native locking
  #   encrypt      = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "node-info"
      ManagedBy   = "terraform"
    }
  }
}
