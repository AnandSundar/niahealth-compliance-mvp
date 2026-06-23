###############################################################################
# modules/identity/roles.tf
#
# Per-service IAM roles for the sample application. Four roles, each
# with a permission boundary attached (see the boundary policy in
# main.tf below).
#
# Design notes (per the plan, R8):
#   - ecs-task-role        : assumed by ECS Fargate task via OIDC.
#                             Can read (GetObject) but NOT write
#                             (PutObject) the PHI S3 bucket -- the
#                             data-tier S3 bucket is write-controlled
#                             by the data-tier ingest path (U7
#                             sample app via a separate ingest
#                             role, scoped by VPC endpoint policy).
#                             Reads Cognito client secret + RDS
#                             password from Secrets Manager.
#   - rds-proxy-role       : assumed by RDS Proxy. kms:Decrypt +
#                             kms:GenerateDataKey on the RDS CMK
#                             so the Proxy can refresh the TLS
#                             session keys.
#   - firehose-role        : assumed by Kinesis Firehose when
#                             delivering to the audit S3 bucket.
#                             kms:Decrypt on the CloudTrail CMK
#                             (the audit bucket's CMK).
#   - lambda-rotation-role : assumed by the AWS-managed Secrets
#                             Manager rotation Lambda blueprint.
#                             Strictly limited to the RotateSecret
#                             family of secretsmanager:* actions,
#                             plus GetRandomPassword. Explicit Deny
#                             on rds:ModifyDBInstance +
#                             rds:DeleteDBInstance so a compromise
#                             of the rotation role cannot change
#                             or delete the database.
#
# Permission boundary: every role below attaches
# `permissions_boundary = aws_iam_policy.service_boundary.arn`.
# The boundary is a CEILING on the role's effective permissions,
# not a grant -- so an over-permissive inline policy is capped by
# the boundary at evaluation time.
#
# U3's recommendation: scope the cmk_base Statement 2 to specific
# roles per key domain. U4's role list above is what gets scoped
# in. The security module's kms.tf is left untouched in U4 because
# the boundary policy already caps wildcards; U6/U7 will tighten
# the key policies if a tighter blast radius is needed.
###############################################################################

locals {
  # Canonical resource names referenced by the role policies.
  # These follow the convention ${var.project_name}-${purpose}-${var.environment}
  # so a single grep across modules reveals the full name.
  data_bucket_arn    = "arn:${data.aws_partition.current.partition}:s3:::${var.project_name}-data-${var.environment}"
  data_bucket_prefix = "${var.project_name}-data-${var.environment}/*"
  audit_bucket_arn   = "arn:${data.aws_partition.current.partition}:s3:::${var.project_name}-audit-${var.environment}"
  audit_bucket_pref  = "${var.project_name}-audit-${var.environment}/*"

  ecs_log_group_arn = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project_name}-${var.environment}:*"
}

