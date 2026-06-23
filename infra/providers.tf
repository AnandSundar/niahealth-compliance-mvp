###############################################################################
# providers.tf
# Default AWS provider configuration. Default tags are the 3 required by
# the policy-as-code suite (see infra/policies/conftest.rego and
# infra/policies/tflint.hcl). The backend "s3" block here is a STUB:
# the real backend is configured in backend.tf via partial configuration
# so the one-time bootstrap script can write the bucket + kms_key_id
# values without editing this file.
###############################################################################

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = "dev"
      DataClass   = "phi"
      Owner       = "niahealth-eng"
    }
  }

  # The real S3 backend is in backend.tf (partial configuration).
  # Terraform requires the block to be syntactically present even when
  # the values are sourced from variables / a backend config file.
  # Leaving a stub here would be a footgun, so we intentionally omit it
  # from this file and keep the partial configuration in backend.tf.
}

# The tls provider is used (only) by the OIDC module for thumbprint
# calculations on the GitHub OIDC provider certificate. Declaring it
# here keeps the dependency graph explicit.
provider "tls" {}
