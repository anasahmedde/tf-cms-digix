# terraform/modules/s3-data/main.tf
# S3 bucket for application data (videos, advertisements, uploads)
# One bucket per environment for isolation

variable "project" { type = string }
variable "environment" { type = string }

locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_s3_bucket" "data" {
  bucket        = "${local.name_prefix}-data"
  force_destroy = var.environment == "staging" ? true : false

  tags = { Name = "${local.name_prefix}-data" }
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = var.environment == "production" ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS for presigned URL uploads from browser
resource "aws_s3_bucket_cors_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "HEAD"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

# Lifecycle: move old data to cheaper storage after 90 days
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    id     = "archive-old-data"
    status = var.environment == "production" ? "Enabled" : "Disabled"

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

output "bucket_name" { value = aws_s3_bucket.data.bucket }
output "bucket_arn" { value = aws_s3_bucket.data.arn }
output "bucket_region" { value = aws_s3_bucket.data.region }
