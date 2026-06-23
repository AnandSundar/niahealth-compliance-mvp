###############################################################################
# modules/security/secrets-rotation.tf
#
# Secrets Manager rotation configuration for the RDS master
# password. The plan calls for the AWS-managed rotation Lambda
# blueprint (SecretsManagerRDSPostgreSQLRotationSingleUser),
# which is provisioned by AWS in every region by default -- we
# do NOT create a custom Lambda.
#
# Why the AWS-managed blueprint: the blueprint is a hardened,
# AWS-maintained function that handles the single-user rotation
# pattern (rotate the master password, update RDS, verify the
# new password works, mark AWSCURRENT). Forging our own would
# invite bugs in the rotation handshake (the staging-label
# dance) and is not justified for an MVP.
#
# Rotation window: 30 days. Matches the PHIPA / PIPEDA "no
# credentials older than 30 days" guidance the plan references
# in R9.
#
# The Lambda execution role is owned by the identity module
# (aws_iam_role.lambda_rotation_role) and is granted the
# secretsmanager:RotateSecret family + explicit Deny on RDS
# mutation. See modules/identity/roles.tf. This file is the
# resource-policy side: it grants the rotation Lambda role
# permission to call secretsmanager:RotateSecret on the
# rds-master-password secret.
#
# This file lives in the existing security module alongside
# kms.tf and secrets.tf. The variable declarations for
# `region`, `environment`, `project_name`, `tags`, and the 4
# CMK ARNs are inherited from kms.tf (single module, shared
# locals).
###############################################################################

# ---------------------------------------------------------------------------
# Resource policy on the secret granting the rotation Lambda
# permission to call secretsmanager:RotateSecret on it. Without
# this, the Lambda cannot initiate rotation even with the right
# execution role -- the resource policy is the per-secret gate.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "rds_master_password_rotation_policy" {
  statement {
    sid    = "AllowRotationLambdaRotateSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:RotateSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]

    principals {
      type = "AWS"
      # The Lambda's execution role. Owned by the identity
      # module and passed in by the root.
      identifiers = [var.lambda_rotation_role_arn]
    }

    resources = ["*"]
  }
}

resource "aws_secretsmanager_secret_policy" "rds_master_password" {
  secret_arn = aws_secretsmanager_secret.rds_master_password.arn
  policy     = data.aws_iam_policy_document.rds_master_password_rotation_policy.json
}

resource "aws_secretsmanager_secret_rotation" "rds_master_password" {
  secret_id           = aws_secretsmanager_secret.rds_master_password.id
  rotation_lambda_arn = "arn:${data.aws_partition.current.partition}:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:SecretsManagerRDSPostgreSQLRotationSingleUser"

  rotate_immediately = false

  rotation_rules {
    automatically_after_days = 30
  }

  depends_on = [aws_secretsmanager_secret_policy.rds_master_password]
}