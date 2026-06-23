###############################################################################
# modules/compute/outputs.tf
#
# Outputs for the compute plane. Consumed by the root module
# (main.tf) for the plan-output summary, by U8 (CI/CD) for the
# deploy job (image push + service update), and by U9 (runbooks)
# for cross-references.
#
# The ECR repository URL is the canonical input the U8 deploy job
# pushes images to. The Cognito User Pool ID + Client ID + issuer
# URL are the canonical inputs the sample app reads at boot.
###############################################################################

# ----------------------------------------------------------------------------
# ECR outputs.
# ----------------------------------------------------------------------------
output "ecr_repository_url" {
  description = "URL of the ECR repository the app image is pushed to. Consumed by U8's deploy job (docker push)."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository. Referenceable for cross-account policy attachments (reserved for future cross-account deploys)."
  value       = aws_ecr_repository.app.arn
}

output "ecr_repository_name" {
  description = "Name of the ECR repository."
  value       = aws_ecr_repository.app.name
}

# ----------------------------------------------------------------------------
# ECS outputs.
# ----------------------------------------------------------------------------
output "ecs_cluster_name" {
  description = "Name of the ECS Fargate cluster."
  value       = aws_ecs_cluster.this.name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS Fargate cluster. Referenceable for cluster-scoped IAM conditions."
  value       = aws_ecs_cluster.this.arn
}

output "ecs_service_name" {
  description = "Name of the ECS Fargate service. Consumed by U8's deploy job (aws ecs update-service)."
  value       = aws_ecs_service.app.name
}

output "ecs_service_arn" {
  description = "ARN of the ECS Fargate service."
  value       = aws_ecs_service.app.id
}

output "ecs_task_definition_arn" {
  description = "ARN of the most recent Fargate task definition. Referenceable for rollback operations."
  value       = aws_ecs_task_definition.app.arn
}

output "ecs_task_security_group_id" {
  description = "ID of the ECS task security group. U6 references this to tighten the RDS + RDS Proxy SG ingress (U7's fix-up to the U6 placeholder)."
  value       = aws_security_group.ecs_task.id
}

output "alb_target_group_arn" {
  description = "ARN of the U7 ALB target group. The U7 service registers to this group; the listener rule in service.tf forwards matching paths to it."
  value       = aws_lb_target_group.app.arn
}

output "alb_target_group_name" {
  description = "Name of the U7 ALB target group."
  value       = aws_lb_target_group.app.name
}

# ----------------------------------------------------------------------------
# IAM outputs.
# ----------------------------------------------------------------------------
output "ecs_task_role_arn" {
  description = "ARN of the U7 ECS task role (the runtime identity of the app). Distinct from the U4 cross-service role; same service boundary attached."
  value       = aws_iam_role.ecs_task_app.arn
}

output "ecs_task_role_name" {
  description = "Name of the U7 ECS task role."
  value       = aws_iam_role.ecs_task_app.name
}

output "ecs_execution_role_arn" {
  description = "ARN of the U7 ECS execution role (used by ECS to pull the image and write to CloudWatch Logs)."
  value       = aws_iam_role.ecs_exec.arn
}

# ----------------------------------------------------------------------------
# Cognito outputs.
# ----------------------------------------------------------------------------
output "cognito_user_pool_id" {
  description = "ID of the Cognito User Pool. The app's COGNITO_USER_POOL_ID env var."
  value       = aws_cognito_user_pool.this.id
}

output "cognito_user_pool_arn" {
  description = "ARN of the Cognito User Pool."
  value       = aws_cognito_user_pool.this.arn
}

output "cognito_user_pool_endpoint" {
  description = "Issuer endpoint of the Cognito User Pool. The app builds the issuer URL as the cognito_issuer_url output below."
  value       = aws_cognito_user_pool.this.endpoint
}

output "cognito_user_pool_client_id" {
  description = "ID of the Cognito User Pool Client. The app's COGNITO_CLIENT_ID env var (audience claim for JWT verification)."
  value       = aws_cognito_user_pool_client.this.id
}

output "cognito_user_pool_client_secret" {
  description = "Client secret of the Cognito User Pool Client. SENSITIVE. The app reads it from Secrets Manager at boot via the task definition's `secrets` block; the output is exposed here for runbook cross-references."
  value       = aws_cognito_user_pool_client.this.client_secret
  sensitive   = true
}

output "cognito_issuer_url" {
  description = "OIDC issuer URL for the User Pool. The app uses this as the `issuer` claim in JWT verification."
  value       = "${local.cognito_issuer_url}/${aws_cognito_user_pool.this.id}"
}

# ----------------------------------------------------------------------------
# Convenience URL.
# ----------------------------------------------------------------------------
output "app_url" {
  description = "Full URL of the sample app (the ALB DNS name). HTTPS, no path -- the app serves /healthz at the root."
  value       = "https://${var.alb_dns_name}"
}
