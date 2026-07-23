output "state_bucket_name" {
  description = "Name of the S3 bucket that stores Terraform state"
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket"
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "Name of the DynamoDB table used for state locking"
  value       = aws_dynamodb_table.locks.name
}

output "region" {
  description = "Region the remote-state resources were created in"
  value       = var.aws_region
}

# Copy this block into ../backend.tf (it is already pre-filled to match the defaults).
output "backend_config" {
  description = "The backend block the root infra configuration should use"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.id}"
        key            = "aws-finops-audit/terraform.tfstate"
        region         = "${var.aws_region}"
        dynamodb_table = "${aws_dynamodb_table.locks.name}"
        encrypt        = true
      }
    }
  EOT
}
