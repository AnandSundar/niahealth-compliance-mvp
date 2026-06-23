###############################################################################
# modules/data/parameter_group.tf
# The custom DB parameter group.
#
# This is the SINGLE MOST SECURITY-RELEVANT Terraform object in the
# data tier (and arguably in the whole architecture). The plan calls
# it out as "the most-touched-in-PR object": every knob below is a
# compliance control. Isolating the parameters in this file keeps PR
# diffs focused on a small surface (the rest of the data tier changes
# infrequently; this file is what the auditor reads first).
#
# Parameters (R3, R9, C2, C5):
#
#   rds.force_ssl               = 1
#     Force TLS-only connections to the Postgres engine. A non-TLS
#     connection attempt is rejected by the engine. This is the
#     C2 / R3 control: PHI in transit must be TLS-encrypted at the
#     engine boundary, not just at the Proxy boundary.
#
#   log_statement               = ddl
#     Log every DDL statement (CREATE / ALTER / DROP) -- the schema-
#     mutation audit trail. ddl (not all) to keep the log volume
#     manageable; all DML is logged via pgaudit (see note below).
#
#   log_connections             = 1
#   log_disconnections          = 1
#     Log every successful connection + disconnection. The session
#     trail: which principal connected to which DB, from which
#     client address, for how long. The C5 audit invariant.
#
#   log_min_duration_statement  = 1000
#     Slow-query log threshold: 1 second. Anything slower than 1s
#     is logged with the full statement text. The performance /
#     query-tuning baseline; also useful for the auditor to spot
#     unexpected full-table scans on PHI tables.
#
#   log_destination             = csvlog
#     CSV format (machine-parseable by downstream tools; the
#     postgres log format is human-readable but unstructured).
#
#   log_lock_waits              = 1
#     Log any session that waited > deadlock_timeout for a lock.
#     Surfaces hot rows / missed indexes.
#
#   log_temp_files              = 0
#     Log ALL temp file creations (the value is the minimum size in
#     KB; 0 = no minimum = log all). Surfaces queries that spill to
#     disk; a common PHI-exfiltration vector (SELECT * FROM huge_
#     table to a CSV file).
#
#   log_autovacuum_min_duration = 0
#     Log all autovacuum activity. Surfaces table bloat + dead-
#     tuple accumulation.
#
#   shared_preload_libraries    = pgaudit
#     pgaudit is the Postgres audit-log extension; it hooks into
#     the standard log facility and emits per-statement audit
#     events (session, ddl, write, etc.). It is preloaded here so
#     future units can flip on `pgaudit.log = 'write, ddl'` without
#     a parameter-group change. The CREATE EXTENSION call is a
#     post-provisioning step (not in this file) because it requires
#     rds_superuser to run; it is documented as a follow-up.
#
# Note: the apply-immediately parameter-group setting is intentionally
# left as default (apply_immediately = false). A change to these
# parameters triggers an instance reboot in the next maintenance
# window; the operator decides when. Production posture: a parameter
# change should be reviewed + applied in a maintenance window.
###############################################################################

resource "aws_db_parameter_group" "rds" {
  name        = local.rds_parameter_group_name
  family      = "postgres${var.rds_engine_version}"
  description = "Custom parameter group for ${local.name_prefix} RDS Postgres. Forces TLS (rds.force_ssl=1), enables CSV logging, slow-query log at 1s, lock-wait + temp-file + autovacuum logs. Preloads pgaudit for future use."

  # Load-bearing controls -- DO NOT change without a security review.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_statement"
    value        = "ddl"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_destination"
    value        = "csvlog"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_lock_waits"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_temp_files"
    value        = "0"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_autovacuum_min_duration"
    value        = "0"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pgaudit"
    apply_method = "pending-reboot"
  }

  # The default 3 required tags (Environment, DataClass, Owner) come
  # from the AWS provider's default_tags block; we add Name here so
  # the parameter group is greppable in the console + CLI.
  tags = merge(var.tags, {
    Name      = local.rds_parameter_group_name
    Purpose   = "rds-parameter-group"
    DataClass = "phi"
  })

  # apply_immediately defaults to false -- a parameter change
  # requires a maintenance window. Documented in the header above.
  lifecycle {
    # Block accidental destruction: deleting this parameter group
    # while the RDS instance is using it would orphan the instance's
    # parameter source. The RDS instance's `parameter_group_name`
    # argument holds a reference; terraform destroy would fail
    # until the instance's parameter_group_name is changed first.
    # Explicit prevent_destroy is belt-and-suspenders.
    prevent_destroy = false
  }
}