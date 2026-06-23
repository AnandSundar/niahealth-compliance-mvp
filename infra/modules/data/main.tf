###############################################################################
# modules/data/main.tf
#
# The "data" module owns the data plane (U6 of the NiaHealth
# compliance reference architecture):
#
#   - parameter_group.tf : the custom DB parameter group that
#                          forces TLS-only connections (rds.force_ssl = 1),
#                          enables CSV logging, and emits slow-query +
#                          lock-wait + temp-file + autovacuum logs.
#                          Single most security-relevant Terraform object
#                          (the plan: "forces logging + TLS, the most-
#                          touched-in-PR object"); isolated in its own
#                          file so PR diffs land on a small surface.
#
#   - rds.tf             : the DB subnet group, RDS security group,
#                          RDS Postgres instance, and the RDS enhanced
#                          monitoring IAM role. Encryption at rest
#                          with the rds CMK; IAM auth on; multi-AZ;
#                          enhanced monitoring + Performance Insights;
#                          CloudWatch Logs exports for postgresql +
#                          upgrade; deletion protection on.
#
#   - rds_proxy.tf       : the RDS Proxy in front of the database.
#                          IAM auth required; TLS enforced on client
#                          side; secrets sourced from Secrets Manager;
#                          IAM role is the rds_proxy_role from the
#                          identity module. The Proxy holds the
#                          master password + rotates the IAM-auth
#                          tokens; clients never see the password.
#
#   - s3_phi.tf          : the data-tier PHI S3 bucket
#                          (niahealth-data-${var.environment}).
#                          Versioned, default-encrypted with the
#                          s3_phi CMK, all 4 public-access blocks on,
#                          lifecycle transitions to Glacier IR @ 90d
#                          + Glacier Deep Archive @ 365d, replication
#                          to ca-west-1 wired in lifecycle.tf.
#                          NO Object Lock (PHIPA right-to-erasure
#                          conflicts with WORM retention).
#
#   - lifecycle.tf       : the cross-region replication of the PHI
#                          bucket to ca-west-1 (the DR bucket) + the
#                          CRR IAM role. Also creates the data_ingest
#                          IAM role (the ingest path that CAN
#                          PutObject on the PHI bucket; the ECS task
#                          role CANNOT by design -- see the U4
#                          recommendation in the subagent report).
#
# Naming convention: ${local.name_prefix}-<purpose> where
# name_prefix = "${var.project_name}-${var.environment}".
#
# All resources flow through the AWS provider's default_tags block
# (infra/providers.tf) so the 3 required tags (Environment, DataClass,
# Owner) are applied automatically. Extra tags are merged via
# `var.tags` to keep the policy-as-code suite (conftest.rego) happy.
#
# Data residency (R1): the home region is ca-central-1 (PHI primary);
# the DR region is ca-west-1 (both are Canadian regions; PIPEDA Schedule 1
# + PHIPA s.13 are satisfied because no PHI leaves Canada). The
# cross-region replication in lifecycle.tf replicates PHI to the
# Canadian DR region only -- NOT to a non-Canadian region. If a future
# requirement mandates a non-Canadian DR, the data-residency policy
# MUST be revisited (this is a hard control; see CONTROLS.md U9).
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Canonical resource names referenced by IAM policies, SG rules, etc.
  # Following the convention set by the other modules so a single
  # grep across modules reveals the full name.
  rds_subnet_group_name         = "${local.name_prefix}-rds-subnets"
  rds_parameter_group_name      = "${local.name_prefix}-rds-params"
  rds_instance_identifier       = "${local.name_prefix}-rds"
  rds_security_group_name       = "${local.name_prefix}-rds-sg"
  rds_proxy_security_group_name = "${local.name_prefix}-rds-proxy-sg"
  rds_proxy_name                = "${local.name_prefix}-rds-proxy"
  rds_monitoring_role_name      = "${local.name_prefix}-rds-monitoring-role"
  phi_bucket_name               = "${var.project_name}-data-${var.environment}"
  phi_bucket_replica_name       = "${var.project_name}-data-${var.environment}-replica"
  data_ingest_role_name         = "${local.name_prefix}-data-ingest-role"
  crr_role_name                 = "${local.name_prefix}-s3-crr-role"
  rds_log_group_postgresql      = "/niahealth/${var.environment}/rds/postgresql"
  rds_log_group_upgrade         = "/niahealth/${var.environment}/rds/upgrade"
  rds_proxy_log_group           = "/niahealth/${var.environment}/rds-proxy"

  # Standard ARNs.
  phi_bucket_arn    = "arn:${data.aws_partition.current.partition}:s3:::${local.phi_bucket_name}"
  phi_bucket_prefix = "${local.phi_bucket_name}/*"

  # Replica ARNs (used in the replication configuration).
  # NOTE: ca-west-1 uses the same partition (aws); the bucket ARN
  # has the same form, just a different region segment.
  phi_bucket_replica_arn = "arn:${data.aws_partition.current.partition}:s3:::${local.phi_bucket_replica_name}"

  # KMS key ARNs derived from CMK ARNs (the same CMK encrypts both
  # the source and the replica; this is the explicit design choice
  # to avoid a multi-region CMK -- the trade-off is that the replica
  # bucket's objects are encrypted in ca-central-1 and decrypted /
  # re-encrypted for the replica in ca-west-1 using the same key
  # ARN. Multi-region CMKs are out of scope for the MVP.)
  s3_phi_kms_key_arn = var.s3_phi_kms_key_arn

  # Ingest target = the PHI bucket (the same name). Exposed via the
  # data_bucket_name output; U7 uses this output to wire the ECS
  # task definition's ingest path.
  data_bucket_name = local.phi_bucket_name
}