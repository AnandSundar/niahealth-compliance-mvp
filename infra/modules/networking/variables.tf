###############################################################################
# modules/networking/variables.tf
# Inputs for the network plane. Defaults match the root module so most
# consumers can call this module with zero arguments. The 3 required tags
# (Environment, DataClass, Owner) are added by the AWS provider's
# default_tags block in infra/providers.tf; the `tags` input here is for
# module-local extras (Project, ManagedBy, CostCenter).
###############################################################################

variable "region" {
  description = "AWS region. Data residency requires ca-central-1 for PHI (R1)."
  type        = string
  default     = "ca-central-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod). Used in resource names and tags."
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Short project identifier used in resource names. Keeps ARNs readable and grep-friendly."
  type        = string
  default     = "niahealth"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the VPC. The plan pins 10.0.0.0/16 so we have room for the public/private/isolated tiers and future secondary CIDRs."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of 3 availability zone names in the home region. The plan pins 3 AZs in ca-central-1 for HA across the public/private/isolated tiers."
  type        = list(string)
  default     = ["ca-central-1a", "ca-central-1b", "ca-central-1c"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks, one per AZ. Hosts the ALB, NAT gateways, and any internet-facing endpoints."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks, one per AZ. Hosts ECS Fargate tasks and other compute that needs VPC endpoints but no public IP. Routes to NAT for non-PHI egress only."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
}

variable "isolated_subnet_cidrs" {
  description = "Isolated subnet CIDR blocks, one per AZ. Hosts the RDS instance, RDS Proxy, and any other data-tier compute. NO route to NAT (PHI never traverses the public NAT -- enforced by the Conftest policy)."
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24", "10.0.22.0/24"]
}

variable "flow_log_retention_days" {
  description = "Retention in days for the VPC Flow Logs CloudWatch log group. 2557 days = 7 years, matching the PHIPA / PIPEDA retention guidance."
  type        = number
  default     = 2557
}

variable "flow_log_cloudwatch_kms_key_id" {
  description = "Optional KMS CMK ARN for encrypting the VPC Flow Logs CloudWatch log group. When null, the AWS-managed CMK is used. U5 will own the dedicated CloudWatch Logs CMK; pass its ARN here from the root module when that unit lands."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags to apply to networking resources. The 3 required tags (Environment, DataClass, Owner) are added by the AWS provider's default_tags block in providers.tf."
  type        = map(string)
  default     = {}
}