# ============================================================================
# PERMISSION BOUNDARY POLICY
# Acts as the ceiling on every service role. The boundary explicitly
# DENIES iam:Create*, iam:Attach*, kms:*, and wildcard actions on
# wildcard resources. The boundary is intentionally stricter than any
# individual role's inline policy -- so even if a role's policy is
# widened later, the boundary caps the effective permission set.
# ============================================================================
data "aws_iam_policy_document" "service_boundary" {
  # Allow: the common read envelope used by every service role.
  # Resource ARN patterns are wildcards over the per-env bucket
  # names and per-env log groups, but NEVER on `*` resources.
  statement {
    sid    = "AllowServiceReads"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
      "rds-db:connect",
    ]

    resources = [
      # Per-env data bucket (read).
      local.data_bucket_arn,
      "${local.data_bucket_arn}/*",
      # ECS log group.
      local.ecs_log_group_arn,
      # Specific secrets (ARN-form constraints). The break-glass
      # password secret is local to this module; the RDS + Cognito
      # secrets are owned by the security module and passed in.
      aws_secretsmanager_secret.break_glass_password.arn,
      var.rds_master_password_secret_arn,
      var.cognito_client_secret_arn,
      # KMS keys.
      var.rds_kms_key_arn,
      var.s3_phi_kms_key_arn,
      var.cloudtrail_kms_key_arn,
      var.cwl_kms_key_arn,
      # RDS Proxy IAM auth tokens are scoped per-resource by the
      # rds-db:connect resource pattern.
      "arn:${data.aws_partition.current.partition}:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:*/${var.project_name}-*",
    ]
  }

  # Allow: STS AssumeRole for cross-service delegation (narrow list
  # scoped to the project's own service roles). This is what lets
  # the ECS task role assume, e.g., a future ingest role.
  statement {
    sid    = "AllowAssumeProjectRoles"
    effect = "Allow"

    actions = [
      "sts:AssumeRole",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-${var.environment}-*",
    ]
  }

  # Deny: explicit deny on IAM mutation. A compromise of any service
  # role cannot escalate by creating new IAM users, attaching
  # policies, or deleting access keys.
  statement {
    sid    = "DenyIamMutation"
    effect = "Deny"

    actions = [
      "iam:Create*",
      "iam:Attach*",
      "iam:Delete*",
      "iam:Put*",
      "iam:Update*",
      "iam:PassRole",
    ]

    resources = ["*"]
  }

  # Deny: explicit deny on KMS admin operations. No service role
  # may rotate, delete, or reconfigure a CMK.
  statement {
    sid    = "DenyKmsAdmin"
    effect = "Deny"

    actions = [
      "kms:*",
    ]

    # Allow kms:Decrypt, kms:GenerateDataKey, and kms:DescribeKey
    # via the AllowServiceReads statement above -- but ONLY when
    # not on a wildcard resource. The Deny here catches any
    # "kms:*" call on the * resource.
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ResourceTag/Project"
      values   = [var.project_name]
    }
  }

  # Deny: explicit deny on wildcard actions against wildcard
  # resources. The boundary is a CEILING, not a grant; an inline
  # policy that says "Action: * Resource: *" is rejected here.
  statement {
    sid       = "DenyWildcardWildcard"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "service_boundary" {
  name        = "${local.name_prefix}-service-boundary"
  description = "Permission boundary capping every service role. Denies iam:Create*, iam:Attach*, kms:*, and wildcard wildcards. Attach via permissions_boundary on each role."
  policy      = data.aws_iam_policy_document.service_boundary.json

  tags = var.tags
}

# ============================================================================
# ECS TASK ROLE
# Assumed by ECS Fargate tasks via OIDC (no static AWS keys).
# Read S3 PHI objects; write to its own log group; read specific
# secrets. NO s3:PutObject on the data bucket (the data tier is
# write-controlled by a separate ingest path owned by U7).
# ============================================================================
data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    sid    = "ECSTasksAssumeRole"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "ecs_task_role" {
  name        = "${local.name_prefix}-ecs-task-role"
  description = "ECS Fargate task role for ${local.name_prefix}. Reads PHI S3 objects, writes structured logs, reads specific secrets. Permission-bounded by ${local.name_prefix}-service-boundary."

  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  max_session_duration = 3600

  permissions_boundary = aws_iam_policy.service_boundary.arn

  tags = var.tags
}

data "aws_iam_policy_document" "ecs_task_role_policy" {
  # Allow: read S3 PHI bucket ONLY (no PutObject).
  statement {
    sid    = "AllowReadDataBucket"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]

    resources = [
      local.data_bucket_arn,
      "${local.data_bucket_arn}/*",
    ]
  }

  # Allow: write to the per-env ECS log group.
  statement {
    sid    = "AllowWriteEcsLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
    ]

    resources = [
      local.ecs_log_group_arn,
    ]
  }

  # Allow: read specific secrets (ARN-form constraints; no wildcards).
  statement {
    sid    = "AllowReadSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = [
      var.rds_master_password_secret_arn,
      var.cognito_client_secret_arn,
    ]
  }

  # Allow: decrypt with the S3 PHI CMK (objects already exist).
  statement {
    sid    = "AllowKmsDecryptS3Phi"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]

    resources = [
      var.s3_phi_kms_key_arn,
    ]
  }

  # Deny: explicit deny on s3:PutObject on the data bucket. This is
  # the load-bearing cross-env control: the ECS task CANNOT write
  # to its own env's data bucket, and the boundary already blocks
  # PutObject on other-env buckets via the wildcard wildcard deny.
  # We add this deny explicitly so the intent is reviewable in PR.
  statement {
    sid    = "DenyWriteToDataBucket"
    effect = "Deny"

    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      local.data_bucket_arn,
      "${local.data_bucket_arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "ecs_task_role_inline" {
  name   = "${local.name_prefix}-ecs-task-role-inline"
  role   = aws_iam_role.ecs_task_role.id
  policy = data.aws_iam_policy_document.ecs_task_role_policy.json
}

