###############################################################################
# modules/observability/config.tf
# AWS Config: recorder + delivery channel + 7 managed rules.
#
# Requirements (R12, C10):
#   - Recorder enabled, recording all resource types in the home
#     region.
#   - Delivery channel writes snapshots + history to the audit
#     S3 bucket under the `config/` prefix.
#   - 7 managed rules cover the must-have controls:
#     1. s3-bucket-public-read-prohibited   (CIS)
#     2. s3-bucket-public-write-prohibited  (CIS)
#     3. s3-bucket-server-side-encryption-enabled (CIS)
#     4. cloud-trail-encryption-enabled     (CIS)
#     5. cloud-trail-log-file-validation-enabled (CIS)
#     6. multi-region-cloudtrail-enabled    (CIS)
#     7. iam-root-access-key-check          (CIS)
#
# The recorder is regional (ca-central-1) -- Config does not have
# a multi-region mode for the recorder itself; cross-region
# coverage is achieved by enabling Config in each region via a
# separate StackSet. The MVP scopes to the home region (where all
# PHI-bearing resources live, per the data-residency requirement
# R1).
#
# Recorder role: hand-rolled. The terraform-aws-modules/config
# wrapper handles the trust policy, the inline policy, the
# recorder, the delivery channel, and the rules; for the MVP we
# use the raw resources because (a) the plan documents hand-
# rolling, (b) it gives us tighter control over the IAM scope,
# and (c) it sidesteps a v5 wrapper pin in this unit.
###############################################################################

# ----------------------------------------------------------------------------
# Config recorder IAM role. Trust policy allows config.amazonaws.com
# in the home account. Inline policy grants the S3 + SNS permissions
# the recorder needs to deliver snapshots and history.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "config_assume_role" {
  statement {
    sid    = "ConfigAssumeRole"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "config.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "config" {
  name        = "${local.name_prefix}-config-recorder"
  description = "AWS Config recorder + delivery channel role for ${local.name_prefix}. Writes Config snapshots + history to the audit S3 bucket."

  assume_role_policy = data.aws_iam_policy_document.config_assume_role.json

  tags = var.tags
}

# The minimum IAM policy AWS Config requires to deliver to an
# encrypted S3 bucket. The aws-managed policy
# AWS_ConfigRole is a starting point but is broader than needed;
# we inline a tighter version here.
data "aws_iam_policy_document" "config" {
  # Allow: write to the audit bucket under the `config/` prefix.
  statement {
    sid    = "AllowWriteConfigToAuditBucket"
    effect = "Allow"

    actions = [
      "s3:PutObject",
    ]

    resources = [
      "${local.audit_bucket_arn}/config/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  # Allow: read the bucket ACL (Config records bucket policies
  # in its history; some checks need to retrieve the ACL).
  statement {
    sid    = "AllowGetBucketAcl"
    effect = "Allow"

    actions = [
      "s3:GetBucketAcl",
    ]

    resources = [local.audit_bucket_arn]
  }

  # Allow: decrypt with the cloudtrail CMK (the audit bucket's
  # CMK) when Config reads the history it wrote.
  statement {
    sid    = "AllowKmsDecryptForConfig"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
    ]

    resources = [var.cloudtrail_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "config_inline" {
  name   = "${local.name_prefix}-config-recorder-inline"
  role   = aws_iam_role.config.id
  policy = data.aws_iam_policy_document.config.json
}

# Attach the AWS-managed AWSConfigRole for the rest of the
# permissions Config needs (it includes PutObject on the bucket
# without our prefix constraint). The plan: "The minimum IAM
# policy AWS Config requires to deliver to an encrypted S3
# bucket. The aws-managed policy AWS_ConfigRole is a starting
# point but is broader than needed; we inline a tighter version
# here." -- so we keep BOTH, the inline policy scopes the
# prefix, the managed policy covers the rest.
resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

# ----------------------------------------------------------------------------
# The recorder itself.
#
# - recording_group.all_supported = true captures changes to every
#   supported resource type, not just the ones the rules below
#   evaluate. (Without this, Config would only record the types
#   the rules need; the broader set is required for the Security
#   Hub "centralized posture" control C9.)
# - include_global_resource_types = true captures global types
#   (IAM, etc.) which would otherwise be silently dropped.
# ----------------------------------------------------------------------------
resource "aws_config_configuration_recorder" "this" {
  name     = "${local.name_prefix}-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }

  depends_on = [aws_iam_role_policy_attachment.config_managed]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true

  depends_on = [aws_config_configuration_recorder.this]
}

# ----------------------------------------------------------------------------
# Delivery channel. Writes snapshots and history to the audit
# bucket under the `config/` prefix. SNS topic for notifications
# is omitted (the MVP does not wire page-on-config-change; the
# U5 EventBridge rules on Security Hub findings cover the paging
# path).
# ----------------------------------------------------------------------------
resource "aws_config_delivery_channel" "this" {
  name           = "${local.name_prefix}-channel"
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_key_prefix  = "config"

  depends_on = [
    aws_config_configuration_recorder.this,
    aws_s3_bucket_policy.audit,
  ]
}

# ----------------------------------------------------------------------------
# 7 managed rules. Each rule is `aws_config_config_rule` with a
# `source { owner = "AWS", source_identifier = "<rule-name>" }`.
# Scope defaults to "all resources" within the home region.
# ----------------------------------------------------------------------------
resource "aws_config_config_rule" "s3_public_read_prohibited" {
  name = "${local.name_prefix}-s3-bucket-public-read-prohibited"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_config_rule" "s3_public_write_prohibited" {
  name = "${local.name_prefix}-s3-bucket-public-write-prohibited"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_config_rule" "s3_sse_enabled" {
  name = "${local.name_prefix}-s3-bucket-server-side-encryption-enabled"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_config_rule" "cloudtrail_encryption_enabled" {
  name = "${local.name_prefix}-cloud-trail-encryption-enabled"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_ENCRYPTION_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_config_rule" "cloudtrail_log_file_validation" {
  name = "${local.name_prefix}-cloud-trail-log-file-validation-enabled"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_config_rule" "multi_region_cloudtrail_enabled" {
  name = "${local.name_prefix}-multi-region-cloudtrail-enabled"

  source {
    owner             = "AWS"
    source_identifier = "MULTI_REGION_CLOUD_TRAIL_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_config_rule" "iam_root_access_key_check" {
  name = "${local.name_prefix}-iam-root-access-key-check"

  source {
    owner             = "AWS"
    source_identifier = "IAM_ROOT_ACCESS_KEY_CHECK"
  }

  depends_on = [aws_config_configuration_recorder.this]
}
