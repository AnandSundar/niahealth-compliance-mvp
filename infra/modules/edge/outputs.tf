###############################################################################
# modules/edge/outputs.tf
# Outputs for the edge surface. Consumed by U7 (sample app wires
# the ECS service to the target group) and by the root module's
# plan-output.txt (resource counts).
#
# The v9 ALB module exposes:
#   - listeners       : map keyed by our listener key (https, http-to-https)
#   - target_groups   : map keyed by our target group key (ecs-placeholder)
# We surface the per-key attributes here so consumers don't have to
# know the wrapper's map-of-objects shape.
###############################################################################

output "alb_arn" {
  description = "ARN of the public ALB. Consumed by the WAFv2 association (internal) and by the root module."
  value       = module.alb.arn
}

output "alb_dns_name" {
  description = "DNS name of the public ALB. The A-record target for the domain in Route53 (U7 will own the alias record)."
  value       = module.alb.dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the ALB. Used as the Route53 alias target."
  value       = module.alb.zone_id
}

output "alb_security_group_id" {
  description = "ID of the ALB's dedicated security group. Useful for downstream SG rules (e.g. an ECS task SG that needs to accept from the ALB SG)."
  value       = aws_security_group.alb.id
}

output "alb_listener_https_arn" {
  description = "ARN of the HTTPS listener. Referenceable for downstream rules and CloudWatch metrics."
  value       = module.alb.listeners["https"].arn
}

output "alb_listener_http_arn" {
  description = "ARN of the HTTP listener (the redirect)."
  value       = module.alb.listeners["http-to-https"].arn
}

output "acm_certificate_arn" {
  description = "ARN of the ACM certificate attached to the ALB. Useful for downstream services (e.g. CloudFront) that need the same cert."
  value       = module.acm.acm_certificate_arn
}

output "waf_web_acl_arn" {
  description = "ARN of the WAFv2 web ACL. Useful for cross-region replication and for the U5 AWS Config rule that monitors for 'managed rule not in block mode' in production."
  value       = aws_wafv2_web_acl.edge.arn
}

output "waf_web_acl_id" {
  description = "ID of the WAFv2 web ACL."
  value       = aws_wafv2_web_acl.edge.id
}

output "target_group_ecs_arn" {
  description = "ARN of the placeholder target group for the ECS service. U7 will register the ECS service to this TG (and may rename it for clarity)."
  value       = module.alb.target_groups["ecs-placeholder"].arn
}

output "target_group_ecs_name" {
  description = "Name of the placeholder target group for the ECS service."
  value       = module.alb.target_groups["ecs-placeholder"].name
}