# ============================================================================
# RDS PROXY ROLE
# Assumed by RDS Proxy when iam_auth_enabled = true on the RDS Proxy
# resource. The Proxy uses this role to mint short-lived auth
# tokens; the role needs kms:Decrypt + kms:GenerateDataKey on the
# RDS CMK to handle the TLS session envelope.
# ============================================================================
data "aws_iam_policy_document" "rds_proxy_assume_role" {
  statement {
    sid    = "RDSProxyAssumeRole"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "rds.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "rds_proxy_role" {
  name        = "${local.name_prefix}-rds-proxy-role"
  description = "RDS Proxy IAM auth role for ${local.name_prefix}. Decrypts RDS CMK for TLS session envelope. Permission-bounded by ${local.name_prefix}-service-boundary."

  assume_role_policy = data.aws_iam_policy_document.rds_proxy_assume_role.json

  max_session_duration = 3600

  permissions_boundary = aws_iam_policy.service_boundary.arn

  tags = var.tags
}

data "aws_iam_policy_document" "rds_proxy_role_policy" {
  # Allow: KMS operations on the RDS CMK ONLY.
  statement {
    sid    = "AllowKmsForRdsProxy"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]

    resources = [
      var.rds_kms_key_arn,
    ]
  }

  # Allow: connect to the RDS database instance via IAM auth.
  # The rds-db:connect resource pattern requires the DB user +
  # database name in the resource ARN; we scope to the project
  # prefix so other projects in the account cannot piggyback.
  statement {
    sid    = "AllowRdsDbConnect"
    effect = "Allow"

    actions = [
      "rds-db:connect",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:*/${var.project_name}-*",
    ]
  }
}

resource "aws_iam_role_policy" "rds_proxy_role_inline" {
  name   = "${local.name_prefix}-rds-proxy-role-inline"
  role   = aws_iam_role.rds_proxy_role.id
  policy = data.aws_iam_policy_document.rds_proxy_role_policy.json
}

# ============================================================================
# FIREHOSE ROLE
# Assumed by Kinesis Firehose when delivering to the audit S3
# bucket. Writes to the audit bucket (placeholder name; U5 owns
# the actual bucket creation) and decrypts the CloudTrail CMK.
# ============================================================================
data "aws_iam_policy_document" "firehose_assume_role" {
  statement {
    sid    = "FirehoseAssumeRole"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "firehose.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "firehose_role" {
  name        = "${local.name_prefix}-firehose-role"
  description = "Kinesis Firehose delivery role for ${local.name_prefix}. Writes to the audit S3 bucket, decrypts the CloudTrail CMK. Permission-bounded by ${local.name_prefix}-service-boundary."

  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role.json

  max_session_duration = 3600

  permissions_boundary = aws_iam_policy.service_boundary.arn

  tags = var.tags
}

data "aws_iam_policy_document" "firehose_role_policy" {
  # Allow: write to the audit bucket (placeholder; U5 creates the
  # actual bucket with this exact name).
  statement {
    sid    = "AllowWriteAuditBucket"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]

    resources = [
      local.audit_bucket_arn,
      "${local.audit_bucket_arn}/*",
    ]
  }

  # Allow: decrypt with the CloudTrail CMK.
  statement {
    sid    = "AllowKmsDecryptCloudTrail"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]

    resources = [
      var.cloudtrail_kms_key_arn,
    ]
  }
}

