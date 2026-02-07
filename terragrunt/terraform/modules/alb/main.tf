# terraform/modules/alb/main.tf
# Single shared ALB with host-based routing rules
#
# Routing:
#   api-staging-cms.wizioners.com   → staging target group
#   api-cms.wizioners.com           → production target group
#   db-cms.wizioners.com            → adminer target group

variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "domain" { type = string }                           # e.g. "cms.wizioners.com"
variable "certificate_arn" {
  type    = string
  default = ""
}  # ACM cert ARN from dns-ssl module

locals {
  name_prefix = "${var.project}-${var.environment}"
  has_cert    = var.certificate_arn != ""
}

# ─── ALB Security Group ───
resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  vpc_id      = var.vpc_id
  description = "Shared ALB"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-alb-sg" }
  lifecycle { create_before_destroy = true }
}

# ─── ALB ───
resource "aws_lb" "main" {
  name               = "${var.project}-shared-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids
  tags = { Name = "${var.project}-shared-alb" }
}

# ─── Target Groups (one per environment) ───
resource "aws_lb_target_group" "staging" {
  name        = "${var.project}-staging-tg"
  port        = 8005
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/docs"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${var.project}-staging-tg" }
}

resource "aws_lb_target_group" "production" {
  name        = "${var.project}-production-tg"
  port        = 8005
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/docs"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${var.project}-production-tg" }
}

# ─── Adminer Target Group ───
resource "aws_lb_target_group" "adminer" {
  name        = "${var.project}-adminer-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200"
  }

  tags = { Name = "${var.project}-adminer-tg" }
}

# ─── HTTP Listener (port 80) ───
# If cert exists: redirect to HTTPS. If no cert: route directly.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = local.has_cert ? "redirect" : "fixed-response"

    dynamic "redirect" {
      for_each = local.has_cert ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = local.has_cert ? [] : [1]
      content {
        content_type = "text/plain"
        message_body = "Not Found"
        status_code  = "404"
      }
    }
  }
}

# Host-based rules on HTTP (used when no HTTPS cert)
resource "aws_lb_listener_rule" "http_staging" {
  count        = local.has_cert ? 0 : 1
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.staging.arn
  }

  condition {
    host_header {
      values = ["api-staging-cms.${var.domain}"]
    }
  }
}

resource "aws_lb_listener_rule" "http_production" {
  count        = local.has_cert ? 0 : 1
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.production.arn
  }

  condition {
    host_header {
      values = ["api-cms.${var.domain}"]
    }
  }
}

resource "aws_lb_listener_rule" "http_adminer" {
  count        = local.has_cert ? 0 : 1
  listener_arn = aws_lb_listener.http.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.adminer.arn
  }

  condition {
    host_header {
      values = ["db-cms.${var.domain}"]
    }
  }
}

# ─── HTTPS Listener (port 443) — only if certificate provided ───
resource "aws_lb_listener" "https" {
  count             = local.has_cert ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

# Host-based rules on HTTPS
resource "aws_lb_listener_rule" "https_staging" {
  count        = local.has_cert ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.staging.arn
  }

  condition {
    host_header {
      values = ["api-staging-cms.${var.domain}"]
    }
  }
}

resource "aws_lb_listener_rule" "https_production" {
  count        = local.has_cert ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.production.arn
  }

  condition {
    host_header {
      values = ["api-cms.${var.domain}"]
    }
  }
}

resource "aws_lb_listener_rule" "https_adminer" {
  count        = local.has_cert ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.adminer.arn
  }

  condition {
    host_header {
      values = ["db-cms.${var.domain}"]
    }
  }
}

# ─── Outputs ───
output "alb_dns_name" { value = aws_lb.main.dns_name }
output "alb_zone_id" { value = aws_lb.main.zone_id }
output "alb_arn" { value = aws_lb.main.arn }
output "alb_security_group_id" { value = aws_security_group.alb.id }

output "staging_target_group_arn" { value = aws_lb_target_group.staging.arn }
output "production_target_group_arn" { value = aws_lb_target_group.production.arn }
output "adminer_target_group_arn" { value = aws_lb_target_group.adminer.arn }
