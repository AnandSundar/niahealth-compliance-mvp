###############################################################################
# modules/identity/main.tf
#
# The "identity" module owns the human + service identity plane
# (U4 of the NiaHealth compliance reference architecture).
#
# Concerns split into separate files for reviewability:
#   - idc.tf           : IAM Identity Center permission sets + groups
#   - roles.tf         : 4 service roles with permission boundaries
#   - break_glass.tf   : single break-glass IAM user with MFA + paging
#   - access_analyzer.tf : IAM Access Analyzer (account-wide)
#
# This file is the glue: locals, name_prefix, and the permission
# boundary policy that caps each service role's effective permissions.
#
# IAM Identity Center nuance: the IdC INSTANCE itself is enabled
# account-wide via the AWS Console (one-time action); Terraform
# cannot create it. We document this in idc.tf and instead manage
# the permission sets + group assignments, which ARE Terraform-
# manageable. The data source `aws_ssoadmin_instances` lets us
# look up the existing instance ARN at apply time.
#
# Permission boundaries are LOAD-BEARING: every service role gets
# `permissions_boundary = aws_iam_policy.service_boundary.arn`.
# The boundary caps each role's effective permissions regardless of
# what inline/attached policies say -- so a future PR that adds an
# over-permissive inline policy cannot escalate the role's blast
# radius.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# Data source for IAM Identity Center. The IdC instance is created
# out-of-band (AWS Console, one-time, per environment). Terraform
# only manages permission sets and group assignments -- so we read
# the instance ARN via this data source. See idc.tf for the
# permission set + assignment resources.
data "aws_ssoadmin_instances" "this" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Canonical resource names that other units will need. They are
  # declared here as a single source of truth so a downstream module
  # (U6 data tier, U7 sample app) can reference them without
  # duplicating the naming convention.
  data_bucket_name    = "${var.project_name}-data-${var.environment}"
  audit_bucket_name   = "${var.project_name}-audit-${var.environment}"
  state_bucket_prefix = "${var.project_name}-state-"

  # ECS log group name. U7 owns the actual log group; U4 references
  # it in the ECS task role's logs:PutLogEvents statement via an
  # ARN. The exact log group name is documented here so U7 picks
  # the same value.
  ecs_log_group_name = "/ecs/${var.project_name}-${var.environment}"
}