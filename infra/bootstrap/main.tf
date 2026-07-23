# Remote-state bootstrap
# Creates the S3 bucket + DynamoDB lock table that ../backend.tf consumes.
# Run this ONCE, before the root infra configuration. Uses local state.

# ---- S3 bucket that stores the Terraform state file -----------------------
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  # Protect the state store from accidental `terraform destroy`.
  # To intentionally tear it down, remove this block first (see README).
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = var.state_bucket_name
  }
}

# Keep every version of the state file so a bad apply can be rolled back.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest (state can contain secrets).
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State must never be public.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny any non-TLS access to the bucket.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---- DynamoDB table used for state locking --------------------------------
resource "aws_dynamodb_table" "locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST" # no idle cost; pay only per lock op
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name = var.lock_table_name
  }
}
