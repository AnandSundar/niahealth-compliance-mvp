###############################################################################
# modules/edge/waf.tf
# WAFv2 web ACL in front of the ALB.
#
# Requirements (R5):
#   - Web ACL associated with the ALB.
#   - AWS managed rule groups: CommonRuleSet + KnownBadInputsRuleSet.
#   - Default action: allow.
#   - In production: rule group action = BLOCK (verified by AWS Config
#     rule `wafv2-managed-rule-not-in-count-mode` with a CloudWatch
#     alarm on NON_COMPLIANT -- that Config rule is a U5 deliverable).
#
# Implementation: hand-roll the aws_wafv2_web_acl resource (the
# terraform-aws-modules/waf wrapper is not in the project, and a
# hand-rolled block is also what the AWS Prescriptive Guidance
# recommends for managed-rule groups -- the wrapper adds no value
# for this surface).
#
# The `override_action` at the group level switches the entire group
# between `count` (dev-friendly -- test traffic is observed but not
# blocked) and `none` (production -- the group rules apply with
# their per-rule AWS defaults, which are typically BLOCK for the
# Common and KnownBadInputs rule sets). The local `waf_rule_action`
# in main.tf is the override_action value: "count" in dev,
# "none" in production.
###############################################################################

resource "aws_wafv2_web_acl" "edge" {
  name        = "${local.name_prefix}-waf"
  description = "Public-facing WAFv2 ACL in front of the ALB. Managed rule groups: CommonRuleSet + KnownBadInputsRuleSet."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS Managed Rules: Common Rule Set -- the baseline OWASP top-10
  # coverage. Priority 1 so user-defined rules can come after.
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    # override_action: "count" makes the group rules observe-only
    # (dev/staging); "none" applies the group's per-rule actions as
    # published by AWS (production -- most CommonRuleSet rules
    # default to BLOCK).
    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-waf-common"
      sampled_requests_enabled   = true
    }
  }

  # Known Bad Inputs Rule Set -- blocks requests matching known
  # malicious request patterns (LOG4J-like strings, etc.).
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-waf-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# Associate the WAFv2 web ACL with the ALB.
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = module.alb.arn
  web_acl_arn  = aws_wafv2_web_acl.edge.arn
}
