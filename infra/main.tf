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
# U5 adds the observability plane (`observability`): CloudTrail,
# AWS Config, GuardDuty, Security Hub, Macie, and the central
# Kinesis Firehose that fans VPC Flow Logs + ALB/WAF logs into the
# immutable audit S3 bucket.
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

variable "dr_region" {
  description = "AWS region for the cross-region replica of the PHI S3 bucket (U6). Default ca-west-1 (the second Canadian region; same data-residency envelope as ca-central-1, satisfying R1 + PIPEDA Schedule 1 + PHIPA s.13)."
  type        = string
  default     = "ca-west-1"
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
# Provider alias for the DR region (U6). The data module's
# lifecycle.tf declares the cross-region replica resources under
# `provider = aws.dr` so Terraform knows to route those calls to
# the DR region. The provider inherits the default_tags block from
# the unaliased provider below; default_tags apply per-provider
# in the v5 provider, so we redeclare the block here.
# ---------------------------------------------------------------------------
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Environment = "dev"
      DataClass   = "phi"
      Owner       = "niahealth-eng"
    }
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

# ---------------------------------------------------------------------------
# Observability (U5): CloudTrail, AWS Config, GuardDuty, Security
# Hub, Macie, and the central Kinesis Firehose that fans VPC Flow
# Logs + ALB/WAF logs into the immutable audit S3 bucket.
#
# Depends on:
#   - `security` for the 4 CMK ARNs (cloudtrail + cwl for log
#     encryption; s3_phi for completeness).
#   - `networking` for the VPC Flow Logs CloudWatch log group
#     ARN (the subscription filter fans those logs into Firehose).
#   - `edge` for the ALB ARN and WAF WebACL ARN (reserved for
#     U6/U7 access-log wiring; the values are not consumed by U5
#     but the module signature requires them).
#   - `identity` for the Firehose IAM role ARN (assumed by
#     Firehose when delivering to the audit bucket) and the
#     paging SNS topic ARN (Critical/High Security Hub findings).
# ---------------------------------------------------------------------------
module "observability" {
  source = "./modules/observability"

  region       = var.region
  environment  = var.environment
  project_name = var.project_name

  # 3 CMK ARNs from the security module. cloudtrail + cwl are
  # consumed; s3_phi is carried for completeness (the audit
  # bucket uses the cloudtrail CMK by design so PHI cannot
  # pivot through the audit CMK).
  cloudtrail_kms_key_arn = module.security.cloudtrail_kms_key_arn
  cwl_kms_key_arn        = module.security.cwl_kms_key_arn
  s3_phi_kms_key_arn     = module.security.s3_phi_kms_key_arn

  # VPC Flow Log group ARN from the networking module. The
  # subscription filter on this log group is the load-bearing
  # piece that gets the flow logs into the central Firehose
  # for archive in the audit bucket.
  vpc_flow_log_group_arn = module.networking.vpc_flow_log_destination_arn

  # ALB + WAF ARNs from the edge module. Not consumed by U5
  # (U5 does not create new log groups for ALB/WAF; it expects
  # those groups to be created by U6/U7). The variables are
  # passed so the module signature is consistent and U6/U7
  # can add the access-log wiring in a follow-up.
  alb_arn         = module.edge.alb_arn
  waf_web_acl_arn = module.edge.waf_web_acl_arn

  # Firehose IAM role ARN + paging SNS topic ARN from the
  # identity module. The Firehose role is assumed when
  # Firehose delivers to the audit bucket; the SNS topic is
  # paged on Critical/High Security Hub findings.
  firehose_role_arn    = module.identity.firehose_role_arn
  paging_sns_topic_arn = module.identity.paging_sns_topic_arn

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Data (U6): RDS Postgres + RDS Proxy + S3 PHI bucket + cross-
# region replication + data-ingest IAM role. The data tier is
# the most security-relevant plane: PHI lives here. Every input
# to this module is wired from a module whose blast radius is
# bounded by an explicit deny (see modules/data/variables.tf for
# the cross-module seam map).
#
# Depends on:
#   - `security`     : rds CMK (RDS storage encryption), s3_phi
#                       CMK (PHI bucket encryption), cwl CMK
#                       (RDS log group encryption), rds-master-
#                       password secret ARN (RDS Proxy auth).
#   - `networking`   : VPC ID (RDS / RDS Proxy SGs), database
#                       subnets (RDS subnet group + RDS Proxy
#                       placement), isolated subnets (RDS SG
#                       ingress placeholder; U7 tightens).
#   - `identity`     : rds-proxy-role ARN (Proxy IAM auth),
#                       ecs-task-role ARN (reserved for U7;
#                       carries through for auditability),
#                       service-boundary ARN (data-ingest-role
#                       permissions boundary).
# ---------------------------------------------------------------------------
module "data" {
  source = "./modules/data"

  # Provider passthroughs. The data module's lifecycle.tf declares
  # the cross-region replica resources under `provider = aws.dr`;
  # the alias must be passed in from the root so Terraform can
  # resolve it. Without these provider passthroughs, validate
  # fails with "Provider configuration not present".
  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  region       = var.region
  dr_region    = var.dr_region
  environment  = var.environment
  project_name = var.project_name

