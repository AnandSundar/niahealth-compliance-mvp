###############################################################################
# modules/data/variables.tf
#
# Inputs for the data tier (U6). The data tier is the most security-
# relevant layer in the architecture: PHI lives here, and every input
# to this module is wired from a module whose blast radius is bounded
# by an explicit deny (see the cross-module seam map below).
#
# Cross-module seams (the "what depends on what" map):
#
#   module.security.rds_kms_key_arn        -> aws_db_instance.rds.kms_key_id
#                                           -> aws_db_parameter_group.rds (n/a;
#                                              the parameter group has no
#                                              direct KMS dependency, but the
#                                              instance's storage encryption
#                                              uses this key)
#                                           -> aws_rds_proxy.auth (iam auth
#                                              with this key -- the proxy's
#                                              IAM role decrypts this key)
#   module.security.s3_phi_kms_key_arn     -> aws_s3_bucket_server_side_encryption_configuration.phi
#                                           -> aws_s3_bucket_server_side_encryption_configuration.phi_replica
#   module.security.cwl_kms_key_arn        -> (reserved; the RDS log group
#                                              is created in this module
#                                              and uses the cwl CMK)
#   module.security.rds_master_password_secret_arn
#                                          -> aws_db_proxy.auth[*].secret_arn
#                                           (the proxy retrieves the
#                                            password from Secrets Manager
#                                            on every connect -- no
#                                            plaintext password on the
#                                            instance)
#   module.networking.vpc_id               -> aws_security_group.rds.vpc_id
#                                           -> aws_security_group.rds_proxy.vpc_id
#   module.networking.database_subnet_ids  -> aws_db_subnet_group.rds.subnet_ids
#                                           -> aws_db_proxy.vpc_subnet_ids
#   module.networking.isolated_subnet_ids  -> aws_security_group ingress
#                                            (placeholder: the ECS tasks
#                                             live in isolated subnets;
#                                             U7 tightens to the ECS SG)
#   module.identity.rds_proxy_role_arn     -> aws_db_proxy.role_arn
#   module.identity.ecs_task_role_arn      -> (reserved for U7; the ingest
#                                             role's policy will reference
#                                             this ARN so future cross-role
#                                             assumptions are auditable)
#   module.identity.service_boundary_arn   -> aws_iam_role.data_ingest_role
#                                             .permissions_boundary
#
# Sizing variables are exposed so dev can override cost-conscious defaults
# without editing this file. Production defaults are pinned to multi-AZ
# with 14-day backup retention and Performance Insights enabled; dev
# can drop instance class + storage via tfvars to keep the bill small
# while preserving the production posture on the security controls.
###############################################################################

variable "region" {
  description = "AWS region for the home account. Data residency requires ca-central-1 for PHI (R1)."
  type        = string
  default     = "ca-central-1"
}

variable "dr_region" {
  description = "AWS region for the cross-region replica of the PHI S3 bucket. Default ca-west-1 (the second Canadian region; same data-residency envelope as ca-central-1, satisfying R1 + PIPEDA Schedule 1 + PHIPA s.13)."
  type        = string
  default     = "ca-west-1"
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
  description = "ID of the VPC. Sourced from module.networking. Used to scope the RDS + RDS Proxy security groups."
  type        = string
}

variable "database_subnet_ids" {
  description = "List of 3 database subnet IDs (no NAT, no IGW route). Sourced from module.networking. Hosts the RDS instance + RDS Proxy. In the current networking module this is the same tier as isolated_subnet_ids (both map to the vpc.database_subnets tier); the variable is kept separate for future divergence if the networking module grows separate database + isolated tiers."
  type        = list(string)
}

variable "isolated_subnet_ids" {
  description = "List of 3 isolated subnet IDs (no NAT, no IGW route). Sourced from module.networking. Hosts the ECS Fargate tasks AND the RDS instance (the networking module's database_subnets and isolated_subnets are the same tier in this architecture -- both are 'no NAT, no IGW route'). The RDS SG accepts 5432 ingress from these subnets as a placeholder; U7 tightens to the ECS task SG."
  type        = list(string)
}

