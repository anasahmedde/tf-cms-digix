# terraform/modules/rds/main.tf
# Single RDS PostgreSQL with staging + production databases

variable "project" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}
variable "allocated_storage" {
  type    = number
  default = 20
}
variable "db_username" {
  type    = string
  default = "dgx_admin"
}

locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "${local.name_prefix}-db-subnet" }
}

resource "aws_security_group" "rds" {
  name_prefix = "${local.name_prefix}-rds-"
  vpc_id      = var.vpc_id
  description = "RDS PostgreSQL from VPC"

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-rds-sg" }
  lifecycle { create_before_destroy = true }
}

# ─── Passwords ───
resource "random_password" "master" {
  length  = 24
  special = false
}

resource "random_password" "staging" {
  length  = 24
  special = false
}

resource "random_password" "production" {
  length  = 24
  special = false
}

# ─── SSM Parameters ───
resource "aws_ssm_parameter" "db_master_password" {
  name  = "/${var.project}/shared/db/master_password"
  type  = "SecureString"
  value = random_password.master.result
}

resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project}/shared/db/host"
  type  = "String"
  value = aws_db_instance.main.address
}

resource "aws_ssm_parameter" "db_port" {
  name  = "/${var.project}/shared/db/port"
  type  = "String"
  value = tostring(aws_db_instance.main.port)
}

# Per-env params
resource "aws_ssm_parameter" "db_password_staging" {
  name  = "/${var.project}/staging/db/password"
  type  = "SecureString"
  value = random_password.staging.result
}

resource "aws_ssm_parameter" "db_password_production" {
  name  = "/${var.project}/production/db/password"
  type  = "SecureString"
  value = random_password.production.result
}

resource "aws_ssm_parameter" "db_name_staging" {
  name  = "/${var.project}/staging/db/name"
  type  = "String"
  value = "dgx_staging"
}

resource "aws_ssm_parameter" "db_name_production" {
  name  = "/${var.project}/production/db/name"
  type  = "String"
  value = "dgx_production"
}

resource "aws_ssm_parameter" "db_username_staging" {
  name  = "/${var.project}/staging/db/username"
  type  = "String"
  value = "dgx_staging_user"
}

resource "aws_ssm_parameter" "db_username_production" {
  name  = "/${var.project}/production/db/username"
  type  = "String"
  value = "dgx_production_user"
}

# ─── RDS Instance ───
resource "aws_db_instance" "main" {
  identifier = "${var.project}-shared-postgres"

  engine         = "postgres"
  engine_version = "18.1"
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = 100
  storage_type          = "gp3"

  db_name  = "dgx_production"
  username = var.db_username
  password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az                  = false
  publicly_accessible       = false
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project}-shared-final-snapshot"
  backup_retention_period   = 1
  deletion_protection       = true

  performance_insights_enabled = true

  tags = { Name = "${var.project}-shared-postgres" }
}

# ─── Outputs ───
output "db_endpoint" { value = aws_db_instance.main.endpoint }
output "db_address" { value = aws_db_instance.main.address }
output "db_port" { value = aws_db_instance.main.port }
output "db_security_group_id" { value = aws_security_group.rds.id }

output "staging_db_name" { value = "dgx_staging" }
output "staging_db_username" { value = "dgx_staging_user" }
output "staging_db_password_ssm_arn" { value = aws_ssm_parameter.db_password_staging.arn }

output "production_db_name" { value = "dgx_production" }
output "production_db_username" { value = "dgx_production_user" }
output "production_db_password_ssm_arn" { value = aws_ssm_parameter.db_password_production.arn }
