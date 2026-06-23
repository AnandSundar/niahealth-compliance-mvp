###############################################################################
# modules/data/versions.tf
#
# The data module declares the AWS provider twice -- once as the
# default (used by the home-region resources: RDS, RDS Proxy, S3
# PHI bucket, IAM roles) and once as the "dr" alias (used by the
# cross-region replica bucket in ca-west-1). The alias is supplied
# by the root module via the module's `providers =` block.
#
# `configuration_aliases` tells Terraform that the child module
# EXPECTS the root to pass in a provider configuration for the
# alias. Without this declaration, the alias reference inside the
# child (`provider = aws.dr`) triggers a validate error.
#
# NOTE: this file is not in the U6 Files list, but it is required
# by Terraform 1.x for any child module that consumes a provider
# alias. The plan's Files list is strict, but `versions.tf` is a
# sibling to the existing `versions.tf` at the root and to
# provider alias declarations in other modules; adding one for
# the data module is a documented deviation (a 6-line boilerplate
# file).
###############################################################################

terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.50"
      configuration_aliases = [aws.dr]
    }
  }
}