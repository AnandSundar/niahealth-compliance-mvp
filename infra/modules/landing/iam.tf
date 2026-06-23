###############################################################################
# modules/landing/iam.tf
# GitHub OIDC provider using the official terraform-aws-modules wrapper
# (the v5.50.0 GitHub-flavored submodule -- not the generic iam-oidc-provider
# which assumes a different URL/client_id_list shape). The provider ARN
# is exported and consumed by oidc.tf to create the deploy role with
# a trust policy that pins sub + aud + workflow_file.
#
# Pin to a specific tag (NOT main) to control supply-chain risk.
# The plan suggests ~> 5.50; we pin v5.50.0 exactly to match the plan.
###############################################################################

module "iam_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-github-oidc-provider"
  version = "5.50.0"

  tags = var.tags
}
