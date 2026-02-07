# terraform/modules/s3-cloudfront/main.tf
# S3 + CloudFront for React SPA with custom domain + HTTPS

variable "project" { type = string }
variable "environment" { type = string }
variable "domain" {
  type    = string
  default = ""
}
variable "cloudfront_certificate_arn" {
  type    = string
  default = ""
}

locals {
  name_prefix = "${var.project}-${var.environment}"
  has_domain  = var.domain != "" && var.cloudfront_certificate_arn != ""
}

resource "random_id" "bucket" {
  byte_length = 4
}

resource "aws_s3_bucket" "frontend" {
  bucket        = "${local.name_prefix}-frontend-${random_id.bucket.hex}"
  force_destroy = true
  tags = { Name = "${local.name_prefix}-frontend" }
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration {
    status = var.environment == "production" ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name_prefix}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  comment             = "${local.name_prefix} React frontend"

  aliases = local.has_domain ? "api-staging-cms.${var.domain}" : []

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-frontend"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    compress               = true
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.has_domain ? false : true
    acm_certificate_arn            = local.has_domain ? var.cloudfront_certificate_arn : null
    ssl_support_method             = local.has_domain ? "sni-only" : null
    minimum_protocol_version       = local.has_domain ? "TLSv1.2_2021" : null
  }

  tags = { Name = "${local.name_prefix}-cdn" }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFront"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn }
      }
    }]
  })
}

output "bucket_name" { value = aws_s3_bucket.frontend.bucket }
output "cloudfront_distribution_id" { value = aws_cloudfront_distribution.frontend.id }
output "cloudfront_domain_name" { value = aws_cloudfront_distribution.frontend.domain_name }
output "website_url" {
  value = local.has_domain ? "https://${var.domain}" : "https://${aws_cloudfront_distribution.frontend.domain_name}"
}
