include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../terraform/modules/adminer"
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

inputs = {
  # Shared VPC
  vpc_id             = dependency.vpc.outputs.vpc_id
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids

  # Shared ALB — adminer target group
  alb_security_group_id = dependency.alb.outputs.alb_security_group_id
  target_group_arn      = dependency.alb.outputs.adminer_target_group_arn

  # RDS host (adminer login page lets you pick which DB)
  db_address = dependency.rds.outputs.db_address
}
