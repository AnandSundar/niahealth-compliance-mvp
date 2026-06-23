###############################################################################
# modules/landing/main.tf
#
# The "landing" module owns the AWS account bootstrap: the OIDC
# provider, the OIDC-backed GitHub Actions deploy role, and a
# documented-name placeholder for the state bucket + lock table. Those
# two state resources are created by infra/scripts/bootstrap.sh
# (a follow-up unit) because Terraform cannot manage its own state
# backend (chicken-and-egg).
#
# Glue: this file is intentionally tiny. The heavy lifting lives in
# iam.tf and oidc.tf so each concern is reviewable in isolation.
###############################################################################

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # The exact sub claim string that must match the GitHub Actions OIDC
  # token. We use StringEquals (not StringLike) so the role cannot be
  # assumed by a fork, a feature branch, or a pull_request build.
  github_sub = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"

  # The exact workflow file path that must match. Pinning this means a
  # malicious workflow file added under .github/workflows/ cannot assume
  # the deploy role even if it runs on main.
  github_workflow_file = "infra/.github/workflows/apply.yml"
}
