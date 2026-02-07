include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../terraform/modules/alb"
}

dependency "vpc" {
  config_path = "../vpc"
}

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
}

# NOTE: On first deploy, set certificate_arn = ""
# After dns-ssl is deployed, update this to use the cert and re-apply:
#   certificate_arn = dependency.dns_ssl.outputs.alb_certificate_arn
# Or just paste the ARN directly after dns-ssl outputs it.

inputs = {
  vpc_id            = dependency.vpc.outputs.vpc_id
  public_subnet_ids = dependency.vpc.outputs.public_subnet_ids
  domain            = local.account_vars.locals.domain

  # FIRST RUN: leave empty (HTTP only)
  # SECOND RUN: paste the ACM cert ARN from dns-ssl output
  certificate_arn = "arn:aws:acm:us-east-2:746393610736:certificate/745b01a3-6d3f-4a14-9366-56df1b64b2e4"
}
