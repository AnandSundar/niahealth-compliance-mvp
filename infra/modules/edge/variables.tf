###############################################################################
# modules/edge/variables.tf
# Inputs for the edge module: the ALB, ACM cert, and WAFv2 web ACL that
# sit in the public tier in front of the (future) ECS Fargate service.
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
  description = "Short project identifier used in resource names."
  type        = string
  default     = "niahealth"
}

variable "vpc_id" {
  description = "VPC ID where the ALB security group is created. Sourced from the networking module."
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs (one per AZ) where the ALB is placed. Sourced from the networking module."
  type        = list(string)
}

variable "domain_name" {
  description = "Primary domain name for the ACM certificate (e.g. dev.niahealth.example.com). Subject of the cert."
  type        = string
}

variable "subject_alternative_names" {
  description = "Optional list of SANs for the ACM cert (e.g. api.dev.niahealth.example.com). Default: a single wildcard subdomain under domain_name."
  type        = list(string)
  default     = []
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS validation of the ACM cert. When null, the module falls back to EMAIL validation (which requires manual approval and is documented as a U3 limitation -- a real deploy would pass the zone ID)."
  type        = string
  default     = null
}

variable "waf_block_mode" {
  description = "When true, WAFv2 managed rule groups use action=BLOCK (production posture). When false (default for dev), they use action=COUNT to avoid blocking tests. Controlled per-environment."
  type        = bool
  default     = false
}

variable "alb_access_logs_bucket" {
  description = "S3 bucket name for ALB access logs. The plan defers the data-tier S3 bucket to U6; for now we leave this null and the ALB has no access logs (a documented U6 migration item)."
  type        = string
  default     = null
}

variable "alb_access_logs_prefix" {
  description = "S3 key prefix for ALB access logs when alb_access_logs_bucket is set."
  type        = string
  default     = "alb"
}

variable "tags" {
  description = "Extra tags to apply to edge resources. The 3 required tags (Environment, DataClass, Owner) are added by the AWS provider's default_tags block in providers.tf."
  type        = map(string)
  default     = {}
}
