###############################################################################
# modules/landing/outputs.tf
# Outputs the OIDC provider ARN and the OIDC-backed deploy role ARN
# (consumed by the GitHub Actions workflow). The state-bucket /
# lock-table names are also exposed as canonical-name placeholders
# (the resources themselves are created by infra/scripts/bootstrap.sh
# in a later unit; exposed now so root-level consumers and human
# readers have a single source of truth for what the bootstrap
# should produce).
###############################################################################

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider. Referenceable from the deploy role's trust policy."
  value       = module.iam_oidc_provider.arn
}

output "deploy_role_arn" {
  description = "ARN of the GitHub Actions deploy role. Set as AWS_ROLE_TO_ASSUME in .github/workflows/apply.yml."
  value       = aws_iam_role.deploy.arn
}

output "deploy_role_name" {
  description = "Name of the GitHub Actions deploy role (no ARN path). Useful for IAM policy attachment references and break-glass scoping."
  value       = aws_iam_role.deploy.name
}

output "deploy_role_max_session_duration" {
  description = "Maximum session duration in seconds for the deploy role. Currently 1h as a defense-in-depth control."
  value       = aws_iam_role.deploy.max_session_duration
}

# The state backend is created by the one-time bootstrap script
# (infra/scripts/bootstrap.sh, U3+). We expose the canonical names
# here so root-level consumers (and human readers) have a single
# source of truth for what the bootstrap should produce.
output "state_bucket_name" {
  description = "Name of the S3 state bucket. Created by bootstrap.sh; matches what backend.tf expects."
  value       = "${var.project_name}-state-${var.environment}"
}

output "state_lock_table_name" {
  description = "Name of the DynamoDB state lock table. Created by bootstrap.sh; matches what backend.tf expects."
  value       = "${var.project_name}-state-lock"
}
