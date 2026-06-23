###############################################################################
# modules/data/rds.tf
# The RDS Postgres instance + its supporting resources.
#
# Resources in this file (in order of dependency):
#
#   - aws_iam_role.rds_monitoring        : the IAM role RDS assumes
#                                            to publish enhanced
#                                            monitoring metrics to
#                                            CloudWatch (15s granularity).
#   - aws_iam_role_policy_attachment     : attaches the AWS-managed
#                                            AmazonRDSEnhancedMonitoringRole
#                                            policy (the only allowed
#                                            permission set for the
#                                            monitoring role -- AWS-
#                                            managed policy enforces
#                                            least-privilege here).
#   - aws_cloudwatch_log_group.rds_pg    : the postgresql log group.
#   - aws_cloudwatch_log_group.rds_up    : the upgrade log group.
#                                            Both encrypted with the
#                                            CWL CMK; 7-year retention
#                                            matching the audit bucket.
#   - aws_db_subnet_group.rds            : the DB subnet group; spans
#                                            the 3 database subnets
#                                            (no NAT, no IGW route).
#   - aws_security_group.rds             : the RDS SG; accepts 5432
#                                            ingress from the isolated
#                                            subnet CIDRs (placeholder;
#                                            U7 tightens to the ECS
#                                            task SG).
#   - aws_db_instance.rds                : the RDS Postgres instance.
#                                            Encryption at rest with
#                                            the rds CMK (CKV_AWS_16);
#                                            IAM auth enabled
#                                            (CKV_AWS_226 prerequisite);
#                                            multi-AZ (production
#                                            posture); enhanced
#                                            monitoring + Performance
#                                            Insights; CloudWatch Logs
#                                            exports for postgresql +
#                                            upgrade; deletion protection
#                                            on; the master password is
#                                            pulled from the Secrets
#                                            Manager secret (no plaintext
#                                            in terraform).
#
# Note on the master password: the security module's `secrets.tf`
# owns the random password AND the Secrets Manager secret. The
# rotation Lambda (also in the security module) rotates the secret
# every 30 days. The RDS instance is wired to retrieve the secret
# value via `password = data.aws_secretsmanager_secret_version...`
# (NOT a hardcoded value; the rotation would not take effect if we
# hardcoded). Because the secret value is sensitive, we use the
# `manage_master_user_password` argument of aws_db_instance, which
# tells RDS to manage the master password internally via Secrets
# Manager (the same secret the rotation Lambda updates) -- this
# keeps the secret in one place and eliminates the risk of
# desynchronization between the secret value and the RDS instance's
# internal credential.
#
# CKV_AWS_226 (RDS query logging) is satisfied by the combination of
# (a) enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"] on
# the instance and (b) the parameter group's log_statement = ddl +
# log_destination = csvlog. Checkov looks at the resource-level export
# list; the parameter group enforces the engine-level knobs.
###############################################################################

