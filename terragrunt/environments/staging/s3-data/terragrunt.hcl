include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../terraform/modules/s3-data"
}
