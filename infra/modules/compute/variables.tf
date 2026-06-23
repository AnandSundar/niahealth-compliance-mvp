###############################################################################
# modules/compute/variables.tf
#
# Inputs for the U7 compute plane. The compute module owns:
#   - ECR repository (image registry)
#   - ECS Fargate cluster + service + task definition
#   - Cognito User Pool + User Pool Client (the JWT issuer)
#   - IAM roles for the task (execution + runtime)
#   - Security group for the ECS tasks
#   - ALB target group + listener rule wiring the routes to Fargate
#
# Cross-module seams (the "what depends on what" map):
#   module.security.s3_phi_kms_key_arn    -> aws_ecr_repository.app.encryption_configuration.kms_key
#                                            (image encryption; PHI-classified
#                                             CMK keeps the encryption-key domain
#                                             consistent with the data the
#                                             image will process)
#   module.security.cwl_kms_key_arn       -> aws_cloudwatch_log_group.ecs_cluster
#                                            (cluster log group)
#   module.security.cognito_client_secret_arn
#                                          -> aws_ecs_task_definition.app.secrets
#                                            (the task definition passes the
#                                             client secret as a Secrets
#                                             Manager reference so it is
#                                             never baked into the image)
#   module.networking.vpc_id              -> aws_security_group.ecs_task.vpc_id
#                                            -> aws_lb_target_group.app.vpc_id
#   module.networking.isolated_subnet_ids -> aws_ecs_service.app.network_configuration.subnets
#   module.edge.alb_security_group_id     -> aws_security_group.ecs_task ingress
#   module.edge.alb_listener_https_arn    -> aws_lb_listener_rule.api
#                                            (U7 attaches the rule that
#                                             routes /health-summary/*,
#                                             /access-request, /delete-my-data
#                                             to the U7 target group)
#   module.identity.ecs_task_role_arn     -> (the canonical cross-service role;
#                                             not directly used -- the U7
#                                             task role is its own role with
#                                             the same boundary attached)
#   module.identity.service_boundary_arn  -> aws_iam_role.ecs_task_app.permissions_boundary
#                                            (blast-radius cap)
#   module.data.rds_proxy_endpoint        -> aws_ecs_task_definition.app env
#                                            (the app connects to the Proxy,
#                                             not the RDS instance)
#   module.data.data_bucket_name          -> (informational; the audit-bucket
#                                             name is consumed from the
#                                             observability module)
#   module.observability.audit_bucket_name-> aws_ecs_task_definition.app env
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

# ---------------------------------------------------------------------------
# Network placement.
# ---------------------------------------------------------------------------
variable "vpc_id" {
  description = "VPC ID where the ECS tasks and ALB target group live. Sourced from module.networking."
  type        = string
}

variable "isolated_subnet_ids" {
  description = "List of 3 isolated subnet IDs (no NAT, no IGW route) where the ECS tasks are placed. Sourced from module.networking."
  type        = list(string)
}

# ---------------------------------------------------------------------------
# Edge wiring.
# ---------------------------------------------------------------------------
variable "alb_security_group_id" {
  description = "Security group ID of the public ALB. Sourced from module.edge. The ECS task SG accepts ingress from this SG on the container port."
  type        = string
}

variable "alb_listener_arn" {
  description = "ARN of the HTTPS listener on the ALB. Sourced from module.edge. The U7 listener rule attaches to this listener."
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the public ALB. Sourced from module.edge. Used in the app_url output."
  type        = string
}

# ---------------------------------------------------------------------------
# CMKs.
# ---------------------------------------------------------------------------
variable "s3_phi_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts the ECR repository. Sourced from module.security. PHI-classified for encryption-key-domain consistency."
  type        = string
}

variable "cwl_kms_key_arn" {
  description = "ARN of the customer-managed CMK that encrypts the ECS cluster's CloudWatch Logs log group. Sourced from module.security."
  type        = string
}

# ---------------------------------------------------------------------------
# Data plane wiring.
# ---------------------------------------------------------------------------
variable "rds_proxy_endpoint" {
  description = "Endpoint of the RDS Proxy (NOT the RDS instance). Sourced from module.data. The app's RDS_PROXY_ENDPOINT env var."
  type        = string
}

