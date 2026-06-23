###############################################################################
# modules/landing/oidc.tf
# The OIDC-backed GitHub Actions deploy role.
#
# Trust policy MUST pin all three claims:
#   - sub  : repo:<org>/<repo>:ref:refs/heads/main
#   - aud  : sts.amazonaws.com
#   - token.actions.githubusercontent.com:workflow_file :
#            infra/.github/workflows/apply.yml
# The workflow_file pin is the differentiator: a malicious workflow
# file added under .github/workflows/ cannot assume the role even if
# it runs on main.
#
# Implementation note: the v5.50.0 iam-github-oidc-role module only
# exposes the `subjects` (sub) and `audience` (aud) conditions; it
# does NOT expose a hook for adding an arbitrary extra condition
# block to the trust policy. To pin `workflow_file` we hand-roll the
# role with aws_iam_role + aws_iam_policy_document so the assume-role
# policy is a single, reviewable JSON block. The OIDC provider is
# still created by the community module (iam.tf) for consistency.
#
# Policy attachment: AdministratorAccess is INTENTIONALLY WIDE for the
# interview-pitch demo so a single role can drive every layer (U3+
# networking, observability, data tier, compute) without per-layer
# trust bootstrapping. In a real production deploy this would be
# replaced with a per-layer permission set (e.g. terraform-networking,
# terraform-observability) with explicit resource ARN scoping.
###############################################################################

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# The trust policy as a structured document. Three condition blocks:
#   1. sub          : StringEquals  (exact ref:refs/heads/main)
#   2. aud          : StringEquals  (sts.amazonaws.com)
#   3. workflow_file: StringEquals  (infra/.github/workflows/apply.yml)
data "aws_iam_policy_document" "deploy_assume_role" {
  statement {
    sid    = "GitHubActionsOIDCAssume"
    effect = "Allow"

    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.iam_oidc_provider.arn]
    }

    # 1. Pin sub to a single repo + branch.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub]
    }

    # 2. Pin aud. (Required for OIDC; GitHub always sets this.)
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # 3. Pin the exact workflow file. This is the control that
    #    prevents a malicious workflow added later from inheriting
    #    the deploy role even if it runs on main.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:workflow_file"
      values   = [local.github_workflow_file]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name        = "niahealth-${var.environment}-deploy"
  description = "OIDC-backed GitHub Actions deploy role for ${var.github_org}/${var.github_repo} (branch: main, workflow: ${local.github_workflow_file})."

  assume_role_policy = data.aws_iam_policy_document.deploy_assume_role.json

  # Cap sessions at 1h. Long sessions are a defense-in-depth control:
  # a stolen OIDC token is only useful for the duration of a CI job.
  max_session_duration = 3600

  tags = var.tags
}

# Intentionally wide for the MVP demo; see header comment. In a real
# production deploy this would be replaced with a per-layer permission
# set with explicit resource ARN scoping.
resource "aws_iam_role_policy_attachment" "deploy_administrator" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}
