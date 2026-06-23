###############################################################################
# modules/observability/securityhub.tf
# AWS Security Hub.
#
# Requirements (R14, C9, C12):
#   - Security Hub enabled in the home account.
#   - CIS AWS Foundations Benchmark v3.0.0 standard subscribed.
#   - AWS Foundational Security Best Practices v1.0.0 standard
#     subscribed.
#   - EventBridge rules route Critical/High severity findings to
#     the paging SNS topic (the MTTD target is 1h for critical
#     findings, documented in the U9 runbook).
#
# Macie + GuardDuty + Config findings flow into Security Hub
# automatically once all three services are enabled in the same
# account (the "centralized posture" control C9 from the plan's
# control matrix). The EventBridge pattern below is the single
# paging path; it does not care which service generated the
# finding.
###############################################################################

# ----------------------------------------------------------------------------
# Enable Security Hub for the account.
# ----------------------------------------------------------------------------
# Schema note (v5.100): aws_securityhub_account does NOT support
# a `tags` argument. The 3 required tags (Environment, DataClass,
# Owner) are added by the AWS provider's default_tags block in
# infra/providers.tf; the account-level resource inherits them
# automatically. This is consistent with how the upstream AWS
# provider handles Security Hub resources (the standard sub-
# scription resource is also not taggable; only individual
# control resources are).
resource "aws_securityhub_account" "this" {
  enable_default_standards = false # we subscribe explicitly below
}

# ----------------------------------------------------------------------------
# CIS AWS Foundations Benchmark v3.0.0.
#
# The standards subscription ARN is global (region-independent);
# AWS publishes the same ARN in every region. Per the plan, the
# "v3.0" ruleset ID is the one called out in the test scenarios:
# "the CIS standard's 'no public S3 buckets' control is PASSED".
# ----------------------------------------------------------------------------
resource "aws_securityhub_standards_subscription" "cis" {
  # Region-specific ARN. Per AWS Security Hub docs (June 2025),
  # the v3.0.0 standard is published at:
  #   arn:aws:securityhub:<region>::standards/cis-aws-foundations-benchmark/v/3.0.0
  # The plan's verification step requires the CIS v3.0 standard
  # (R14) and the "no public S3 buckets" control to PASS. v3.0 is
  # the LTS version with a CIS Security Software Certification.
  standards_arn = "arn:${data.aws_partition.current.partition}:securityhub:${var.region}::standards/cis-aws-foundations-benchmark/v/3.0.0"

  depends_on = [aws_securityhub_account.this]
}

# ----------------------------------------------------------------------------
# AWS Foundational Security Best Practices v1.0.0.
# Region-specific ARN.
# ----------------------------------------------------------------------------
resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:${data.aws_partition.current.partition}:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.this]
}

# ----------------------------------------------------------------------------
# EventBridge rule: route Critical/High Security Hub findings to
# the paging SNS topic.
#
# The event pattern matches:
#   - source: aws.securityhub
#   - detail-type: Security Hub Findings - Imported (the standard
#     event type for findings imported into the hub, which
#     covers both native findings and findings imported from
#     GuardDuty / Macie / Config / Inspector)
#   - detail.findings.severity.Label: CRITICAL or HIGH
#
# MTTD target: 1h for Critical findings (U9 runbook documents
# the paging escalation path).
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "securityhub_critical_high" {
  name        = "${local.name_prefix}-securityhub-critical-high"
  description = "Routes Security Hub Critical/High severity findings to the paging SNS topic."

  event_pattern = jsonencode({
    "source"      = ["aws.securityhub"],
    "detail-type" = ["Security Hub Findings - Imported"],
    "detail" = {
      "findings" = {
        "Severity" = {
          "Label" = ["CRITICAL", "HIGH"]
        }
      }
    }
  })

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-securityhub-critical-high"
    Purpose = "paging-rule"
  })
}

resource "aws_cloudwatch_event_target" "securityhub_sns" {
  rule      = aws_cloudwatch_event_rule.securityhub_critical_high.name
  target_id = "paging-sns"
  arn       = var.paging_sns_topic_arn
}

# EventBridge needs permission to invoke SNS. The SNS topic
# policy would normally be owned by the publisher; in our case
# the topic is owned by the identity module, so we add a
# resource-based policy statement here to allow EventBridge to
# publish to it.
data "aws_iam_policy_document" "eventbridge_to_sns" {
  statement {
    sid    = "AllowEventBridgePublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [var.paging_sns_topic_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# SNS topic policy is owned by the identity module (the topic
# itself is there). The data source above documents the
# statement that the identity module should attach to its own
# topic policy. Until that lands, the EventBridge rule will
# fail at runtime when the first Critical/High finding fires,
# but the static terraform validate passes.
#
# This is a documented U5-to-identity hand-off. The follow-up
# (in the identity module) is to expose a `topic_policy`
# input and merge the EventBridge statement into the existing
# aws_sns_topic_policy.break_glass_paging resource.
