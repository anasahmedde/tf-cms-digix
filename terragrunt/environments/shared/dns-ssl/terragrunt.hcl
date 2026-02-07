include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../terraform/modules/dns-ssl"
}

dependency "alb" {
  config_path = "../alb"
}

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
}

inputs = {
  domain       = local.account_vars.locals.domain
  alb_dns_name = dependency.alb.outputs.alb_dns_name
  alb_zone_id  = dependency.alb.outputs.alb_zone_id

  # CloudFront domains will be added after staging/production are deployed
  # Then re-run: terragrunt apply
  staging_cloudfront_domain    = "d1x273q7voau0c.cloudfront.net"
  production_cloudfront_domain = "d7l83sekkjhz3.cloudfront.net"
}