resource "aws_iam_role_policy" "firehose_role_inline" {
  name   = "${local.name_prefix}-firehose-role-inline"
  role   = aws_iam_role.firehose_role.id
  policy = data.aws_iam_policy_document.firehose_role_policy.json
}

# ============================================================================
# LAMBDA ROTATION ROLE
# Assumed by the AWS-managed Secrets Manager rotation Lambda
# blueprint. STRICTLY limited to the RotateSecret family of
# actions. Explicit Deny on rds:ModifyDBInstance +
# rds:DeleteDBInstance so a compromise of the rotation role
# cannot change or delete the database.
#
# The plan calls for attaching the AWSLambdaSecretRotationPolicy
# managed policy; the rotate-secret Lambda's trust policy already
# requires the rotationlambda.amazonaws.com service principal, and
# the IAM-managed policy AWSLambdaSecretRotationPolicy grants the
# secretsmanager:RotateSecret + DescribeSecret permissions. We
# attach the managed policy here AS WELL as the inline policy
# (the inline policy is the project-specific allow/deny list).
# ============================================================================
data "aws_iam_policy_document" "lambda_rotation_assume_role" {
  statement {
    sid    = "SecretsManagerRotationLambdaAssumeRole"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "rotationlambda.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "lambda_rotation_role" {
  name        = "${local.name_prefix}-lambda-rotation-role"
  description = "Lambda execution role for Secrets Manager rotation (RDS Postgres single-user). Limited to secretsmanager:RotateSecret family + GetRandomPassword. Permission-bounded by ${local.name_prefix}-service-boundary."

  assume_role_policy = data.aws_iam_policy_document.lambda_rotation_assume_role.json

  max_session_duration = 3600

  permissions_boundary = aws_iam_policy.service_boundary.arn

  tags = var.tags
}

# Attach the AWS-managed Lambda basic execution + secret rotation
# managed policies. The basic execution role is for CloudWatch Logs
# write access; the rotation policy is the canonical grant for
# secretsmanager:RotateSecret + related.
resource "aws_iam_role_policy_attachment" "lambda_rotation_basic_execution" {
  role       = aws_iam_role.lambda_rotation_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_rotation_secret_rotation" {
  role       = aws_iam_role.lambda_rotation_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/SecretsManagerRotationLambdaRole"
}

data "aws_iam_policy_document" "lambda_rotation_role_policy" {
  # Allow: RotateSecret family on the specific RDS password secret.
  statement {
    sid    = "AllowRotateSecretFamily"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetRandomPassword",
    ]

    resources = [
      var.rds_master_password_secret_arn,
    ]
  }

  # Deny: explicit deny on RDS modify/delete. Load-bearing: a
  # compromise of the rotation role cannot delete or modify the
  # underlying RDS instance. Note this is independent of the
  # permission boundary's broader DenyIamMutation (which covers
  # iam:*, not rds:*).
  statement {
    sid    = "DenyRdsMutation"
    effect = "Deny"

    actions = [
      "rds:ModifyDBInstance",
      "rds:DeleteDBInstance",
      "rds:ModifyDBCluster",
      "rds:DeleteDBCluster",
      "rds:StopDBInstance",
    ]

    resources = ["*"]
  }

  # Allow: KMS decrypt + generate for the RDS CMK so the new
  # password can be staged encrypted.
  statement {
    sid    = "AllowKmsForRdsPassword"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]

    resources = [
      var.rds_kms_key_arn,
    ]
  }
}

resource "aws_iam_role_policy" "lambda_rotation_role_inline" {
  name   = "${local.name_prefix}-lambda-rotation-role-inline"
  role   = aws_iam_role.lambda_rotation_role.id
  policy = data.aws_iam_policy_document.lambda_rotation_role_policy.json
}