include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../terraform/modules/ecs"
}

dependency "vpc" {
  config_path = "../../shared/vpc"
}

dependency "alb" {
  config_path = "../../shared/alb"
}

dependency "rds" {
  config_path = "../../shared/rds"
}

dependency "ecr" {
  config_path = "../ecr"
}

dependency "s3_data" {
  config_path = "../s3-data"
}

inputs = {
  # Shared VPC
  vpc_id             = dependency.vpc.outputs.vpc_id
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids

  # Shared ALB — staging target group
  alb_security_group_id = dependency.alb.outputs.alb_security_group_id
  target_group_arn      = dependency.alb.outputs.staging_target_group_arn

  # ECR
  ecr_repository_url = dependency.ecr.outputs.repository_url

  # Staging database on shared RDS
  db_address          = dependency.rds.outputs.db_address
  db_port             = dependency.rds.outputs.db_port
  db_name             = dependency.rds.outputs.staging_db_name
  db_username         = dependency.rds.outputs.staging_db_username
  db_password_ssm_arn = dependency.rds.outputs.staging_db_password_ssm_arn

  # Smallest Fargate
  cpu           = 256
  memory        = 512
  desired_count = 1

  # S3 data bucket
  s3_bucket = dependency.s3_data.outputs.bucket_name
  s3_region = dependency.s3_data.outputs.bucket_region

  # CORS — allow staging frontend
  cors_origins = "https://staging-cms.wizioners.com,http://localhost:3000"
}
