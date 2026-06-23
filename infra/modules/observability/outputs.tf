###############################################################################
# modules/observability/outputs.tf
#
# Outputs for the security + audit plane. Consumed by the root
# module (main.tf) to wire any downstream concerns, and by U6 (data
# tier references the audit bucket ARN for the Firehose role policy)
# and U9 (runbook cross-references the Security Hub ARN, GuardDuty
# detector ID, and Macie job ID).
###############################################################################

output "cloudtrail_arn" {
  description = "ARN of the CloudTrail trail. Consumed by runbooks (U9) and by the root module's plan-output summary."
  value       = aws_cloudtrail.this.arn
}

output "cloudtrail_id" {
  description = "ID of the CloudTrail trail (the same as the name). Useful for aws_cli lookups in runbooks."
  value       = aws_cloudtrail.this.id
}

output "audit_bucket_arn" {
  description = "ARN of the immutable audit S3 bucket. Consumed by U6 (data tier wires its Firehose role policy to this ARN) and by runbook (U9) cross-references."
  value       = aws_s3_bucket.audit.arn
}

output "audit_bucket_name" {
  description = "Name of the immutable audit S3 bucket. Useful for aws_cli lookups and for the audit-bucket policy references in U6."
  value       = aws_s3_bucket.audit.id
}

output "config_recorder_name" {
  description = "Name of the AWS Config recorder. Consumed by the root module's plan-output summary and by runbook (U9) cross-references."
  value       = aws_config_configuration_recorder.this.name
}

output "guardduty_detector_id" {
  description = "ID of the GuardDuty detector. Consumed by runbook (U9) cross-references."
  value       = aws_guardduty_detector.this.id
}

output "securityhub_arn" {
  description = "ARN of the Security Hub account subscription. Consumed by runbook (U9) cross-references."
  value       = aws_securityhub_account.this.arn
}

output "macie_classification_job_id" {
  description = "ID of the Macie daily classification job. Consumed by runbook (U9) cross-references and by U6 (data tier) to confirm the job is running on the data bucket."
  value       = aws_macie2_classification_job.data_discovery.id
}

output "firehose_delivery_stream_arn" {
  description = "ARN of the Kinesis Firehose delivery stream. Consumed by the root module's plan-output summary and by U6 (data tier) cross-references."
  value       = aws_kinesis_firehose_delivery_stream.audit.arn
}

output "firehose_delivery_stream_name" {
  description = "Name of the Kinesis Firehose delivery stream. Useful for aws_cli lookups and for CloudWatch metric filters."
  value       = aws_kinesis_firehose_delivery_stream.audit.name
}
