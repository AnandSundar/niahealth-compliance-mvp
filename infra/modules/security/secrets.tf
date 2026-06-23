###############################################################################
# modules/security/secrets.tf
#
# Secrets Manager secrets for the data tier.
#
# Two secrets, both `SecureString` (KMS-encrypted at rest with a
# customer-managed CMK):
#
#   - rds-master-password    : RDS Postgres master password. Rotated
#                              every 30 days by the Lambda in
#                              secrets-rotation.tf.
#   - cognito-client-secret  : Cognito User Pool app client secret.
#                              Generated up-front; U7 (sample app)
#                              wires the actual User Pool client
#                              to use this secret.
#
# Both secrets use a random_password generated AT PLAN TIME by
# Terraform's `random_password` resource. The first apply creates
# the secret with the random value; subsequent applies do NOT
# regenerate (random_password persists across applies unless
# tainted). The rotation Lambda updates the stored value
# independently after that.
#
# Note on lifecycle: the rds-master-password secret's value is
# pinned by random_password. If the random resource is destroyed
# and recreated, the secret value changes; that would break the
# live RDS connection until RDS is restarted with the new
# password. For that reason the random_password resource below
# sets lifecycle.prevent_destroy = true -- destroying the
# random password (and thus the secret value) is a manual
# operator decision, not a `terraform destroy` accident.
#
# This file lives in the existing security module alongside
# kms.tf. The variable declarations for `region`, `environment`,
# `project_name`, `tags` are inherited from kms.tf (single
# module, shared locals).
###############################################################################

data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# RDS master password (random, pinned across applies).
# ---------------------------------------------------------------------------
resource "random_password" "rds_master_password" {
  length  = 32
  special = true

  # exclude characters that break common shell + RDS CLI parsing.
  override_special = "!#$%&*()-_=+[]{}<>:?"

  lifecycle {
    # Prevent accidental destruction: deleting this resource
    # would orphan the Secrets Manager secret value, which the
    # live RDS instance would still be using. To rotate the
    # password manually, the operator must run
    # `terraform taint random_password.rds_master_password`
    # explicitly.
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "rds_master_password" {
  name        = "${local.name_prefix}/rds-master-password"
  description = "RDS Postgres master password. Auto-rotated every 30 days by the Lambda rotation function in secrets-rotation.tf."

  # CMK for the RDS key domain. Same key that encrypts the RDS
  # instance at rest, so a key compromise exposes both layers
  # (which is the desired blast radius).
  kms_key_id = aws_kms_key.rds.arn

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "rds_master_password" {
  secret_id     = aws_secretsmanager_secret.rds_master_password.id
  secret_string = random_password.rds_master_password.result
}

# ---------------------------------------------------------------------------
# Cognito User Pool client secret (random, pinned across applies).
# ---------------------------------------------------------------------------
resource "random_password" "cognito_client_secret" {
  length  = 64
  special = true

  override_special = "!#$%&*()-_=+[]{}<>:?"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "cognito_client_secret" {
  name        = "${local.name_prefix}/cognito-client-secret"
  description = "Cognito User Pool app client secret. Consumed by U7's sample app during the OAuth2 client_credentials exchange. KMS-encrypted with the S3-PHI CMK (PHI-adjacent -- same key domain as the data)."

  # S3 PHI key domain: the Cognito client authenticates the same
  # humans who read PHI from the data bucket, so its secret
  # shares the PHI key domain.
  kms_key_id = aws_kms_key.s3_phi.arn

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "cognito_client_secret" {
  secret_id     = aws_secretsmanager_secret.cognito_client_secret.id
  secret_string = random_password.cognito_client_secret.result
}

# ---------------------------------------------------------------------------
# Outputs.
#
# Both secret ARNs are exposed because U6 (RDS instance creation)
# and U7 (sample app + Cognito pool client) need them.
# ---------------------------------------------------------------------------

output "rds_master_password_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RDS master password. Consumed by U6's RDS instance (password = the secret value) and by the sample app (DB connection string)."
  value       = aws_secretsmanager_secret.rds_master_password.arn
}

output "rds_master_password_secret_name" {
  description = "Name of the Secrets Manager secret holding the RDS master password. Useful for aws cli / runbook references."
  value       = aws_secretsmanager_secret.rds_master_password.name
}

output "cognito_client_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Cognito User Pool client secret. Consumed by U7's sample app during OAuth2 client setup."
  value       = aws_secretsmanager_secret.cognito_client_secret.arn
}

output "cognito_client_secret_name" {
  description = "Name of the Secrets Manager secret holding the Cognito client secret."
  value       = aws_secretsmanager_secret.cognito_client_secret.name
}