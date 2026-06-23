###############################################################################
# modules/identity/access_analyzer.tf
#
# IAM Access Analyzer (account-wide). The analyzer reviews every
# resource-based policy in the account (S3 bucket policies, KMS
# key policies, IAM trust policies, Lambda function policies,
# SNS topic policies, SQS queue policies, Secrets Manager resource
# policies) for "external access" -- i.e. a principal from outside
# the account or an unauthenticated principal could reach it.
#
# Posture:
#   - analyzer type = ACCOUNT (default; the analyzer runs over
#     every supported resource in the account)
#   - one analyzer per environment (so dev findings don't pollute
#     prod's queue)
#   - findings are reviewed weekly by the auditor group
#     (documented in the U9 runbook)
#
# Note: there is no separate "unresolved findings" resource to
# enforce here -- Access Analyzer surfaces findings in the
# Console / API. U5 wires the findings into Security Hub; U9
# documents the weekly review procedure.
###############################################################################

resource "aws_accessanalyzer_analyzer" "this" {
  analyzer_name = "${local.name_prefix}-analyzer"
  type          = "ACCOUNT"

  tags = merge(var.tags, {
    Name      = "${local.name_prefix}-analyzer"
    Owner     = "niahealth-security"
    DataClass = "phi"
  })
}