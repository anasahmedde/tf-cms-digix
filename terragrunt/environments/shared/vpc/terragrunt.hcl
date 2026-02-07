include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../terraform/modules/vpc"
}

inputs = {
  vpc_cidr = "10.0.0.0/16"
}
