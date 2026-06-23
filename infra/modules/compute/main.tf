###############################################################################
# modules/compute/main.tf
#
# The "compute" module owns the U7 sample-app plane:
#
#   - cluster.tf       : the ECS Fargate cluster + cluster-level
#                        CloudWatch log group (CWL-encrypted).
#   - ecs.tf           : the Fargate service, security group,
#                        ALB target group, listener rule, and
#                        auto-scaling target + step scaling policy.
#   - task.tf          : the Fargate task definition (with the
#                        readonly root FS + non-root user + secrets
#                        from Secrets Manager).
#   - iam_task.tf      : the execution role (image pull, log writes,
#                        secret reads) and the runtime task role
#                        (RDS Connect + audit-bucket write + secret
#                        read for the Cognito client secret).
#   - ecr.tf           : the immutable, scanning-on-push, PHI-CMK-
#                        encrypted container registry.
#   - cognito.tf       : the Cognito User Pool + User Pool Client +
#                        User Pool Domain + clinicians group. The
#                        OIDC issuer for the sample app's JWT
#                        verification.
#
# Naming convention: ${local.name_prefix}-<purpose> where
# name_prefix = "${var.project_name}-${var.environment}".
#
# All resources flow through the AWS provider's default_tags block
# (infra/providers.tf) so the 3 required tags (Environment, DataClass,
# Owner) are applied automatically.
#
# DataClass for compute resources:
#   - ECR repo                 : "metadata" (the image is code, not PHI)
#   - ECS cluster + task def   : "metadata" (the compute is code, not PHI)
#   - ECS service              : "metadata" (the service runs code)
#   - Cognito User Pool        : "metadata" (identity records are
#                                metadata, not PHI on their own; PHI is
#                                in the data tier)
#   - ECR task role            : "phi" (the role can write to the
#                                audit bucket; defensively tagged phi
#                                so a missing tag fails the conftest
#                                policy at the right boundary)
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Canonical resource names. Following the convention set by the
  # other modules so a single grep reveals the full name.
  ecr_repo_name          = "${local.name_prefix}-app"
  ecs_cluster_name       = "${local.name_prefix}-cluster"
  ecs_service_name       = "${local.name_prefix}-app-service"
  ecs_task_family        = "${local.name_prefix}-app"
  ecs_task_sg_name       = "${local.name_prefix}-ecs-task-sg"
  ecs_target_group_name  = "${local.name_prefix}-tg-app"
  ecs_log_group          = "/ecs/${local.name_prefix}/app"
  ecs_cluster_log_group  = "/ecs/${local.name_prefix}/cluster"
  ecs_exec_role_name     = "${local.name_prefix}-ecs-exec-role"
  ecs_task_role_name     = "${local.name_prefix}-ecs-task-role-app"
  cognito_user_pool_name = "${local.name_prefix}-user-pool"
  cognito_domain_prefix  = replace(local.name_prefix, "_", "-")

  # OIDC issuer URL for JWT verification. The app's auth.py builds
  # the same string from COGNITO_USER_POOL_ID + AWS_REGION; the
  # output is exposed here for runbook cross-references.
  cognito_issuer_url = "https://cognito-idp.${var.region}.amazonaws.com"
}
