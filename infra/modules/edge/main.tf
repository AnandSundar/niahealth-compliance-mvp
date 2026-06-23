###############################################################################
# modules/edge/main.tf
#
# The "edge" module owns the public-facing surface:
#   - ACM certificate (acm.tf)
#   - Application Load Balancer in public subnets (alb.tf)
#   - WAFv2 web ACL attached to the ALB (waf.tf)
#
# All three are present in the same module so a single
# `terraform apply -target=module.edge` creates the entire public
# surface, and a single `terraform destroy -target=module.edge` tears
# it down. The plan splits each concern into its own file
# (acm.tf / alb.tf / waf.tf) for reviewability.
###############################################################################

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # The WAFv2 rule action depends on environment. dev -> COUNT
  # (so test traffic isn't blocked); prod -> BLOCK (the compliance
  # posture the plan mandates).
  waf_rule_action = var.waf_block_mode ? "block" : "count"
}
