terraform {
  backend "s3" {
    bucket         = "finops-audit-terraform-state"
    key            = "aws-finops-audit/terraform.tfstate"
    region         = "eu-north-1"
    dynamodb_table = "finops-audit-terraform-locks"
    encrypt        = true
  }
}
