include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../terraform/modules/s3-cloudfront"
}

dependency "dns_ssl" {
  config_path = "../../shared/dns-ssl"

  mock_outputs = {
    cloudfront_certificate_arn = ""
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
}

inputs = {
  domain                    = local.account_vars.locals.domain   # cms.wizioners.com (root)
  cloudfront_certificate_arn = dependency.dns_ssl.outputs.cloudfront_certificate_arn
}