  # Network placement. The networking module exposes one "no-NAT,
  # no-IGW" subnet tier (isolated_subnet_ids, mapped from vpc.
  # database_subnets). Both the RDS instance + RDS Proxy and the
  # ECS task SG ingress use this same tier; U7 tightens the RDS
  # SG ingress to the ECS task SG specifically.
  vpc_id              = module.networking.vpc_id
  database_subnet_ids = module.networking.isolated_subnet_ids
  isolated_subnet_ids = module.networking.isolated_subnet_ids

  # CMKs from the security module.
  rds_kms_key_arn    = module.security.rds_kms_key_arn
  s3_phi_kms_key_arn = module.security.s3_phi_kms_key_arn
  cwl_kms_key_arn    = module.security.cwl_kms_key_arn

  # Identity / secrets.
  rds_proxy_role_arn             = module.identity.rds_proxy_role_arn
  ecs_task_role_arn              = module.identity.ecs_task_role_arn
  rds_master_password_secret_arn = module.security.rds_master_password_secret_arn
  service_boundary_arn           = module.identity.service_boundary_arn

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Compute (U7): ECS Fargate + Cognito + ECR + sample app.
# The compute module owns the runtime plane:
#   - ECR repository (image registry; immutable, scanning on push)
#   - ECS Fargate cluster + service + task definition
#   - Cognito User Pool + User Pool Client + clinicians group
#   - IAM roles for the task (execution + runtime)
#   - ALB target group + listener rule wiring routes to Fargate
#
# Depends on:
#   - security  : s3_phi CMK (ECR), cwl CMK (log groups), cognito
#                 client secret (passed to the container as an env
#                 var via the task definition's `secrets` block).
#   - networking: VPC ID (SGs, target group), isolated subnets
#                 (Fargate task placement).
#   - edge      : ALB SG (ECS task SG ingress), ALB listener ARN
#                 (listener rule attachment), ALB DNS name (app URL).
#   - data      : RDS Proxy endpoint (RDS_PROXY_ENDPOINT env var),
#                 data bucket name (reserved; not used in MVP),
#                 RDS SG IDs (passed but the actual SG tightening
#                 is a U6 follow-up; the compute module's task
#                 role is the canonical consumer).
#   - observability: audit bucket name (AUDIT_BUCKET_NAME env var).
#   - identity  : service boundary (task role permissions boundary).
# ---------------------------------------------------------------------------
module "compute" {
  source = "./modules/compute"

  region       = var.region
  environment  = var.environment
  project_name = var.project_name

  # Network placement. The ECS tasks run in isolated subnets
  # (no NAT, no IGW) -- the same tier as the RDS instance and
  # the RDS Proxy. Tasks reach AWS services via the VPC
  # endpoints (Secrets Manager, ECR, KMS, CloudWatch Logs)
  # created by the networking module.
  vpc_id              = module.networking.vpc_id
  isolated_subnet_ids = module.networking.isolated_subnet_ids

  # Edge wiring. The ECS task SG accepts ingress from the ALB
  # SG; the listener rule attaches to the ALB's HTTPS listener.
  alb_security_group_id = module.edge.alb_security_group_id
  alb_listener_arn      = module.edge.alb_listener_https_arn
  alb_dns_name          = module.edge.alb_dns_name

  # CMKs. The s3_phi CMK encrypts the ECR repo (image encryption
  # domain stays consistent with the data the image processes);
  # the CWL CMK encrypts the ECS cluster + app log groups.
  s3_phi_kms_key_arn = module.security.s3_phi_kms_key_arn
  cwl_kms_key_arn    = module.security.cwl_kms_key_arn

  # Data plane. The app connects to the RDS Proxy (NOT the RDS
  # instance directly); the data_ingest role is reserved for a
  # future ingest path. The RDS SG IDs are passed for the
  # tightening follow-up; the compute module's task role is
  # the canonical consumer of the rds-db:connect permission.
  rds_proxy_endpoint          = module.data.rds_proxy_endpoint
  rds_db_name                 = module.data.rds_db_name
  rds_db_user                 = "niahealth_app"
  rds_proxy_security_group_id = module.data.rds_proxy_security_group_id
  rds_security_group_id       = module.data.rds_security_group_id
  s3_phi_bucket_name          = module.data.data_bucket_name

  # Audit log writes. The access-request + delete-my-data routes
  # write here; this is a DIFFERENT bucket from the data-tier
  # PHI bucket (which the data_ingest role covers).
  audit_bucket_name = module.observability.audit_bucket_name

  # Secrets. The Cognito client secret is passed to the
  # container as the COGNITO_CLIENT_SECRET env var via the task
  # definition's `secrets` block -- never baked into the image.
  cognito_client_secret_arn = module.security.cognito_client_secret_arn

  # Identity. The U4 service boundary is attached to the U7
  # task role (same blast-radius cap as the other service
  # roles). The U4 ecs_task_role is passed for cross-module
  # auditability only; U7 has its own task role with the
  # same boundary.
  ecs_task_role_arn    = module.identity.ecs_task_role_arn
  service_boundary_arn = module.identity.service_boundary_arn

  tags = var.tags
}
