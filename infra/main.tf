###############################################################################
# main.tf
# Root module. Wires the per-layer internal modules. U2 added the
# `landing` module (state bucket, OIDC provider, OIDC deploy role).
# U3 adds the network plane (`networking`), the public edge
# (`edge`), and the KMS key plane (`security`).
# U4 adds the identity plane (`identity`): IAM Identity Center
# permission sets, per-service IAM roles with permission boundaries,
# the single break-glass IAM user, IAM Access Analyzer, Secrets
# Manager secrets, and rotation.
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
# U4 extends this module with Secrets Manager secrets (secrets.tf)
# and rotation configuration (secrets-rotation.tf). The rotation
# Lambda's execution role is owned by the identity module and
# passed in below as `lambda_rotation_role_arn` (the security
# module's rotation policy uses it as the principal).
# ---------------------------------------------------------------------------
module "security" {
  source = "./modules/security"

  region       = var.region
  environment  = var.environment
  project_name = var.project_name

  # Forwarded from the identity module -- the rotation Lambda's
  # execution role ARN. Null when the identity module is not yet
  # wired (U4 fix-up).
  lambda_rotation_role_arn = module.identity.lambda_rotation_role_arn

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

# ---------------------------------------------------------------------------
# Identity (U4): IAM Identity Center permission sets, per-service
# IAM roles with permission boundaries, break-glass IAM user,
# Access Analyzer. Depends on `landing` for the OIDC provider ARN
# (used by the ECS task role's trust policy) and on `security`
# for the 4 CMK ARNs (scoped into per-role permissions).
# ---------------------------------------------------------------------------
module "identity" {
  source = "./modules/identity"

  region       = var.region
  environment  = var.environment
  project_name = var.project_name

  # OIDC provider ARN from the landing module. The ECS task
  # role's trust policy references the federated principal of
  # this provider when the task assumes downstream roles via
  # web identity.
  oidc_provider_arn = module.landing.oidc_provider_arn

  # 4 CMK ARNs from the security module. Each role below scopes
  # its kms:* permissions to ONE of these ARNs per key domain
  # (RDS Proxy role -> rds_kms_key, ECS task role -> s3_phi_kms,
  # Firehose role -> cloudtrail_kms, etc.).
  rds_kms_key_arn        = module.security.rds_kms_key_arn
  s3_phi_kms_key_arn     = module.security.s3_phi_kms_key_arn
  cloudtrail_kms_key_arn = module.security.cloudtrail_kms_key_arn
  cwl_kms_key_arn        = module.security.cwl_kms_key_arn

  # Secret ARNs from the security module. The ECS task role +
  # Lambda rotation role scope their secretsmanager:* permissions
  # to these ARNs.
  rds_master_password_secret_arn = module.security.rds_master_password_secret_arn
  cognito_client_secret_arn      = module.security.cognito_client_secret_arn

  tags = var.tags
}