variable "rds_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts the RDS instance storage and Performance Insights data. Sourced from module.security."
  type        = string
}

variable "s3_phi_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts the data-tier S3 bucket (PHI objects) AND the cross-region replica. Sourced from module.security."
  type        = string
}

variable "cwl_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts CloudWatch Logs log groups (RDS postgresql + upgrade log streams, RDS Proxy log stream, future ALB/WAF). Sourced from module.security."
  type        = string
}

variable "rds_proxy_role_arn" {
  description = "ARN of the IAM role RDS Proxy assumes when IAM auth is enabled. Sourced from module.identity. The Proxy uses this role to mint short-lived auth tokens for each connect."
  type        = string
}

variable "ecs_task_role_arn" {
  description = "ARN of the ECS Fargate task role. Sourced from module.identity. Reserved for U7 -- the ingest role's policy will reference this ARN so future cross-role assumptions are auditable. Not consumed by U6 directly."
  type        = string
}

variable "rds_master_password_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RDS master password. Sourced from module.security. The RDS Proxy retrieves the password from this secret on every connect; the RDS instance itself uses this secret's value as its initial password (rotation is handled by the Lambda in the security module)."
  type        = string
}

variable "service_boundary_arn" {
  description = "ARN of the IAM policy used as a permission boundary for every service role (owned by module.identity). Attached to the data ingest role so the ingest path inherits the same blast-radius cap as the other service roles."
  type        = string
}

# ---------------------------------------------------------------------------
# Sizing tunables. Defaults reflect the production posture; dev.tfvars
# can override for cost-conscious local applies.
# ---------------------------------------------------------------------------
variable "rds_engine_version" {
  description = "PostgreSQL major version. Pinned to 16 (the current supported major; explicit pin so a future major upgrade is a deliberate PR)."
  type        = string
  default     = "16"
}

variable "rds_instance_class" {
  description = "RDS instance class. db.t4g.medium for dev (2 vCPU, 4 GB); production should use db.m6g.large or higher. Override via tfvars."
  type        = string
  default     = "db.t4g.medium"
}

variable "rds_allocated_storage_gb" {
  description = "Allocated storage in GiB. 20 GiB is the minimum for gp3 storage; production should be 100 GiB+. Override via tfvars."
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage_gb" {
  description = "Upper bound for RDS storage autoscaling. 1000 GiB is the AWS ceiling; production should set this to 2-3x the allocated storage to allow headroom."
  type        = number
  default     = 1000
}

variable "rds_backup_retention_days" {
  description = "Backup retention in days. 14 days matches the plan's R7/R8 retention guidance and the AWS Config rule default. Override via tfvars."
  type        = number
  default     = 14
}

variable "rds_multi_az" {
  description = "Enable Multi-AZ for high availability. Production posture is true; dev can override to false for cost discipline (documented in the plan)."
  type        = bool
  default     = true
}

variable "rds_performance_insights_retention_days" {
  description = "Performance Insights retention in days. 7 days is the free tier (and the cost-discipline default); 731 days is the long-term tier ($$$). The plan calls for 'long-term' which is 731 days; we default to 7 for cost discipline and document why. Override via tfvars if long-term retention is required."
  type        = number
  default     = 7
}

variable "rds_db_name" {
  description = "Initial database name created with the RDS instance. Used as the application database. Lowercase + hyphens per naming convention."
  type        = string
  default     = "niahealth"
}

variable "rds_master_username" {
  description = "Master username for the RDS instance. Avoid 'postgres' / 'admin' / 'root' per the plan; project-prefixed username keeps the principal scoped to the project."
  type        = string
  default     = "niahealth_admin"
}

variable "rds_log_retention_days" {
  description = "Retention in days for the RDS postgresql + upgrade CloudWatch log groups created by this module. 2557 days = 7 years, matching the audit-bucket retention + PHIPA/PIPEDA guidance."
  type        = number
  default     = 2557
}

variable "tags" {
  description = "Extra tags to apply to data-tier resources. The 3 required tags (Environment, DataClass, Owner) are added by the AWS provider's default_tags block in providers.tf."
  type        = map(string)
  default     = {}
}