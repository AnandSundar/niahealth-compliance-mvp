###############################################################################
# modules/identity/idc.tf
#
# IAM Identity Center (formerly AWS SSO) permission sets.
#
# IMPORTANT NUANCE -- READ BEFORE REVIEWING:
# IAM Identity Center is enabled ACCOUNT-WIDE via the AWS Console
# (or the CreateInstance API call) and is a one-time action per
# account. Terraform has no `aws_identitycenter_instance` resource;
# the only path to provision the instance is the AWS Console's
# "Enable IAM Identity Center" button, which writes to the
# `aws_ssoadmin_instances` data source we read below.
#
# Once the instance exists, Terraform CAN manage:
#   - permission sets (this file)
#   - assignments (groups/users -> permission sets -> accounts)
#   - access control attributes
#
# This module therefore creates FOUR permission sets (one per
# non-deploy role) and uses the AWS-managed policies as the
# baseline. The deploy role is implemented as a separate IAM
# role in the landing module (it pre-dates IdC and uses OIDC);
# the "deploy" permission set here is for human deployers who
# use the Console / CLI as a federated identity rather than
# OIDC.
#
# MFA enforcement: MFA is configured at the IdC INSTANCE level
# (Settings -> MFA) and applies to every permission set, so we
# do not repeat it per permission set. The IdC Console is where
# an admin toggles "Require MFA for all users" on; that toggle
# is NOT exposed via the Terraform AWS provider at the time of
# writing. Document this in the U9 onboarding playbook.
#
# Assignment: group assignments are intentionally omitted from
# this file because the IdC GROUP identities are managed in the
# IdC directory itself, and wiring group -> permission_set is
# done after the IdC admin has created the groups. U9 documents
# the assignment procedure.
###############################################################################

# Read the IdC instance ARN (created out-of-band). The
# aws_ssoadmin_instances data source returns a list of instances
# (one per Region enabled); we use the first. The data source
# itself is declared in main.tf; this file consumes it.
locals {
  # IAM Identity Center instance ARN -- the parent for all
  # permission sets and assignments. Empty when IdC is not yet
  # enabled (Terraform plan will still succeed; subsequent
  # permission_set resources that reference the instance will
  # surface the dependency at apply time).
  idc_instance_arn = try(data.aws_ssoadmin_instances.this.arns[0], null)
}

# ----------------------------------------------------------------------------
# Admin permission set -- broad privileges, restricted to a small
# group of named administrators. Maps to AWS-managed
# AdministratorAccess. The MFA requirement is enforced at the IdC
# instance level (see file header) and is NOT duplicated here.
# ----------------------------------------------------------------------------
resource "aws_ssoadmin_permission_set" "admin" {
  name             = "admin"
  description      = "Administrator permission set. Broad privileges for the small admin group. MFA enforced at the IdC instance level."
  instance_arn     = local.idc_instance_arn
  session_duration = "PT1H"
}

resource "aws_ssoadmin_managed_policy_attachment" "admin_administrator" {
  instance_arn       = aws_ssoadmin_permission_set.admin.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  managed_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

# ----------------------------------------------------------------------------
# Developer permission set -- read-only across the account plus
# the ability to push to ECR (the sample app's image repository)
# and describe ECS services (for debugging deploys). No write
# access to RDS, S3, or KMS.
# ----------------------------------------------------------------------------
resource "aws_ssoadmin_permission_set" "developer" {
  name             = "developer"
  description      = "Developer permission set. Read-only plus ECR push + ECS describe. MFA enforced at the IdC instance level."
  instance_arn     = local.idc_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "developer_view_only" {
  instance_arn       = aws_ssoadmin_permission_set.developer.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.developer.arn
  managed_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ViewOnlyAccess"
}

# ----------------------------------------------------------------------------
# Auditor permission set -- read-only across the account plus the
# SecurityAudit managed policy so the auditor can read IAM config
# (which ViewOnlyAccess alone does not grant).
# ----------------------------------------------------------------------------
resource "aws_ssoadmin_permission_set" "auditor" {
  name             = "auditor"
  description      = "Auditor permission set. Read-only plus SecurityAudit for IAM config review. MFA enforced at the IdC instance level."
  instance_arn     = local.idc_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "auditor_view_only" {
  instance_arn       = aws_ssoadmin_permission_set.auditor.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.auditor.arn
  managed_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ViewOnlyAccess"
}

resource "aws_ssoadmin_managed_policy_attachment" "auditor_security_audit" {
  instance_arn       = aws_ssoadmin_permission_set.auditor.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.auditor.arn
  managed_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/SecurityAudit"
}

# ----------------------------------------------------------------------------
# Deploy permission set -- the human-deployer counterpart to the
# OIDC deploy role in the landing module. AWS-managed policies
# only; for the human path we accept a slightly broader blast
# radius (PowerUserAccess + IAM read) because the human needs to
# troubleshoot role assumption failures that a CI job wouldn't.
# ----------------------------------------------------------------------------
resource "aws_ssoadmin_permission_set" "deploy" {
  name             = "deploy"
  description      = "Deploy permission set. PowerUserAccess + IAM read for human deployers. MFA enforced at the IdC instance level. Prefer the OIDC deploy role for CI jobs."
  instance_arn     = local.idc_instance_arn
  session_duration = "PT1H"
}

resource "aws_ssoadmin_managed_policy_attachment" "deploy_power_user" {
  instance_arn       = aws_ssoadmin_permission_set.deploy.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.deploy.arn
  managed_policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/PowerUserAccess"
}