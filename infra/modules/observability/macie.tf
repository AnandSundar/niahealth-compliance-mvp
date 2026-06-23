###############################################################################
# modules/observability/macie.tf
# Amazon Macie.
#
# Requirements (R15, C7):
#   - Macie enabled for the account.
#   - Daily discovery job on the data-tier S3 bucket
#     (${var.project_name}-data-${var.environment}, owned by U6).
#   - The job runs daily; a test file with a fake SIN
#     (e.g., 123-456-789) produces a Macie finding within 24h.
#   - Findings flow to Security Hub (Macie publishes findings
#     as Security Hub findings by default once both services
#     are enabled in the same account).
#
# MTTD target: 24h from object write to Macie finding (the 72h
# PIPC breach-report clock starts T0+24h after Macie confirms
# discovery, NOT at first put -- the runbook documents the
# T0/T24/T72 timeline).
#
# Important: the data-tier S3 bucket is owned by U6. The Macie
# job references it by name; if the bucket does not exist when
# the job is created, the apply will fail. The recommended
# dependency order is: U5 creates the Macie job with the
# planned bucket name; U6 creates the bucket with the same
# name. Terraform itself does not enforce this across modules
# (the Macie job only validates the name format), so the
# apply-time error would only fire if Macie pre-validates the
# bucket. Documented in the report.
#
# Schema note (v5.100):
#   - aws_macie2_account does NOT support a `tags` argument.
#     The 3 required tags are inherited via the provider's
#     default_tags block.
#   - aws_macie2_classification_job's `s3_job_definition
#     .bucket_definitions` now takes (account_id, buckets[]) --
#     the legacy single-`name` form was removed.
#   - schedule_frequency.daily (bool) is unchanged in v5.100.
###############################################################################

# ----------------------------------------------------------------------------
# Enable Macie for the account.
#
# finding_publishing_frequency = "FIFTEEN_MINUTES" matches the
# plan's MTTD target (a finding reaches Security Hub within
# 15min of classification, then is paged by the EventBridge
# rule on Critical/High; non-critical Macie findings are
# still visible in the Security Hub console).
#
# status = "ENABLED" turns the service on. The MVP does not
# use a Macie service-linked role explicitly; Macie auto-
# creates one when status flips to ENABLED.
# ----------------------------------------------------------------------------
# Schema note: aws_macie2_account does not accept a `tags`
# argument in v5.100. The 3 required tags are inherited via
# the provider's default_tags block.
resource "aws_macie2_account" "this" {
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  status                       = "ENABLED"
}

# ----------------------------------------------------------------------------
# Daily discovery job on the data-tier bucket.
#
# - name: deterministic per env so a re-apply does not create
#   a duplicate job.
# - schedule_frequency.daily: the job runs every 24h, starting
#   at Macie's chosen time (the API does not let you pin the
#   hour; Macie distributes job starts across the day to avoid
#   thundering-herd).
# - s3_job_definition.bucket_definitions: the data-tier
#   bucket. v5.100 schema is { account_id, buckets[] } -- the
#   account_id is the AWS account that OWNS the bucket (the
#   same as the home account for the MVP; the provider would
#   substitute the data source's caller identity if the var
#   is left null). The buckets list contains the bucket names
#   the job should scan.
# - initial_run = true: the job runs once on creation, then
#   continues on the daily schedule.
# ----------------------------------------------------------------------------
resource "aws_macie2_classification_job" "data_discovery" {
  name        = "${local.name_prefix}-macie-data-discovery"
  description = "Daily Macie discovery job for the data-tier bucket (${local.data_bucket_name}). MTTD target: 24h from object write to finding."
  initial_run = true
  job_type    = "SCHEDULED"

  # v5.100 schema: bucket_definitions is a list of
  # { account_id, buckets[] }. The home account is the bucket
  # owner for the U6 data-tier bucket; the data source returns
  # the caller's account ID at apply time.
  s3_job_definition {
    bucket_definitions {
      account_id = data.aws_caller_identity.current.account_id
      buckets    = [local.data_bucket_name]
    }
  }

  schedule_frequency {
    daily_schedule = true
  }

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-macie-data-discovery"
    Purpose = "pii-discovery"
  })

  depends_on = [aws_macie2_account.this]
}
