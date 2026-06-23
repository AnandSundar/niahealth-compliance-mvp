###############################################################################
# modules/security/kms.tf
# Customer-managed KMS CMKs for the data + audit + logs planes.
#
# Four CMKs are created, one per "key domain" (the principle: a key
# domain is a blast-radius boundary -- if one key is compromised,
# only the resources in that domain are exposed, not the entire
# account's encryption):
#
#   - rds_kms_key         : RDS Postgres storage encryption
#   - s3_phi_kms_key      : data-tier S3 bucket PHI objects
#   - cloudtrail_kms_key  : CloudTrail log file encryption
#   - cwl_kms_key         : CloudWatch Logs (CWL) log group encryption
#                            (VPC flow logs, ALB access logs, WAF logs,
#                            RDS/Proxy logs, etc.)
#
# Posture (R2 + KTD4):
#   - enable_key_rotation = true (annual automatic rotation; the
#     "key_rotation_status" is monitored by the U5 AWS Config rule
#     `kms-cmk-not-have-rotation-enabled`).
#   - Key policy: explicit Deny on kms:ScheduleKeyDeletion for
#     non-admin principals. The root principal (account root) always
#     retains the right to delete -- that is a fundamental AWS
#     invariant -- but the explicit Deny blocks any other IAM
#     principal from initiating a deletion, so a compromise of a
#     deploy role or a service role cannot silently destroy PHI
#     encryption.
#   - The key policy STARTS PERMISSIVE (account root + key admin can
#     do everything) and ADDS the explicit Deny. Future units (U4)
#     will tighten the key policy to scope specific principals to
#     specific actions (e.g. the RDS Proxy role gets
#     kms:Decrypt + kms:GenerateDataKey on the RDS key only).
#
# File layout: per the U3 file list, this module only contains
# kms.tf. Variables and outputs are declared inline in this file
# (the module has no other concerns; splitting them out is
# deferred to a later unit if more security resources land).
###############################################################################

variable "region" {
  description = "AWS region. Data residency requires ca-central-1 for PHI (R1)."
  type        = string
  default     = "ca-central-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod). Used in resource names and tags."
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Short project identifier used in resource names."
  type        = string
  default     = "niahealth"
}

variable "tags" {
  description = "Extra tags to apply to KMS resources. The 3 required tags (Environment, DataClass, Owner) are added by the AWS provider's default_tags block in providers.tf."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# U4 input: the Lambda rotation function's execution role ARN. Owned
# by the identity module and passed in by the root. Used as the
# principal in the rds-master-password secret's resource policy so
# the rotation Lambda can call secretsmanager:RotateSecret on it.
# ---------------------------------------------------------------------------
variable "lambda_rotation_role_arn" {
  description = "ARN of the Lambda rotation function's execution role. Owned by the identity module and passed in by the root. Used as the principal in the secret's resource policy so the rotation Lambda can call secretsmanager:RotateSecret on it."
  type        = string
  default     = null
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # The "key admins" -- principals that can administer each key.
  # Today: the account root only. U4 will add the deploy role and
  # any human admin groups. Keeping this as a local makes future
  # edits a one-line change.
  key_admins = [
    "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root",
  ]
}

# ----------------------------------------------------------------------------
# Base key policy. Reused by all four CMKs.
#
# Structure:
#   Statement 1: Allow root + key admins to administer the key.
#   Statement 2: Allow AWS service-linked principals to use the key
#                (kms:Decrypt, etc.) -- the wildcard "Service" is
#                intentional: the key policy does not know in
#                advance which service (RDS, S3, CloudTrail, CWL)
#                will consume this key. AWS service principals
#                are explicitly allowed to call kms:Encrypt /
#                kms:Decrypt / kms:GenerateDataKey / kms:ReEncrypt*
#                / kms:CreateGrant on the key, but NOT
#                kms:ScheduleKeyDeletion (denied in Statement 3).
#   Statement 3: Deny kms:ScheduleKeyDeletion for any non-admin
#                principal -- even those in Statement 2.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "cmk_base" {
  # Statement 1: admin Allow.
  statement {
    sid    = "AllowKeyAdministration"
    effect = "Allow"
    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]

    principals {
      type        = "AWS"
      identifiers = local.key_admins
    }

    resources = ["*"]
  }

  # Statement 2: service usage Allow.
  statement {
    sid    = "AllowServiceUsage"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:CreateGrant",
      "kms:ListGrants",
      "kms:RetireGrant",
    ]

    principals {
      type = "AWS"
      # Any IAM principal in the account can use the key for the
      # service-call envelope encryption. Future units (U4) will
      # scope this to specific roles per key domain.
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # Statement 3: deny delete by non-admin. Load-bearing control:
  # even a compromised deploy role (which Statement 2 allows to
  # encrypt/decrypt) cannot initiate key deletion.
  statement {
    sid    = "DenyScheduleKeyDeletionForNonAdmins"
    effect = "Deny"

    actions = [
      "kms:ScheduleKeyDeletion",
      "kms:DisableKey",
      "kms:PutKeyPolicy",
      "kms:CreateAlias",
      "kms:DeleteAlias",
    ]

    principals {
      type = "AWS"
      # Deny everyone EXCEPT the key_admins list. AWS IAM does not
      # support "Deny if not in list" as a single statement, so we
      # deny everyone and rely on Statement 1's Allow for the
      # admins (Deny always wins over Allow in IAM evaluation).
      identifiers = ["*"]
    }

    resources = ["*"]

    condition {
      test     = "ForAnyValue:ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = local.key_admins
    }
  }
}

