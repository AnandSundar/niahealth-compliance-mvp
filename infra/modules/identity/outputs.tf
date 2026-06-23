###############################################################################
# modules/identity/outputs.tf
#
# Outputs the 4 service role ARNs (consumed by U6 data tier and
# U7 sample app), the break-glass user ARN (runbook reference), the
# Access Analyzer ARN (U5 logging + U9 runbook), the IdC instance
# ARN (audit reference), and the permission boundary ARN (used by
# future roles created elsewhere in the codebase to enforce the
# same boundary).
###############################################################################

output "ecs_task_role_arn" {
  description = "ARN of the ECS Fargate task role. Consumed by U7's task definition as taskRoleArn."
  value       = aws_iam_role.ecs_task_role.arn
}

output "ecs_task_role_name" {
  description = "Name of the ECS Fargate task role. Useful for IAM policy attachment references and runbook scoping."
  value       = aws_iam_role.ecs_task_role.name
}

output "rds_proxy_role_arn" {
  description = "ARN of the RDS Proxy IAM auth role. Consumed by U6's RDS Proxy when iam_auth_enabled = true."
  value       = aws_iam_role.rds_proxy_role.arn
}

output "rds_proxy_role_name" {
  description = "Name of the RDS Proxy IAM auth role."
  value       = aws_iam_role.rds_proxy_role.name
}

output "firehose_role_arn" {
  description = "ARN of the Kinesis Firehose delivery role. Consumed by U5's Firehose-to-S3 audit pipeline."
  value       = aws_iam_role.firehose_role.arn
}

output "firehose_role_name" {
  description = "Name of the Kinesis Firehose delivery role."
  value       = aws_iam_role.firehose_role.name
}

output "lambda_rotation_role_arn" {
  description = "ARN of the Lambda rotation function's execution role. Consumed by the Secrets Manager rotation configuration in the security module."
  value       = aws_iam_role.lambda_rotation_role.arn
}

output "lambda_rotation_role_name" {
  description = "Name of the Lambda rotation function's execution role."
  value       = aws_iam_role.lambda_rotation_role.name
}

output "service_boundary_arn" {
  description = "ARN of the IAM policy used as a permission boundary for every service role. Exposed so future roles (U5+, any new service) can attach the same boundary for consistent blast-radius capping."
  value       = aws_iam_policy.service_boundary.arn
}

output "break_glass_user_arn" {
  description = "ARN of the single break-glass IAM user. Referenceable in the U9 incident response runbook."
  value       = aws_iam_user.break_glass.arn
}

output "break_glass_user_name" {
  description = "Name of the single break-glass IAM user. Used by the printed-envelope script (infra/scripts/break-glass-envelope.sh.tpl) and the EventBridge paging rule."
  value       = aws_iam_user.break_glass.name
}

output "break_glass_password_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the break-glass user's console password. The orchestrator retrieves this with aws secretsmanager get-secret-value during envelope printing."
  value       = aws_secretsmanager_secret.break_glass_password.arn
}

output "access_analyzer_arn" {
  description = "ARN of the IAM Access Analyzer. U5 indexes the analyzer's findings; U9 documents the weekly review in the runbook."
  value       = aws_accessanalyzer_analyzer.this.arn
}

output "idc_instance_arn" {
  description = "ARN of the IAM Identity Center instance for this account. Empty list when IdC is not yet enabled (Terraform cannot create the instance; the human runs a one-time Console step)."
  value       = try(data.aws_ssoadmin_instances.this.arns[0], null)
}

output "permission_set_arns" {
  description = "Map of permission-set name -> ARN. Referenceable from group-assignment resources added by U9 onboarding playbooks."
  value = {
    admin     = aws_ssoadmin_permission_set.admin.arn
    developer = aws_ssoadmin_permission_set.developer.arn
    auditor   = aws_ssoadmin_permission_set.auditor.arn
    deploy    = aws_ssoadmin_permission_set.deploy.arn
  }
}

output "paging_sns_topic_arn" {
  description = "ARN of the SNS topic that the EventBridge rule pages on break-glass console sign-in. Consumed by U9's on-call rotation."
  value       = aws_sns_topic.break_glass_paging.arn
}