# terraform/modules/dns-ssl/main.tf
# Route53 hosted zone, ACM certificates, and all DNS records
#
# Records created:
#   cms.wizioners.com               → CloudFront (production frontend)
#   staging-cms.wizioners.com       → CloudFront (staging frontend)
#   api-cms.wizioners.com           → ALB (production backend)
#   api-staging-cms.wizioners.com   → ALB (staging backend)

variable "project" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }
variable "domain" { type = string }   # e.g. "cms.wizioners.com"

# ALB
variable "alb_dns_name" { type = string }
variable "alb_zone_id" { type = string }

# CloudFront
variable "staging_cloudfront_domain" {
  type    = string
  default = ""
}
variable "production_cloudfront_domain" {
  type    = string
  default = ""
}

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ─── Route53 Hosted Zone ───
# NOTE: After creating this, you must update your parent domain (wizioners.com)
# NS records to point to the nameservers output by this zone.
resource "aws_route53_zone" "main" {
  name    = var.domain
  comment = "${var.project} - managed by Terraform"

  tags = { Name = "${local.name_prefix}-zone" }
}

# ─── ACM Certificate (for ALB — must be in same region as ALB) ───
resource "aws_acm_certificate" "alb" {
  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"

  tags = { Name = "${local.name_prefix}-alb-cert" }

  lifecycle {
    create_before_destroy = true
  }
}

# DNS validation records for ALB cert
resource "aws_route53_record" "alb_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.main.zone_id
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.alb_cert_validation : record.fqdn]
}

# ─── ACM Certificate for CloudFront (MUST be in us-east-1) ───
# CloudFront requires certificates in us-east-1 regardless of your region
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

resource "aws_acm_certificate" "cloudfront" {
  provider                  = aws.us_east_1
  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"

  tags = { Name = "${local.name_prefix}-cf-cert" }

  lifecycle {
    create_before_destroy = true
  }
}

# Validation records are the same CNAME — already created above by alb_cert_validation
# Just need to wait for validation
resource "aws_acm_certificate_validation" "cloudfront" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for record in aws_route53_record.alb_cert_validation : record.fqdn]
}

# ─── DNS Records: API subdomains → ALB ───
resource "aws_route53_record" "api_production" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "api-cms.${var.domain}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "api_staging" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "api-staging-cms.${var.domain}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "adminer" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "db-cms.${var.domain}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# ─── DNS Records: Frontend subdomains → CloudFront ───
# These are created conditionally (only when CloudFront domains are provided)

resource "aws_route53_record" "frontend_production" {
  count   = var.production_cloudfront_domain != "" ? 1 : 0
  zone_id = aws_route53_zone.main.zone_id
  name    = "cms.${var.domain}"   # cms.wizioners.com (root)
  type    = "A"

  alias {
    name                   = var.production_cloudfront_domain
    zone_id                = "Z2FDTNDATAQYW2"  # CloudFront's fixed hosted zone ID
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "frontend_staging" {
  count   = var.staging_cloudfront_domain != "" ? 1 : 0
  zone_id = aws_route53_zone.main.zone_id
  name    = "staging-cms.${var.domain}"
  type    = "A"

  alias {
    name                   = var.staging_cloudfront_domain
    zone_id                = "Z2FDTNDATAQYW2"  # CloudFront's fixed hosted zone ID
    evaluate_target_health = false
  }
}

# ─── Outputs ───
output "zone_id" { value = aws_route53_zone.main.zone_id }
output "name_servers" {
  value       = aws_route53_zone.main.name_servers
  description = "UPDATE your parent domain (cms.wizioners.com) NS records with these"
}

output "alb_certificate_arn" {
  value = aws_acm_certificate_validation.alb.certificate_arn
}

output "cloudfront_certificate_arn" {
  value = aws_acm_certificate_validation.cloudfront.certificate_arn
}