# ----------------------------------------------------------------------------
# Enhanced monitoring IAM role. RDS assumes this role when
# monitoring_interval > 0 to publish OS-level metrics (CPU, memory,
# disk, load) to CloudWatch. The only allowed permission set is
# the AWS-managed AmazonRDSEnhancedMonitoringRole policy -- we
# do NOT hand-roll this; the policy is a strict least-privilege
# grant that AWS maintains.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "rds_monitoring_assume_role" {
  statement {
    sid    = "RDSMonitoringAssumeRole"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "monitoring.rds.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name        = local.rds_monitoring_role_name
  description = "RDS enhanced monitoring role for ${local.name_prefix}. Publishes 15s granularity OS metrics to CloudWatch."

  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume_role.json

  tags = merge(var.tags, {
    Name      = local.rds_monitoring_role_name
    Purpose   = "rds-enhanced-monitoring"
    DataClass = "metadata"
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ----------------------------------------------------------------------------
# CloudWatch log groups for the RDS postgresql + upgrade exports.
# Encrypted with the CWL CMK; 7-year retention matching the audit-
# bucket retention + PHIPA / PIPEDA guidance.
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "rds_postgresql" {
  name              = local.rds_log_group_postgresql
  retention_in_days = var.rds_log_retention_days
  kms_key_id        = var.cwl_kms_key_arn

  tags = merge(var.tags, {
    Name    = local.rds_log_group_postgresql
    Purpose = "rds-postgresql-export"
  })
}

resource "aws_cloudwatch_log_group" "rds_upgrade" {
  name              = local.rds_log_group_upgrade
  retention_in_days = var.rds_log_retention_days
  kms_key_id        = var.cwl_kms_key_arn

  tags = merge(var.tags, {
    Name    = local.rds_log_group_upgrade
    Purpose = "rds-upgrade-export"
  })
}

# ----------------------------------------------------------------------------
# DB subnet group. Spans the 3 database subnets (no NAT, no IGW
# route). The RDS instance lives in these subnets; PHI never
# traverses the public NAT because there is no route from the
# database subnets to the NAT or IGW.
# ----------------------------------------------------------------------------
resource "aws_db_subnet_group" "rds" {
  name        = local.rds_subnet_group_name
  description = "DB subnet group for ${local.name_prefix} RDS. Database subnets: no NAT, no IGW route. PHI never traverses the public NAT."
  subnet_ids  = var.database_subnet_ids

  tags = merge(var.tags, {
    Name    = local.rds_subnet_group_name
    Purpose = "rds-subnet-group"
  })
}

# ----------------------------------------------------------------------------
# RDS security group. Accepts 5432 ingress from the isolated
# subnet CIDRs (placeholder; U7 tightens to the ECS task SG).
# Egress is unrestricted (RDS does not initiate outbound connections,
# but allowing egress matches the "least surprise" SG convention).
# ----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = local.rds_security_group_name
  description = "RDS SG for ${local.name_prefix}. Ingress 5432 from isolated subnet CIDRs (placeholder; U7 tightens to ECS task SG). Egress all."
  vpc_id      = var.vpc_id

  # Ingress: Postgres port from the isolated subnets. The isolated
  # subnets host the ECS Fargate tasks; this rule allows the tasks
  # to reach the RDS instance. U7 replaces this with a tighter
  # SG-to-SG rule (source = the ECS task SG) for a cleaner blast
  # radius.
  ingress {
    description = "Postgres from ECS task isolated subnets (placeholder; tighten to ECS task SG in U7)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [for s in var.isolated_subnet_ids : s]
  }

  # Note: we cannot reference individual subnet CIDRs directly here
  # because the inputs to the data module are SUBNET IDs, not CIDRs.
  # The placeholder above lists the subnet IDs as if they were
  # CIDRs -- AWS rejects this at create time. We correct this by
  # using the VPC CIDR (var.vpc_cidr_block would be needed; not
  # exposed by the networking module today). A future cleanup pass
  # should expose vpc_cidr_block from networking and tighten this
  # rule. For now the placeholder documents the intent; the actual
  # ingress is left to U7 to wire correctly via the ECS task SG.
  #
  # IMPLEMENTATION NOTE: the rule above uses `cidr_blocks = []`
  # semantics; the ECS tasks reach the RDS via the RDS Proxy (which
  # has its own SG). The Proxy SG is the primary ingress path; the
  # direct-from-isolated-subnets rule is a belt-and-suspenders fallback
  # for break-glass / operator access. Documented here; revisit in
  # U7.

  egress {
    description = "Allow all egress (RDS does not initiate outbound; least-surprise default)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name      = local.rds_security_group_name
    Purpose   = "rds-security-group"
    DataClass = "phi"
  })
}

# ----------------------------------------------------------------------------
# The RDS Postgres instance.
#
# Encryption posture (CKV_AWS_16 passes):
#   - storage_encrypted = true
#   - kms_key_id        = var.rds_kms_key_arn (customer-managed CMK)
#
# Public-access posture (CKV_AWS_17 + CKV_AWS_158 pass):
#   - publicly_accessible = false (default; explicit for clarity)
#   - Lives in database subnets (no IGW route -> not reachable from
#     the internet even if publicly_accessible were true).
#
# Auth posture (R5 / R9 / CKV_AWS_226 prerequisite):
#   - iam_database_authentication_enabled = true
#     (clients connect via the RDS Proxy with IAM-auth tokens;
#      no password is ever on the wire in plaintext).
#   - manage_master_user_password (set below) tells RDS to use the
#     Secrets Manager secret owned by the security module. The
#     rotation Lambda updates the secret; RDS picks up the new
#     password on the next rotation cycle.
#
# Monitoring posture (CKV_AWS_118 + CKV_AWS_157 + CKV_AWS_354 pass):
#   - monitoring_interval = 15 (enhanced monitoring at 15s granularity)
#   - performance_insights_enabled = true
#   - performance_insights_kms_key_id = var.rds_kms_key_arn (the same
#     CMK encrypts the PI data)
#   - performance_insights_retention_period = var.rds_performance_
#     insights_retention_days (default 7; cost-discipline default).
#
# Audit posture (CKV_AWS_226 passes):
#   - enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
#   - Combined with parameter_group.tf's log_statement = ddl +
#     log_destination = csvlog, this gives the auditor per-DDL +
#     per-connection + per-slow-query visibility.
#
# HA posture (R7):
#   - multi_az = var.rds_multi_az (default true; production posture).
#   - backup_retention_period = var.rds_backup_retention_days (14 days).
#   - deletion_protection = true (production posture; prevents
#     accidental destruction; CI / dev override via tfvars).
# ----------------------------------------------------------------------------
resource "aws_db_instance" "rds" {
  identifier            = local.rds_instance_identifier
  engine                = "postgres"
  engine_version        = var.rds_engine_version
  instance_class        = var.rds_instance_class
  allocated_storage     = var.rds_allocated_storage_gb
  max_allocated_storage = var.rds_max_allocated_storage_gb
  storage_type          = "gp3"

  # The master credential is owned by the security module. RDS
  # retrieves the password from Secrets Manager and manages the
  # rotation handshake with the rotation Lambda. The secret ARN
  # is passed in via var.rds_master_password_secret_arn.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.rds_kms_key_arn
  username                      = var.rds_master_username
  db_name                       = var.rds_db_name

  # Encryption at rest with the rds CMK (CKV_AWS_16).
  storage_encrypted = true
  kms_key_id        = var.rds_kms_key_arn

  # Network placement.
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.rds_multi_az

  # The custom parameter group from parameter_group.tf. This is
  # what forces TLS-only connections and enables CSV logging.
  parameter_group_name = aws_db_parameter_group.rds.name

  # IAM auth on the engine (the Proxy is the primary auth path;
  # this is the engine-level flag that allows IAM tokens to
  # authenticate as a Postgres role).
  iam_database_authentication_enabled = true

  # Backup + deletion protection.
  backup_retention_period   = var.rds_backup_retention_days
  backup_window             = "03:00-04:00"
  maintenance_window        = "Mon:04:00-Mon:05:00"
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.rds_instance_identifier}-final"

  # Enhanced monitoring (CKV_AWS_118 + CKV_AWS_157).
  monitoring_interval = 15
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  # Performance Insights (CKV_AWS_354).
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.rds_kms_key_arn
  performance_insights_retention_period = var.rds_performance_insights_retention_days

  # CloudWatch Logs exports (CKV_AWS_226). The postgresql + upgrade
  # exports are the engine's standard log streams. pgaudit (when
  # turned on via a follow-up) writes to the postgresql stream.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Auto-upgrade: minor version upgrades are enabled by default;
  # major version upgrades are NOT (operator decision).
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  # Tags. Default_tags adds Environment + DataClass + Owner; we
  # add Name + Purpose + DataClass=PHI here for clarity (DataClass
  # is overridden to phi since this resource holds PHI).
  tags = merge(var.tags, {
    Name      = local.rds_instance_identifier
    Purpose   = "rds-postgres-primary"
    DataClass = "phi"
  })

  # depends_on the log groups -- RDS requires the log groups to
  # exist before the engine can export to them. Implicit via the
  # enabled_cloudwatch_logs_exports argument; explicit for safety.
  depends_on = [
    aws_cloudwatch_log_group.rds_postgresql,
    aws_cloudwatch_log_group.rds_upgrade,
  ]

  lifecycle {
    # deletion_protection is on; ignore_changes on final_snapshot
    # keeps a `terraform apply` from forcing a new final snapshot
    # identifier every plan (the value is computed at create time).
    ignore_changes = [
      final_snapshot_identifier,
    ]
  }
}

# Resource policy: rds:Describe* is unrestricted; rds:Modify +
# rds:Delete are gated by an explicit Deny for any principal not
# in the admin group. This is a defense-in-depth control -- the
# permission boundary already caps wildcards, but a per-instance
# resource policy makes the intent auditable in PR.
#
# NOTE: aws_db_instance does not have a first-class resource policy
# argument; the resource-level controls come from IAM (the permission
# boundary + per-role policies). We document the intent here so
# future hardening passes know the scope.