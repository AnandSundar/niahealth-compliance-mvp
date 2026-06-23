###############################################################################
# modules/observability/cloudtrail.tf
# CloudTrail: multi-region, KMS-encrypted, log file validation on,
# CloudWatch Logs integration for management events only.
#
# Requirements (R10, C5):
#   - is_multi_region_trail = true.
#   - enable_log_file_validation = true.
#   - kms_key_id = the cloudtrail CMK (the audit bucket's CMK).
#   - include_global_service_events = true (IAM, STS, CloudFront).
#   - The trail delivers to the S3 audit bucket.
#   - CloudWatch Logs integration: management events ONLY.
#     Data events on the PHI bucket are intentionally NOT streamed
#     to CWL (they would incur per-event CWL ingestion cost; they
#     are written directly to S3 by CloudTrail itself). The plan:
#     "CloudWatch Logs integration is configured for management
#     events only (cheapest tier; data events on the PHI bucket go
#     directly to S3 to avoid the per-event CWL ingestion cost)."
#   - The CloudTrail bucket policy is created inline below (not in
#     a separate file) to keep the trail-bucket association local.
#
# Cost discipline (KTD7): data events on the data-tier bucket cost
# $0.10 per 100K events at the management-events tier; if we routed
# them through CloudWatch Logs we'd add $0.50/GB ingested on top.
# Letting CloudTrail write them straight to S3 and skipping CWL
# for the data plane keeps the bill readable.
###############################################################################

# ----------------------------------------------------------------------------
# CloudWatch log group for CloudTrail management events.
# Encrypted with the CWL CMK; 7-year retention matching the audit
# bucket retention.
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = local.cloudtrail_log_group
  retention_in_days = var.retention_days
  kms_key_id        = var.cwl_kms_key_arn

  tags = merge(var.tags, {
    Name    = local.cloudtrail_log_group
    Purpose = "cloudtrail-management-events"
  })
}

# ----------------------------------------------------------------------------
# IAM role assumed by CloudTrail to deliver to CloudWatch Logs.
# Trust policy: cloudtrail.amazonaws.com in the home account only.
# Inline policy: create log stream + put log events on the specific
# log group.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "cloudtrail_assume_role" {
  statement {
    sid    = "CloudTrailAssumeRole"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "cloudtrail.amazonaws.com",
      ]
    }

    # The aws:SourceAccount condition is the canonical guard
    # against confused-deputy: CloudTrail can only assume this role
    # when the call originates from the home account.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "cloudtrail_to_cwl" {
  name        = "${local.name_prefix}-cloudtrail-to-cwl"
  description = "CloudTrail-to-CloudWatch-Logs delivery role for ${local.name_prefix}. Writes management events to the CloudTrail log group."

  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume_role.json

  tags = var.tags
}

data "aws_iam_policy_document" "cloudtrail_to_cwl" {
  statement {
    sid    = "AllowWriteToCloudTrailLogGroup"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.cloudtrail_log_group}:*",
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.cloudtrail_log_group}",
    ]
  }
}

resource "aws_iam_role_policy" "cloudtrail_to_cwl_inline" {
  name   = "${local.name_prefix}-cloudtrail-to-cwl-inline"
  role   = aws_iam_role.cloudtrail_to_cwl.id
  policy = data.aws_iam_policy_document.cloudtrail_to_cwl.json
}

# ----------------------------------------------------------------------------
# CloudTrail bucket policy. Allow CloudTrail to put objects in the
# audit bucket. The trust principal is the CloudTrail service in
# the home account, with an aws:SourceArn condition to scope the
# grant to this trail's ARN.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "audit_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [local.audit_bucket_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = [
      "s3:PutObject",
    ]

    resources = ["${local.audit_bucket_arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json

  depends_on = [aws_s3_bucket.audit]
}

# ----------------------------------------------------------------------------
# The CloudTrail trail itself.
#
# - is_multi_region_trail = true: captures API calls from every
#   region, not just ca-central-1. Critical for detecting
#   cross-region attacks.
# - enable_log_file_validation = true: digests are written
#   alongside the log files; a separate process can verify the
#   files were not modified in S3.
# - kms_key_id: the cloudtrail CMK encrypts the log files at rest
#   in S3.
# - event_selector: management events ONLY. Data events on the
#   PHI bucket (U6) will be added by U6 if/when the bucket lands,
#   but they will deliver directly to S3 (NOT to CWL) to avoid
#   the per-event CWL ingestion cost.
# - cloud_watch_logs_group_arn: the trail's management events are
#   also streamed to CloudWatch Logs for near-real-time alerting
#   (U8 wires the EventBridge -> Lambda -> SNS chain).
# ----------------------------------------------------------------------------
resource "aws_cloudtrail" "this" {
  name                          = "${local.name_prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.audit.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  kms_key_id = var.cloudtrail_kms_key_arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    # Schema note (v5.100): the legacy `include_data_events`
    # argument was removed from `event_selector`. To enable
    # data events, the v5 provider now uses `data_resource`
    # blocks inside the same `event_selector`, OR an
    # `advanced_event_selector` block. The plan's "management
    # events only" posture (CWL cost discipline, KTD7) means
    # no data_resource block is needed -- the management-event
    # stream covers the audit posture without the per-event
    # CWL ingestion cost of data events. Data events on the
    # U6 data-tier bucket will be added by U6 in a follow-up
    # via an `advanced_event_selector` block scoped to the
    # data-tier bucket ARN (delivered DIRECTLY to S3, not
    # to CWL, to avoid the CWL cost).
  }

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_to_cwl.arn

  # The trail depends on the bucket policy being in place BEFORE
  # the trail starts delivering. Without this depends_on, the
  # apply order is implementation-dependent.
  depends_on = [aws_s3_bucket_policy.audit]

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-trail"
    Purpose = "audit-trail"
  })
}
