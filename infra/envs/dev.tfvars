###############################################################################
# envs/dev.tfvars
# Per-environment overrides for the dev environment.
#
# Convention: -var-file=envs/<env>.tfvars is the source of truth for
# environment-specific values. The root module's variables (main.tf)
# provide defaults so a no-args `terraform plan` is still valid; this
# file is the explicit dev override.
#
# dev-specific posture:
#   - waf_block_mode = false (WAFv2 managed groups use COUNT, not
#     BLOCK, so test traffic isn't accidentally blocked).
#   - route53_zone_id = null (no live Route53 zone; ACM falls back
#     to EMAIL validation, which requires manual approval -- fine
#     for the terraform-only demo path).
#   - domain_name = dev.niahealth.example.com (RFC-2606 reserved
#     .example.com TLD, safe to commit).
###############################################################################

region             = "ca-central-1"
environment        = "dev"
project_name       = "niahealth"
domain_name        = "dev.niahealth.example.com"
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["ca-central-1a", "ca-central-1b", "ca-central-1c"]

# Live Route53 zone ID for DNS validation of the ACM cert. When null
# the edge module falls back to EMAIL validation. Set to a real
# zone ID (e.g. "Z0123456789ABCDEFGHIJ") for a real deploy.
route53_zone_id = null

# WAFv2 managed-rule action: COUNT (dev-friendly) vs BLOCK (prod).
# Default to false in dev so test traffic isn't blocked.
waf_block_mode = false

tags = {
  Project    = "niahealth-compliance-mvp"
  ManagedBy  = "terraform"
  CostCenter = "eng-compliance"
}
