###############################################################################
# main.tf
# Root module. Wires the per-layer internal modules. In U2 we only
# stand up the `landing` module (state bucket, OIDC provider, OIDC
# deploy role). Networking, edge, identity, observability, data tier,
# compute, and CI workflows land in U3+ as separate modules.
#
# Module layout follows Anton Babenko's convention: each layer is a
# self-contained subdirectory under modules/ with main/variables/
# outputs split, and external modules are pinned via ?ref=... for
# supply-chain control.
#
# Root-level input variables are declared here (instead of a separate
# variables.tf) because the U2 file list contains only main.tf at the
# root. In a later unit we can split them out if more layers land.
###############################################################################

variable "region" {
  description = "AWS region for the root provider. Data residency: ca-central-1."
  type        = string
  default     = "ca-central-1"
}

variable "environment" {
  description = "Deployment environment name. One of: dev, staging, prod."
  type        = string
  default     = "dev"
}

variable "github_org" {
  description = "GitHub organization (or user) that owns the deploy workflow. Used in the OIDC trust policy sub claim."
  type        = string
  default     = "niahealth"
}

variable "github_repo" {
  description = "GitHub repository name that owns the deploy workflow. Used in the OIDC trust policy sub claim."
  type        = string
  default     = "niahealth-compliance-mvp"
}

variable "tags" {
  description = "Extra tags to apply to landing-zone resources. The 3 required tags (Environment, DataClass, Owner) are added by the AWS provider's default_tags block in providers.tf."
  type        = map(string)
  default = {
    Project    = "niahealth-compliance-mvp"
    ManagedBy  = "terraform"
    CostCenter = "eng-compliance"
  }
}

module "landing" {
  source = "./modules/landing"

  region      = var.region
  environment = var.environment

  # OIDC trust policy inputs.
  github_org  = var.github_org
  github_repo = var.github_repo

  tags = var.tags
}
