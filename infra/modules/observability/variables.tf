###############################################################################
# modules/observability/variables.tf
# Inputs for the observability plane.
#
# Cross-module seams (the "what depends on what" map):
#   - cloudtrail_kms_key_arn comes from module.security.
#   - cwl_kms_key_arn        comes from module.security.
#   - s3_phi_kms_key_arn     comes from module.security (carried
#                            through for completeness; the audit bucket
#                            uses the cloudtrail CMK so PHI cannot
#                            pivot through the audit CMK).
#   - vpc_flow_log_group_arn comes from module.networking
#                            (the CloudWatch log group ARN that
#                            receives the VPC Flow Logs).
#   - alb_arn, waf_web_acl_arn come from module.edge (U5 does not
#                            create new log groups for ALB/WAF; it
#                            expects those groups to be created by
#                            U3/U6/U7 and is parameterized accordingly).
#   - firehose_role_arn     comes from module.identity (the IAM role
#                            Firehose assumes to write to the audit
#                            bucket).
#   - paging_sns_topic_arn  comes from module.identity (the break-
#                            glass paging topic; Security Hub findings
#                            are routed here on Critical/High).
#   - alb_access_log_group  + waf_log_group are optional variables
#                            (default null) that, when provided, attach
#                            a CloudWatch Logs subscription filter so
#                            the central Firehose receives them. U6
#                            and U7 own the actual log group creation;
#                            U5 just documents the wiring.
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

variable "cloudtrail_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts CloudTrail log files. Sourced from module.security."
  type        = string
}

variable "cwl_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts CloudWatch Logs log groups (CloudTrail, Firehose errors, future ALB/WAF). Sourced from module.security."
  type        = string
}

variable "s3_phi_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts the data-tier PHI bucket. Sourced from module.security. Carried for completeness; the audit bucket uses the cloudtrail CMK by design so PHI cannot pivot through the audit CMK."
  type        = string
}

variable "vpc_flow_log_group_arn" {
  description = "ARN of the CloudWatch log group that receives VPC Flow Logs. Sourced from module.networking. U5 attaches a subscription filter to fan these logs into the central Firehose."
  type        = string
}

variable "alb_arn" {
  description = "ARN of the public ALB. Sourced from module.edge. Currently unused by U5; reserved for the U6/U7 access-log wiring."
  type        = string
  default     = null
}

variable "waf_web_acl_arn" {
  description = "ARN of the WAFv2 web ACL. Sourced from module.edge. Currently unused by U5; reserved for the U6/U7 WAF-log wiring."
  type        = string
  default     = null
}

variable "firehose_role_arn" {
  description = "ARN of the IAM role Firehose assumes to write to the audit S3 bucket. Sourced from module.identity."
  type        = string
}

variable "paging_sns_topic_arn" {
  description = "ARN of the SNS topic that EventBridge pages on Critical/High Security Hub findings. Sourced from module.identity."
  type        = string
}

variable "alb_access_log_group" {
  description = "Name of the CloudWatch log group that receives ALB access logs. U6 will create this; U5 attaches a subscription filter when the value is non-null. Default null means the U5 subscription filter is skipped (the central Firehose receives only VPC Flow Logs for now)."
  type        = string
  default     = null
}

variable "waf_log_group" {
  description = "Name of the CloudWatch log group that receives WAF logs. U6/U7 will create this; U5 attaches a subscription filter when the value is non-null. Default null means the U5 subscription filter is skipped."
  type        = string
  default     = null
}

variable "retention_days" {
  description = "Retention in days for the CloudWatch log groups created by this module (CloudTrail events, Firehose errors). 2557 days = 7 years, matching the PHIPA / PIPEDA retention guidance."
  type        = number
  default     = 2557
}

variable "object_lock_retention_days" {
  description = "Default Object Lock retention in days for the audit S3 bucket. 2557 days = 7 years. COMPLIANCE mode prevents root from deleting early."
  type        = number
  default     = 2557
}

variable "lifecycle_transition_days" {
  description = "Number of days after which objects in the audit S3 bucket transition to Glacier Instant Retrieval. The plan pins 90 days for cost without sacrificing retrieval latency."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Extra tags to apply to observability resources. The 3 required tags (Environment, DataClass, Owner) are added by the AWS provider's default_tags block in infra/providers.tf."
  type        = map(string)
  default     = {}
}
