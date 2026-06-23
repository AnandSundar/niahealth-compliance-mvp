###############################################################################
# modules/data/outputs.tf
#
# Outputs for the data plane. Consumed by the root module
# (main.tf) for the plan-output summary, by U7's sample app
# (the ECS task definition uses data_bucket_name, ingest_role_arn,
# rds_proxy_endpoint), and by U9's runbooks (RDS endpoint, SG IDs,
# bucket ARNs).
#
# The data_bucket_name output is the SAME as the s3_phi_bucket_name
# output (the ingest target == the PHI bucket; documented in the
# plan as the "U6 invariant: the data-tier bucket name is the
# same as the ingest target"). U7 uses data_bucket_name to wire
# the ECS task definition's ingest path.
###############################################################################

# ----------------------------------------------------------------------------
# RDS outputs.
# ----------------------------------------------------------------------------
output "rds_endpoint" {
  description = "Endpoint (host:port) of the RDS Postgres instance. Consumed by U7's sample app (via Secrets Manager; never in plaintext in the task definition)."
  value       = aws_db_instance.rds.endpoint
}

output "rds_address" {
  description = "Host portion of the RDS endpoint. Useful for cross-module references (e.g. an SG rule that allows the RDS SG to be reached from a specific source)."
  value       = aws_db_instance.rds.address
}

output "rds_port" {
  description = "Port of the RDS Postgres instance (5432)."
  value       = aws_db_instance.rds.port
}

output "rds_engine_version" {
  description = "Postgres engine version of the RDS instance (the actual running version, including any minor version auto-upgrades since launch)."
  value       = aws_db_instance.rds.engine_version_actual
}

output "rds_db_name" {
  description = "Name of the initial database created on the RDS instance."
  value       = aws_db_instance.rds.db_name
}

output "rds_instance_arn" {
  description = "ARN of the RDS Postgres instance. Useful for resource policies and IAM scoping."
  value       = aws_db_instance.rds.arn
}

output "rds_security_group_id" {
  description = "ID of the RDS security group. Consumed by U7 (to tighten ingress from the ECS task SG) and by runbook cross-references."
  value       = aws_security_group.rds.id
}

output "rds_subnet_group_name" {
  description = "Name of the DB subnet group."
  value       = aws_db_subnet_group.rds.name
}

output "rds_parameter_group_name" {
  description = "Name of the custom parameter group. Referenceable from runbooks to verify rds.force_ssl is still set."
  value       = aws_db_parameter_group.rds.name
}

# ----------------------------------------------------------------------------
# RDS Proxy outputs.
# ----------------------------------------------------------------------------
output "rds_proxy_endpoint" {
  description = "Endpoint (host:port) of the RDS Proxy. The PRIMARY connection target for U7's sample app; clients connect here, not directly to the RDS instance."
  value       = aws_db_proxy.rds.endpoint
}

output "rds_proxy_arn" {
  description = "ARN of the RDS Proxy. Useful for resource policies and IAM scoping."
  value       = aws_db_proxy.rds.arn
}

output "rds_proxy_id" {
  description = "ID of the RDS Proxy. Useful for aws_cli lookups in runbooks."
  value       = aws_db_proxy.rds.id
}

# ----------------------------------------------------------------------------
# S3 PHI bucket outputs.
# ----------------------------------------------------------------------------
output "s3_phi_bucket_name" {
  description = "Name of the data-tier PHI bucket. Equal to data_bucket_name (the same bucket is the ingest target)."
  value       = aws_s3_bucket.phi.id
}

output "s3_phi_bucket_arn" {
  description = "ARN of the data-tier PHI bucket. Consumed by U7's data_ingest_role policy and by runbook cross-references."
  value       = aws_s3_bucket.phi.arn
}

output "s3_phi_bucket_domain_name" {
  description = "Bucket domain name (regional endpoint). Useful for S3 client configuration."
  value       = aws_s3_bucket.phi.bucket_domain_name
}

# The data_bucket_name output is the SAME as s3_phi_bucket_name;
# U7 uses this for the ECS task definition's ingest path.
output "data_bucket_name" {
  description = "Name of the data-tier bucket (same as s3_phi_bucket_name). The ingest target for U7's sample app; the ECS task definition's ingest path writes here via the data_ingest_role."
  value       = aws_s3_bucket.phi.id
}

# ----------------------------------------------------------------------------
# S3 PHI replica outputs.
# ----------------------------------------------------------------------------
output "s3_phi_replica_bucket_name" {
  description = "Name of the cross-region replica bucket in ca-west-1. Useful for aws_cli lookups and DR runbooks."
  value       = aws_s3_bucket.phi_replica.id
}

output "s3_phi_replica_bucket_arn" {
  description = "ARN of the cross-region replica bucket in ca-west-1. Referenceable from DR runbooks."
  value       = aws_s3_bucket.phi_replica.arn
}

# ----------------------------------------------------------------------------
# IAM role outputs.
# ----------------------------------------------------------------------------
output "ingest_role_arn" {
  description = "ARN of the data ingest IAM role. Consumed by U7's sample app (the future ingest pipeline assumes this role). Also referenceable for cross-service policy attachments."
  value       = aws_iam_role.data_ingest.arn
}

output "ingest_role_name" {
  description = "Name of the data ingest IAM role. Useful for IAM policy attachment references and runbook scoping."
  value       = aws_iam_role.data_ingest.name
}

output "crr_role_arn" {
  description = "ARN of the S3 cross-region replication role. Referenceable from the source bucket's replication configuration (which is what references it; this output is for runbook cross-references)."
  value       = aws_iam_role.s3_crr.arn
}

output "rds_monitoring_role_arn" {
  description = "ARN of the RDS enhanced monitoring IAM role. Referenceable from runbooks; consumed by the RDS instance's monitoring_role_arn argument."
  value       = aws_iam_role.rds_monitoring.arn
}