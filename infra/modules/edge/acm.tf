###############################################################################
# modules/edge/acm.tf
# ACM certificate for the ALB HTTPS listener.
#
# Validation method:
#   - Preferred: DNS validation via Route53 (var.route53_zone_id).
#     DNS validation is auto-renewing and does not require manual
#     approval -- the right answer for a CI-driven deploy.
#   - Fallback: EMAIL validation when route53_zone_id is null.
#     EMAIL requires a human to click a link in the AWS-issued
#     email; this is fine for the terraform-only demo path
#     (no live AWS account, no real Route53 zone) but a production
#     deploy would always pass the zone ID.
#
# Why terraform-aws-modules/acm/aws: the wrapper handles both
# validation methods and the SAN wiring in one block, which keeps
# the cert ARN stable across runs.
###############################################################################

module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 5.0"

  domain_name = var.domain_name

  # SAN list: a single wildcard under the domain is a safe default
  # (e.g. *.dev.niahealth.example.com). When the consumer passes
  # their own SANs via var.subject_alternative_names, those win.
  subject_alternative_names = length(var.subject_alternative_names) > 0 ? var.subject_alternative_names : ["*.${var.domain_name}"]

  # validation_method: prefer DNS when a zone ID is provided, else
  # fall back to EMAIL.
  validation_method = var.route53_zone_id != null ? "DNS" : "EMAIL"

  # zone_id triggers Route53 record creation in the wrapper when
  # validation_method = "DNS". When validation_method = "EMAIL" the
  # zone_id is ignored, so it's safe to pass null conditionally.
  zone_id = var.route53_zone_id

  tags = var.tags
}
