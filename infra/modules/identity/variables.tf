###############################################################################
# modules/identity/variables.tf
#
# Inputs for the identity plane. The 3 required tags (Environment,
# DataClass, Owner) are added by the AWS provider's default_tags block
# in infra/providers.tf; the `tags` input here is for module-local
# extras (Project, ManagedBy, CostCenter).
#
# CMK ARNs come from the security module; the OIDC provider ARN comes
# from the landing module. These cross-module inputs are the seam
# between U3 (KMS + OIDC) and U4 (identity).
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

variable "github_org" {
  description = "GitHub organization that owns the deploy workflow. Pinned in the IdC permission set metadata."
  type        = string
  default     = "niahealth"
}

variable "github_repo" {
  description = "GitHub repository that owns the deploy workflow. Pinned in the IdC permission set metadata."
  type        = string
  default     = "niahealth-compliance-mvp"
}

variable "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider. Referenceable from the ECS task role's trust policy when the task uses web identity for downstream calls. Comes from module.landing."
  type        = string
}

variable "rds_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts RDS Postgres. Consumed by the rds-proxy-role for kms:Decrypt + kms:GenerateDataKey."
  type        = string
}

variable "s3_phi_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts the PHI S3 bucket. Consumed by the ecs-task-role for kms:Decrypt on PHI objects."
  type        = string
}

variable "cloudtrail_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts CloudTrail log files. Consumed by the firehose-role for kms:Decrypt on the audit bucket's objects."
  type        = string
}

variable "cwl_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts CloudWatch Logs log groups. Consumed by the ecs-task-role for kms:Encrypt when the app writes structured logs."
  type        = string
}

variable "rds_master_password_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RDS master password. Owned by the security module and passed in by the root. Referenced by the ECS task role + Lambda rotation role inline policies."
  type        = string
}

variable "cognito_client_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Cognito client secret. Owned by the security module and passed in by the root. Referenced by the ECS task role inline policy."
  type        = string
}

variable "tags" {
  description = "Extra tags to apply to identity resources. The 3 required tags (Environment, DataClass, Owner) are added by the AWS provider's default_tags block in providers.tf."
  type        = map(string)
  default     = {}
}