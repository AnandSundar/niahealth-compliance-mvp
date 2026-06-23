###############################################################################
# modules/networking/outputs.tf
# Outputs for the network plane. Consumed by the root module
# (main.tf) to wire the edge module (ALB subnets, ALB SG, WAF
# association) and by the data tier in U6 (isolated subnets for
# the RDS subnet group, VPC endpoint security group).
###############################################################################

output "vpc_id" {
  description = "VPC ID. Consumed by the edge module to create the ALB and by the security module to scope VPC endpoint SGs."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "Primary IPv4 CIDR of the VPC. Useful for SG rules and endpoint policies that need to scope to the VPC CIDR."
  value       = module.vpc.vpc_cidr_block
}

output "vpc_arn" {
  description = "VPC ARN. Useful for resource policies that need a VPC-scoped principal."
  value       = module.vpc.vpc_arn
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (one per AZ). Hosts the ALB, NAT gateways, and any internet-facing endpoints."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (one per AZ). Hosts ECS Fargate tasks; routes to NAT for non-PHI egress only."
  value       = module.vpc.private_subnets
}

output "isolated_subnet_ids" {
  description = "List of isolated (database) subnet IDs (one per AZ). Hosts the RDS instance + RDS Proxy. NO route to NAT or IGW -- PHI never traverses the public NAT."
  value       = module.vpc.database_subnets
}

output "isolated_subnet_group_name" {
  description = "Name of the database subnet group created by the v5 wrapper. Consumed by U6's RDS subnet group."
  value       = module.vpc.database_subnet_group_name
}

output "nat_gateway_ids" {
  description = "List of NAT gateway IDs (one per AZ). Exposed for future Conftest/Checkov checks that need to verify no PHI-bearing SG routes to a NAT."
  value       = module.vpc.nat_ids
}

output "nat_public_ips" {
  description = "List of public IPs assigned to the NAT gateways. Useful for outbound-allowlist on third-party services."
  value       = module.vpc.nat_public_ips
}

output "vpc_endpoint_security_group_id" {
  description = "Security group ID created by the vpc-endpoints wrapper for the interface endpoints. U7 will tighten ingress to the ECS task SG; for now the wrapper default allows the VPC CIDR."
  value       = module.vpc_endpoints.security_group_id
}

output "vpc_endpoint_ids" {
  description = "Map of VPC endpoint service short name -> endpoint ID. Useful for endpoint policies and reference from U4/U5."
  value       = { for k, v in module.vpc_endpoints.endpoints : k => v.id }
}

output "vpc_flow_log_id" {
  description = "ID of the aws_flow_log resource. Useful for cross-module references (e.g. the U5 logging fan-in)."
  value       = module.vpc.vpc_flow_log_id
}

output "vpc_flow_log_destination_arn" {
  description = "Destination ARN of the flow log (CloudWatch log group ARN). U5 can use this to attach a subscription filter for fan-in to the audit S3 archive."
  value       = module.vpc.vpc_flow_log_destination_arn
}

output "internet_gateway_id" {
  description = "ID of the internet gateway attached to the VPC. Exposed for completeness and for future Conftest/Checkov checks."
  value       = module.vpc.igw_id
}
