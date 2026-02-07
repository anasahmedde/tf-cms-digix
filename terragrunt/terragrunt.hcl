# Root terragrunt.hcl — all child modules inherit this

locals {
  account_vars     = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  environment_vars = try(read_terragrunt_config(find_in_parent_folders("env.hcl")), { locals = { environment = "shared" } })

  account_id  = local.account_vars.locals.account_id
  aws_region  = local.account_vars.locals.aws_region
  project     = local.account_vars.locals.project
  environment = local.environment_vars.locals.environment
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"

  default_tags {
    tags = {
      Project     = "${local.project}"
      Environment = "${local.environment}"
      ManagedBy   = "terragrunt"
    }
  }
}
EOF
}

remote_state {
  backend = "s3"
  config = {
    encrypt        = true
    bucket         = "${local.project}-terraform-state"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    dynamodb_table = "${local.project}-terraform-locks"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

inputs = {
  project     = local.project
  environment = local.environment
  aws_region  = local.aws_region
}
