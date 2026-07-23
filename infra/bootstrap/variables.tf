variable "aws_region" {
  description = "Region in which to create the remote-state bucket and lock table. Must match the region in ../backend.tf."
  type        = string
  default     = "eu-north-1"

  validation {
    condition     = length(trimspace(var.aws_region)) > 0
    error_message = "aws_region must not be empty."
  }
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform state. Must match the bucket in ../backend.tf. Change if the name is already taken."
  type        = string
  default     = "finops-audit-terraform-state"

  validation {
    condition     = can(regex("^[a-z0-9.-]{3,63}$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name (3-63 lowercase chars)."
  }
}

variable "lock_table_name" {
  description = "DynamoDB table name for state locking. Must match dynamodb_table in ../backend.tf."
  type        = string
  default     = "finops-audit-terraform-locks"

  validation {
    condition     = length(trimspace(var.lock_table_name)) > 0
    error_message = "lock_table_name must not be empty."
  }
}
