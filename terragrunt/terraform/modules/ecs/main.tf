# terraform/modules/ecs/main.tf
# ECS Fargate service — registers with shared ALB target group

variable "project" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }

# Shared infra
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "alb_security_group_id" { type = string }
variable "target_group_arn" { type = string }   # From shared ALB

# ECR
variable "ecr_repository_url" { type = string }

# RDS
variable "db_address" { type = string }
variable "db_port" {
  type    = number
  default = 5432
}
variable "db_name" { type = string }
variable "db_username" { type = string }
variable "db_password_ssm_arn" { type = string }

# S3 (for app's boto3 usage)
variable "s3_bucket" {
  type    = string
  default = "markhorvideo"
}
variable "s3_region" {
  type    = string
  default = "eu-west-1"
}

# CORS
variable "cors_origins" {
  type    = string
  default = "*"
}

# Fargate sizing
variable "cpu" {
  type    = number
  default = 256
}
variable "memory" {
  type    = number
  default = 512
}
variable "desired_count" {
  type    = number
  default = 1
}
variable "container_port" {
  type    = number
  default = 8005
}

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ─── ECS Cluster ───
resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = var.environment == "production" ? "enabled" : "disabled"
  }

  tags = { Name = "${local.name_prefix}-cluster" }
}

# ─── IAM: Task Execution Role ───
resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.name_prefix}-ecs-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_ssm" {
  name = "${local.name_prefix}-ecs-ssm"
  role = aws_iam_role.ecs_task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters", "ssm:GetParameter"]
      Resource = [
        "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project}/${var.environment}/*",
        "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project}/shared/*"
      ]
    }]
  })
}

# ─── IAM: Task Role (app-level: S3/boto3) ───
resource "aws_iam_role" "ecs_task" {
  name = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ecs_s3" {
  name = "${local.name_prefix}-ecs-s3"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3BucketAccess"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = ["arn:aws:s3:::${var.s3_bucket}"]
      },
      {
        Sid      = "S3ObjectAccess"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:HeadObject"]
        Resource = ["arn:aws:s3:::${var.s3_bucket}/*"]
      }
    ]
  })
}

# ─── CloudWatch Logs ───
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = var.environment == "production" ? 30 : 7
  tags = { Name = "${local.name_prefix}-ecs-logs" }
}

# ─── ECS Security Group ───
resource "aws_security_group" "ecs" {
  name_prefix = "${local.name_prefix}-ecs-"
  vpc_id      = var.vpc_id
  description = "ECS ${var.environment}"

  ingress {
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
    description     = "From shared ALB"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-ecs-sg" }
  lifecycle { create_before_destroy = true }
}

# ─── Task Definition ───
resource "aws_ecs_task_definition" "main" {
  family                   = "${local.name_prefix}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "backend"
    image     = "${var.ecr_repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    environment = [
      { name = "PGHOST",       value = var.db_address },
      { name = "PGPORT",       value = tostring(var.db_port) },
      { name = "PGDATABASE",   value = var.db_name },
      { name = "PGUSER",       value = var.db_username },
      { name = "PG_MIN_CONN",  value = "1" },
      { name = "PG_MAX_CONN",  value = "5" },
      { name = "S3_BUCKET",    value = var.s3_bucket },
      { name = "AWS_REGION",   value = var.s3_region },
      { name = "ENVIRONMENT",  value = var.environment },
      { name = "PORT",         value = tostring(var.container_port) },
      { name = "CORS_ORIGINS", value = var.cors_origins },
    ]

    secrets = [{
      name      = "PGPASSWORD"
      valueFrom = var.db_password_ssm_arn
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "backend"
      }
    }
  }])

  tags = { Name = "${local.name_prefix}-backend-task" }
}

# ─── ECS Service (registers with shared ALB target group) ───
resource "aws_ecs_service" "main" {
  name            = "${local.name_prefix}-backend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "backend"
    container_port   = var.container_port
  }

  lifecycle {
    ignore_changes = [task_definition]
  }

  tags = { Name = "${local.name_prefix}-backend-svc" }
}

output "cluster_name" { value = aws_ecs_cluster.main.name }
output "service_name" { value = aws_ecs_service.main.name }
output "task_definition_family" { value = aws_ecs_task_definition.main.family }
