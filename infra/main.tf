###############################################################################
# main.tf
# Root module. Wires the per-layer internal modules. U2 added the
# `landing` module (state bucket, OIDC provider, OIDC deploy role).
# U3 adds the network plane (`networking`), the public edge
# (`edge`), and the KMS key plane (`security`).
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

variable "project_name" {
  description = "Short project identifier used in resource names. Default: niahealth. Overridable per env."
  type        = string
  default     = "niahealth"
}

variable "domain_name" {
  description = "Primary domain name for the ACM cert + Route53 record. Used by the edge module."
  type        = string
  default     = "dev.niahealth.example.com"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the VPC. Default: 10.0.0.0/16. Overridable per env."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of 3 availability zones in the home region. Default: ca-central-1a/b/c."
  type        = list(string)
  default     = ["ca-central-1a", "ca-central-1b", "ca-central-1c"]
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS validation of the ACM cert. When null, the edge module falls back to EMAIL validation. Default null (terraform-only demo path)."
  type        = string
  default     = null
}

variable "waf_block_mode" {
  description = "When true, the WAFv2 managed rule groups use action=BLOCK (production posture). When false (default for dev), they use action=COUNT to avoid blocking tests."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Extra tags to apply to all resources. The 3 required tags (Environment, DataClass, Owner) are added by the AWS provider's default_tags block in providers.tf."
  type        = map(string)
  default = {
    Project    = "niahealth-compliance-mvp"
    ManagedBy  = "terraform"
    CostCenter = "eng-compliance"
  }
}

# ---------------------------------------------------------------------------
# Landing (U2): state bootstrap, OIDC provider, OIDC deploy role.
# ---------------------------------------------------------------------------
module "landing" {
  source = "./modules/landing"

  region      = var.region
  environment = var.environment

  # OIDC trust policy inputs.
  github_org  = var.github_org
  github_repo = var.github_repo

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Security (U3): KMS CMKs for the data + audit + logs planes.
# No upstream dependencies; can be applied first or in parallel.
# ---------------------------------------------------------------------------
module "security" {
  source = "./modules/security"

  region       = var.region
  environment  = var.environment
  project_name = var.project_name

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Networking (U3): VPC, public/private/isolated subnets, NAT, endpoints,
# flow logs. Consumed by `edge` (public subnets, VPC ID) and by
# future units (U4/U5/U6).
# ---------------------------------------------------------------------------
module "networking" {
  source = "./modules/networking"

  region       = var.region
  environment  = var.environment
  project_name = var.project_name

  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones

  # Wire the CWL CMK ARN from the security module to encrypt the
  # VPC flow log group. If the security module's CMK is not yet
  # available, leave flow_log_cloudwatch_kms_key_id null and the
  # v5 wrapper falls back to the AWS-managed CMK.
  flow_log_cloudwatch_kms_key_id = module.security.cwl_kms_key_arn

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Edge (U3): ACM cert, ALB, WAFv2 in public subnets. Depends on
# `networking` for VPC ID + public subnet IDs.
# ---------------------------------------------------------------------------
module "edge" {
  source = "./modules/edge"

  region       = var.region
  environment  = var.environment
  project_name = var.project_name

  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids

  domain_name     = var.domain_name
  route53_zone_id = var.route53_zone_id
  waf_block_mode  = var.waf_block_mode

  # ALB access logs deferred to U6 (data-tier S3 bucket does not
  # exist yet). When U6 lands, set this to the bucket name and
  # ALB access logs will begin flowing.
  alb_access_logs_bucket = null
  alb_access_logs_prefix = "alb"

  tags = var.tags
}