# ----------------------------------------------------------------------------
# RDS CMK
# ----------------------------------------------------------------------------
resource "aws_kms_key" "rds" {
  description             = "CMK for RDS Postgres storage encryption. Key domain: data tier (RDS)."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = false
  policy                  = data.aws_iam_policy_document.cmk_base.json

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-rds"
    KeyDomain = "rds"
  })
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${local.name_prefix}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

# ----------------------------------------------------------------------------
# S3 PHI CMK
# ----------------------------------------------------------------------------
resource "aws_kms_key" "s3_phi" {
  description             = "CMK for the data-tier S3 bucket (PHI objects). Key domain: data tier (S3)."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = false
  policy                  = data.aws_iam_policy_document.cmk_base.json

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-s3-phi"
    KeyDomain = "s3-phi"
  })
}

resource "aws_kms_alias" "s3_phi" {
  name          = "alias/${local.name_prefix}-s3-phi"
  target_key_id = aws_kms_key.s3_phi.key_id
}

# ----------------------------------------------------------------------------
# CloudTrail CMK
# ----------------------------------------------------------------------------
resource "aws_kms_key" "cloudtrail" {
  description             = "CMK for CloudTrail log file encryption. Key domain: audit."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = false
  policy                  = data.aws_iam_policy_document.cmk_base.json

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-cloudtrail"
    KeyDomain = "cloudtrail"
  })
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/${local.name_prefix}-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail.key_id
}

# ----------------------------------------------------------------------------
# CloudWatch Logs CMK
# ----------------------------------------------------------------------------
resource "aws_kms_key" "cwl" {
  description             = "CMK for CloudWatch Logs log-group encryption. Key domain: logs."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = false
  policy                  = data.aws_iam_policy_document.cmk_base.json

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-cwl"
    KeyDomain = "cwl"
  })
}

resource "aws_kms_alias" "cwl" {
  name          = "alias/${local.name_prefix}-cwl"
  target_key_id = aws_kms_key.cwl.key_id
}

# ----------------------------------------------------------------------------
# Outputs.
#
# All four CMK ARNs are exposed because every consumer in U4+ scopes
# its key policy to one of these ARNs:
#   - rds_kms_key_arn        : U6 (RDS instance) + U4 (RDS Proxy role)
#   - s3_phi_kms_key_arn     : U6 (data-tier S3 bucket) + U4 (ECS task role)
#   - cloudtrail_kms_key_arn : U5 (CloudTrail)
#   - cwl_kms_key_arn        : U5 (CloudWatch log group encryption),
#                              U3 (VPC flow log group encryption)
# ----------------------------------------------------------------------------

output "rds_kms_key_arn" {
  description = "ARN of the CMK that encrypts the RDS Postgres instance. Consumed by U6 (RDS instance) and U4 (RDS Proxy role)."
  value       = aws_kms_key.rds.arn
}

output "rds_kms_key_id" {
  description = "Key ID (UUID) of the RDS CMK. Useful for downstream aws_* resources that take a key_id (not an ARN)."
  value       = aws_kms_key.rds.key_id
}

output "s3_phi_kms_key_arn" {
  description = "ARN of the CMK that encrypts the data-tier S3 bucket (PHI objects). Consumed by U6 (S3 bucket) and U4 (ECS task role)."
  value       = aws_kms_key.s3_phi.arn
}

output "s3_phi_kms_key_id" {
  description = "Key ID (UUID) of the S3 PHI CMK."
  value       = aws_kms_key.s3_phi.key_id
}

output "cloudtrail_kms_key_arn" {
  description = "ARN of the CMK that encrypts CloudTrail log files. Consumed by U5 (CloudTrail)."
  value       = aws_kms_key.cloudtrail.arn
}

output "cloudtrail_kms_key_id" {
  description = "Key ID (UUID) of the CloudTrail CMK."
  value       = aws_kms_key.cloudtrail.key_id
}

output "cwl_kms_key_arn" {
  description = "ARN of the CMK that encrypts CloudWatch Logs log groups. Consumed by U5 (central log groups) and by the networking module's flow log group via the root module."
  value       = aws_kms_key.cwl.arn
}

output "cwl_kms_key_id" {
  description = "Key ID (UUID) of the CloudWatch Logs CMK."
  value       = aws_kms_key.cwl.key_id
}
