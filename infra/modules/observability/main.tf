###############################################################################
# modules/observability/main.tf
#
# The "observability" module owns the security + audit plane (U5 of
# the NiaHealth compliance reference architecture):
#
#   - cloudtrail.tf        : multi-region CloudTrail, KMS-encrypted,
#                            CloudWatch Logs integration (management
#                            events only)
#   - s3_archive.tf        : the immutable audit S3 bucket
#                            (Object Lock Compliance, 7-year retention,
#                            lifecycle -> Glacier IR @ 90d)
#   - config.tf            : AWS Config recorder + delivery channel +
#                            7 managed rules
#   - guardduty.tf         : GuardDuty with S3 + Malware Protection
#   - securityhub.tf       : Security Hub account + CIS + FSBP standards
#                            + EventBridge -> SNS paging rules
#   - macie.tf             : Macie + daily discovery job on the data
#                            tier bucket
#   - kinesis_firehose.tf  : the central Firehose-to-S3 pipeline that
#                            fans VPC Flow Logs / ALB / WAF / RDS logs
#                            into the same audit bucket
#
# Naming convention: ${local.name_prefix}-<purpose> where
# name_prefix = "${var.project_name}-${var.environment}".
#
# All resources flow through the AWS provider's default_tags block
# (infra/providers.tf) so the 3 required tags (Environment, DataClass,
# Owner) are applied automatically. Extra tags are merged via
# `var.tags` to keep the policy-as-code suite (conftest.rego) happy.
#
# Cross-module seams (the "what depends on what" map):
#
#   module.security.cloudtrail_kms_key_arn -> aws_cloudtrail.this.kms_key_id
#   module.security.cwl_kms_key_arn        -> aws_cloudwatch_log_group
#                                              (CloudTrail, Firehose
#                                              errors, future ALB/WAF
#                                              log groups)
#   module.security.s3_phi_kms_key_arn     -> aws_s3_bucket.audit
#                                              (kept for completeness;
#                                              the audit bucket uses
#                                              the cloudtrail CMK by
#                                              design so PHI cannot
#                                              pivot through the audit
#                                              CMK)
#   module.networking.vpc_flow_log_destination_arn
#                                          -> aws_logs_subscription_filter.vpc
#   module.identity.firehose_role_arn     -> aws_kinesis_firehose_delivery_stream
#   module.identity.paging_sns_topic_arn   -> aws_cloudwatch_event_target
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Canonical resource names referenced by IAM policies, log group
  # ARNs, etc. Following the convention set by the identity module
  # so a single grep across modules reveals the full name.
  audit_bucket_name       = "${var.project_name}-audit-${var.environment}"
  data_bucket_name        = "${var.project_name}-data-${var.environment}"
  firehose_log_group      = "/niahealth/${var.environment}/firehose-errors"
  cloudtrail_log_group    = "/niahealth/${var.environment}/cloudtrail"
  vpc_flow_log_group_name = "/niahealth/${var.environment}/vpc-flow-logs"

  # Audit bucket ARN (used inline in the CloudTrail bucket policy
  # and in the Firehose extended-S3 configuration).
  audit_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${local.audit_bucket_name}"
}
