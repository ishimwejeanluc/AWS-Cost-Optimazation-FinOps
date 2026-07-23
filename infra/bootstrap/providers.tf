terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # NOTE: The bootstrap intentionally has NO backend block.
  # It uses LOCAL state, because it is the code that *creates* the
  # remote backend (S3 bucket + DynamoDB lock table) that the root
  # infra configuration in ../ then consumes. Chicken-and-egg:
  # you cannot store this state remotely before the remote store exists.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "FinOps-Audit"
      ManagedBy = "Terraform"
      Purpose   = "tf-remote-state-bootstrap"
    }
  }
}
