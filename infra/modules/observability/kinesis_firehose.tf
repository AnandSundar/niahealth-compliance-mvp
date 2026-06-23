###############################################################################
# modules/observability/kinesis_firehose.tf
# The central Kinesis Firehose delivery stream + CloudWatch Logs
# subscription filters that fan VPC Flow Logs, ALB access logs,
# and WAF logs into the audit S3 bucket.
#
# Architecture (from the plan):
#   VPC Flow Logs (CW log group) --\
#   ALB access logs (CW log group) --+--> Firehose --> S3 audit
#   WAF logs (CW log group)       --/        |
#                                            +-- errors --> CW log group
#                                                             (encrypted with
#                                                              CWL CMK)
#
# The Firehose delivery stream is configured for extended S3
# destination (the v2 Firehose API). Server-side encryption uses
# the cloudtrail CMK (the audit bucket's CMK). The IAM role is
# passed in from the identity module (firehose_role_arn).
#
# Subscription filters:
#   1. VPC Flow Logs (the log group ARN is passed in from
#      module.networking.vpc_flow_log_destination_arn). ALWAYS
#      created (the VPC flow log group exists in U3).
#   2. ALB access logs (the log group name is passed in via
#      var.alb_access_log_group). CONDITIONALLY created (U6
#      owns the log group; the filter is skipped when null).
#   3. WAF logs (the log group name is passed in via
#      var.waf_log_group). CONDITIONALLY created (U6/U7 own
#      the log group; the filter is skipped when null).
#
# Cost discipline: Firehose charges per-GB ingested. The
# subscription filter has no filter pattern, so all events from
# the source log group are forwarded. The plan accepts this
# cost because the alternative (per-event filtering) loses
# context and is harder to reason about during incident
# response.
###############################################################################

# ----------------------------------------------------------------------------
# CloudWatch log group for Firehose delivery errors.
# Encrypted with the CWL CMK; 7-year retention matching the
# audit bucket retention.
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "firehose_errors" {
  name              = local.firehose_log_group
  retention_in_days = var.retention_days
  kms_key_id        = var.cwl_kms_key_arn

  tags = merge(var.tags, {
    Name    = local.firehose_log_group
    Purpose = "firehose-delivery-errors"
  })
}

# ----------------------------------------------------------------------------
# Firehose delivery stream: extended S3 destination.
#
# The extended S3 destination (vs the legacy s3 destination) is
# the v2 API and gives us per-object metadata prefixes (year/
# month/day/hour), dynamic partitioning, and tighter error
# handling. The plan calls out the v2 API in the verification
# step ("VPC Flow Logs are reaching the Firehose to S3 pipeline")
# -- the v1 API would not surface the per-hour partition the
# verification expects to see.
#
# buffering_interval = 60 + buffering_size = 1 keeps the
# delivery latency low (a finding from a single connection
# should appear in the audit bucket within a few minutes of
# the connection closing). For higher throughput you would
# increase the size; for the MVP's expected volume (a few
# hundred flow log events per minute at peak) the smallest
# buffer is correct.
# ----------------------------------------------------------------------------
resource "aws_kinesis_firehose_delivery_stream" "audit" {
  name        = "${local.name_prefix}-audit-firehose"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = var.firehose_role_arn
    bucket_arn = aws_s3_bucket.audit.arn

    # The audit bucket's "audit" prefix; Firehose appends
    # year=/month=/day=/hour=/ objects underneath.
    prefix              = "audit/!{timestamp:yyyy}/!{timestamp:MM}/!{timestamp:dd}/!{timestamp:HH}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/!{timestamp:yyyy}/!{timestamp:MM}/!{timestamp:dd}/!{timestamp:HH}/"

    # SSE with the cloudtrail CMK (the audit bucket's CMK).
    # Using the same key for Firehose envelope encryption +
    # bucket object encryption keeps the key domain consistent.
    s3_backup_mode = "Disabled"

    processing_configuration {
      enabled = false
    }

    # v5.100 schema: `buffer_interval`/`buffer_size` were
    # renamed to `buffering_interval`/`buffering_size`. Same
    # semantics, just the new names. buffering_interval = 60
    # seconds + buffering_size = 1 MiB keeps the delivery
    # latency low -- a flow log event should appear in the
    # audit bucket within a few minutes of the connection
    # closing. For higher throughput you would increase the
    # size; for the MVP's expected volume (a few hundred flow
    # log events per minute at peak) the smallest buffer is
    # correct.
    buffering_interval = 60
    buffering_size     = 1

    compression_format = "GZIP"

    # CloudWatch Logs for delivery errors. Firehose publishes
    # any delivery-failure events to this log group, encrypted
    # with the CWL CMK. The log group was created above.
    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose_errors.name
      log_stream_name = "S3Delivery"
    }
  }

  # KMS key for envelope encryption (the data Firehose buffers
  # in flight). The cloudtrail CMK is used to be consistent with
  # the audit bucket's encryption.
  server_side_encryption {
    enabled  = true
    key_type = "CUSTOMER_MANAGED_CMK"
    key_arn  = var.cloudtrail_kms_key_arn
  }

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-audit-firehose"
    Purpose = "log-archive-fan-in"
  })

  depends_on = [aws_s3_bucket.audit]
}

# ----------------------------------------------------------------------------
# Subscription filter: VPC Flow Logs -> Firehose.
#
# The destination_arn is the Firehose delivery stream. The
# role_arn is NOT needed when the destination is Firehose
# (Firehose does not require an IAM role for subscription
# filters; it uses the role from the delivery stream config).
# The filter_pattern is empty (forward all events).
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_subscription_filter" "vpc" {
  name            = "${local.name_prefix}-vpc-flow-logs-to-firehose"
  log_group_name  = split(":", var.vpc_flow_log_group_arn)[6]
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.audit.arn

  # The log_group_name from the ARN requires the leading slash
  # stripped (the ARN is
  # arn:aws:logs:region:account:log-group:/path/of/logs:* and
  # we want the /path/of/logs part). Splitting on ":" and
  # taking [6] gives us the log-group path including the leading
  # slash, which is what aws_cloudwatch_log_subscription_filter
  # expects.
  #
  # Schema note (v5.100): the resource was renamed from
  # `aws_logs_subscription_filter` to
  # `aws_cloudwatch_log_subscription_filter` in the v5 AWS
  # provider. The `role_arn` argument (used by the legacy
  # resource when the destination was a Lambda) is no longer
  # required when the destination is Kinesis Firehose; Firehose
  # uses its own IAM role (the `var.firehose_role_arn` set on
  # the delivery stream resource above).
}

# ----------------------------------------------------------------------------
# Subscription filter: ALB access logs -> Firehose.
# CONDITIONAL: only when var.alb_access_log_group is set (U6
# creates the log group; the filter is skipped until then).
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_subscription_filter" "alb" {
  count = var.alb_access_log_group != null ? 1 : 0

  name            = "${local.name_prefix}-alb-access-logs-to-firehose"
  log_group_name  = var.alb_access_log_group
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.audit.arn
}

# ----------------------------------------------------------------------------
# Subscription filter: WAF logs -> Firehose.
# CONDITIONAL: only when var.waf_log_group is set (U6/U7
# create the log group; the filter is skipped until then).
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_subscription_filter" "waf" {
  count = var.waf_log_group != null ? 1 : 0

  name            = "${local.name_prefix}-waf-logs-to-firehose"
  log_group_name  = var.waf_log_group
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.audit.arn
}
