# terraform/modules/adminer/main.tf
# Adminer (DB admin UI) on Fargate — minimal resources
# Runs on production cluster, can connect to both staging + production DBs

variable "project" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }

# Shared infra
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "alb_security_group_id" { type = string }
variable "target_group_arn" { type = string }

# RDS
variable "db_address" { type = string }

locals {
  name_prefix = "${var.project}-adminer"
}

# ─── CloudWatch Logs ───
resource "aws_cloudwatch_log_group" "adminer" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 7
  tags = { Name = "${local.name_prefix}-logs" }
}

# ─── Security Group ───
resource "aws_security_group" "adminer" {
  name_prefix = "${local.name_prefix}-"
  vpc_id      = var.vpc_id
  description = "Adminer ECS"

  ingress {
    from_port       = 8080
    to_port         = 8080
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

  tags = { Name = "${local.name_prefix}-sg" }
  lifecycle { create_before_destroy = true }
}

# ─── IAM: Task Execution Role ───
resource "aws_iam_role" "adminer_exec" {
  name = "${local.name_prefix}-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "adminer_exec" {
  role       = aws_iam_role.adminer_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ─── Task Definition ───
resource "aws_ecs_task_definition" "adminer" {
  family                   = local.name_prefix
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256     # 0.25 vCPU — minimal
  memory                   = 512     # 0.5 GB — minimal
  execution_role_arn       = aws_iam_role.adminer_exec.arn

  container_definitions = jsonencode([{
    name      = "adminer"
    image     = "adminer:latest"
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [
      { name = "ADMINER_DEFAULT_SERVER", value = var.db_address },
      { name = "ADMINER_DESIGN",         value = "dracula" },
      { name = "ADMINER_PLUGINS",        value = "tables-filter tinymce" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.adminer.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "adminer"
      }
    }
  }])

  tags = { Name = "${local.name_prefix}-task" }
}

# ─── ECS Service ───
# Runs on the production cluster
data "aws_ecs_cluster" "production" {
  cluster_name = "${var.project}-production-cluster"
}

resource "aws_ecs_service" "adminer" {
  name            = local.name_prefix
  cluster         = data.aws_ecs_cluster.production.arn
  task_definition = aws_ecs_task_definition.adminer.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.adminer.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "adminer"
    container_port   = 8080
  }

  tags = { Name = "${local.name_prefix}-svc" }
}

output "service_name" { value = aws_ecs_service.adminer.name }