variable "rds_db_name" {
  description = "Database name the app connects to. Sourced from module.data. The app's RDS_DB_NAME env var."
  type        = string
  default     = "niahealth"
}

variable "rds_db_user" {
  description = "Database user the app uses for IAM auth. The user must exist in the RDS Postgres role list; rotation is a U8+ concern."
  type        = string
  default     = "niahealth_app"
}

variable "rds_proxy_security_group_id" {
  description = "Security group ID of the RDS Proxy. Sourced from module.data. The RDS Proxy SG ingress is tightened in U7 to the ECS task SG (referenced as source_security_group_id)."
  type        = string
}

variable "rds_security_group_id" {
  description = "Security group ID of the RDS instance. Sourced from module.data. The RDS SG ingress is tightened in U7 to the ECS task SG (referenced as source_security_group_id)."
  type        = string
}

# ---------------------------------------------------------------------------
# Audit log wiring.
# ---------------------------------------------------------------------------
variable "audit_bucket_name" {
  description = "Name of the immutable audit S3 bucket. Sourced from module.observability. The app's AUDIT_BUCKET_NAME env var."
  type        = string
}

variable "s3_phi_bucket_name" {
  description = "Name of the data-tier PHI S3 bucket. Sourced from module.data. Reserved for a future ingest path; not consumed by the MVP routes."
  type        = string
}

# ---------------------------------------------------------------------------
# Secrets.
# ---------------------------------------------------------------------------
variable "cognito_client_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Cognito User Pool Client secret. Sourced from module.security. The task definition passes the secret value to the container as the COGNITO_CLIENT_SECRET env var via the `secrets` block."
  type        = string
}

# ---------------------------------------------------------------------------
# Identity plane.
# ---------------------------------------------------------------------------
variable "ecs_task_role_arn" {
  description = "ARN of the U4 canonical ECS task role. Sourced from module.identity. Not directly used as taskRoleArn (U7 has its own task role with the same boundary) -- carried for cross-module auditability."
  type        = string
}

variable "service_boundary_arn" {
  description = "ARN of the IAM policy used as a permission boundary for the U7 task role. Sourced from module.identity. Inherits the same blast-radius cap as the other service roles."
  type        = string
}

# ---------------------------------------------------------------------------
# Sizing tunables.
# ---------------------------------------------------------------------------
variable "fargate_cpu" {
  description = "Fargate task CPU units (1024 = 1 vCPU). 512 is the smallest non-trivial size for a FastAPI app."
  type        = number
  default     = 512
}

variable "fargate_memory" {
  description = "Fargate task memory (MiB). 1024 MiB is the minimum that pairs with 512 CPU."
  type        = number
  default     = 1024
}

variable "fargate_desired_count" {
  description = "Desired number of running Fargate tasks. 2 keeps the demo cost-conscious while providing redundancy."
  type        = number
  default     = 2
}

variable "fargate_min_count" {
  description = "Auto-scaling minimum task count. 2 keeps the demo always-on."
  type        = number
  default     = 2
}

variable "fargate_max_count" {
  description = "Auto-scaling maximum task count. 4 is a small ceiling for the demo."
  type        = number
  default     = 4
}

variable "container_port" {
  description = "Port the container listens on. Matches the port the Dockerfile EXPOSE-s and the port the ALB target group forwards to."
  type        = number
  default     = 8000
}

variable "app_image_tag" {
  description = "ECR image tag to deploy. 'latest' is the CI default; pinned tags are used for prod. Immutable tag mutation is enforced on the ECR repo so 'latest' cannot be overwritten -- a deploy must push a new tag and update this var."
  type        = string
  default     = "latest"
}

variable "cognito_callback_urls" {
  description = "OAuth2 callback URLs for the Cognito User Pool Client. The first entry is the OIDC redirect target after a successful sign-in."
  type        = list(string)
  default     = ["https://niahealth.example.com/oauth2/idpresponse"]
}

variable "cognito_logout_urls" {
  description = "OAuth2 sign-out URLs for the Cognito User Pool Client."
  type        = list(string)
  default     = ["https://niahealth.example.com/"]
}

variable "tags" {
  description = "Extra tags to apply to compute resources. The 3 required tags (Environment, DataClass, Owner) are added by the AWS provider's default_tags block in providers.tf."
  type        = map(string)
  default     = {}
}
