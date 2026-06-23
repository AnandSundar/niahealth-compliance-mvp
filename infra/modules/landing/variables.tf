###############################################################################
# modules/landing/variables.tf
# Inputs for the landing zone: state backend wiring, OIDC trust inputs,
# and resource tags. Defaults match the root module so most consumers
# can call this module with zero arguments.
###############################################################################

variable "region" {
  description = "AWS region. Data residency requires ca-central-1 for PHI."
  type        = string
  default     = "ca-central-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod). Used in resource names and tags."
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Short project identifier used in resource names. Keeps ARNs readable and grep-friendly."
  type        = string
  default     = "niahealth"
}

variable "github_org" {
  description = "GitHub organization that owns the deploy workflow. Pinned in the OIDC trust policy sub claim."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository that owns the deploy workflow. Pinned in the OIDC trust policy sub claim."
  type        = string
}

variable "tags" {
  description = "Extra tags to apply to landing-zone resources. The 3 required tags (Environment, DataClass, Owner) are added by the AWS provider's default_tags block in providers.tf."
  type        = map(string)
  default     = {}
}
