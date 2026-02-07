include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../terraform/modules/rds"
}

dependency "vpc" {
  config_path = "../vpc"
}

inputs = {
  vpc_id             = dependency.vpc.outputs.vpc_id
  vpc_cidr           = dependency.vpc.outputs.vpc_cidr
  private_subnet_ids = dependency.vpc.outputs.private_subnet_ids

  instance_class    = "db.t3.micro"   # Free tier eligible
  allocated_storage = 20
  db_username       = "dgx_admin"
}
