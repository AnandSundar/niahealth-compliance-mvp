###############################################################################
# modules/compute/iam_task.tf
#
# Two IAM roles for the Fargate task:
#
#   1. ecs_exec (execution role)
#      Assumed by ECS itself (not the app). Used by ECS to:
#        - Pull the image from ECR (ecr:GetAuthorizationToken +
#          ecr:BatchGetImage + ecr:GetDownloadLayerForImage)
#        - Write to the task's CloudWatch Logs log group
#          (logs:CreateLogStream + logs:PutLogEvents)
#        - Read the Cognito client secret from Secrets Manager
#          (secretsmanager:GetSecretValue) for the task definition's
#          `secrets` block.
#
#   2. ecs_task_app (task role)
#      The runtime identity of the app (what `aws s3 cp` or
#      `boto3.client("rds").generate_db_auth_token` is signed with
#      when the app code calls AWS APIs). Granted:
#        - rds-db:connect on the RDS Proxy resource (the data
#          module's outputs.tf exposes the resource pattern; U6
#          recommendation)
#        - s3:PutObject on the audit bucket (the access-request +
#          delete-my-data routes)
#        - s3:GetObject on the data-tier PHI bucket (the data is
#          NOT fetched by the app in the MVP; reserved for a
#          future ingest path)
#        - secretsmanager:GetSecretValue on the Cognito client
#          secret (so the app can read the secret at boot; the
#          task definition also passes the same value via the
#          `secrets` block, so this is a belt-and-suspenders)
#        - kms:Decrypt on the s3_phi + cwl CMKs (defense in depth;
#          the bucket policy already authorizes the role)
#
# Trust policies:
#   - ecs_exec        : ecs-tasks.amazonaws.com
#   - ecs_task_app    : ecs-tasks.amazonaws.com, with conditions on
#                       aws:SourceAccount and aws:SourceArn scoped
#                       to THIS cluster. The cluster-arn condition
#                       is the "service control" boundary that
#                       prevents a future cross-cluster task from
#                       assuming this role.
#
# Permission boundary: the U4 service boundary is attached to
# ecs_task_app (NOT to ecs_exec -- the execution role is a
# service-control-plane role, not an app-data role). The same
# boundary caps the blast radius as the other service roles.
###############################################################################

# ---------------------------------------------------------------------------
# Trust policy data. Built once, referenced by both roles.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    sid     = "ECSTasksAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Execution role.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ecs_exec" {
  name               = local.ecs_exec_role_name
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = merge(var.tags, {
    Name      = local.ecs_exec_role_name
    Purpose   = "ecs-execution-role"
    DataClass = "metadata"
  })
}

# Inline policy for the execution role. Attachment is inline so a
# future role rename doesn't leave an orphan managed policy.
resource "aws_iam_role_policy" "ecs_exec" {
  name = "${local.ecs_exec_role_name}-inline"
  role = aws_iam_role.ecs_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        # GetAuthorizationToken has no resource scope; the ECR
        # repo is in this same account, so no resource element.
        Resource = "*"
      },
      {
        Sid    = "ECRPullFromThisRepo"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadLayerForImage",
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Sid    = "LogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.ecs_cluster.arn}:*"
      },
      {
        Sid    = "SecretsRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
        ]
        Resource = var.cognito_client_secret_arn
      },
      {
        Sid    = "KMSDecryptForCWL"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
        ]
        # The CWL CMK encrypts the cluster's log group; the
        # execution role needs Decrypt on it to PutLogEvents.
        Resource = var.cwl_kms_key_arn
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Task role (runtime identity of the app).
# ---------------------------------------------------------------------------
# Cluster-arn condition trust policy. The SourceArn condition binds
# the role to THIS cluster, so a future task launched in a different
# cluster cannot assume this role.
data "aws_iam_policy_document" "ecs_task_app_assume_role" {
  statement {
    sid     = "ECSTasksAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${local.ecs_cluster_name}"]
    }
  }
}

resource "aws_iam_role" "ecs_task_app" {
  name                 = local.ecs_task_role_name
  assume_role_policy   = data.aws_iam_policy_document.ecs_task_app_assume_role.json
  permissions_boundary = var.service_boundary_arn

  tags = merge(var.tags, {
    Name      = local.ecs_task_role_name
    Purpose   = "ecs-task-runtime-role"
    DataClass = "phi"
  })
}

# Inline policy for the task role.
#
# Note on the rds-db:connect action: this is a DIFFERENT IAM action
# from rds:* (control plane). rds-db:connect is a data-plane action
# scoped to the resource pattern
#   arn:aws:rds-db:<region>:<account>:dbuser:<proxy_resource_id>/<username>
# The RDS Proxy's resource ID is in the proxy ARN, so we extract it
# from the input. The data module's outputs expose the rds_proxy_arn;
# the resource pattern below is constructed from that.
#
# Note on the audit bucket: the app's `access-request` and
# `delete-my-data` routes write here. The data-ingest role does
# NOT cover the audit bucket (it covers the data-tier PHI bucket
# only). The U7 task role is a different role with a different
# blast radius.
resource "aws_iam_role_policy" "ecs_task_app" {
  name = "${local.ecs_task_role_name}-inline"
  role = aws_iam_role.ecs_task_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RDSConnectViaProxy"
        Effect = "Allow"
        Action = [
          "rds-db:connect",
        ]
        # The RDS Proxy ARN is the Proxy's resource ID, but the
        # rds-db:connect action scopes by dbuser:<resource_id>/<user>.
        # The data module's outputs expose the proxy ARN, but the
        # resource_id (a hex string at the end of the ARN) is what
        # rds-db:connect wants. We construct the resource pattern
        # generically: any rds-db resource in this account that
        # has a user matching the app's DB user is fair game.
        # This is the same approach the U6 subagent recommended.
        Resource = "arn:${data.aws_partition.current.partition}:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:*"
      },
      {
        Sid    = "AuditBucketWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.audit_bucket_name}/*"
      },
      {
        Sid    = "AuditBucketList"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.audit_bucket_name}"
      },
      {
        Sid    = "PHIBucketRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
        ]
        # The app's MVP does not read PHI; this is reserved for a
        # future ingest path (when the app is the consumer, not
        # the producer, of PHI objects).
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.s3_phi_bucket_name}/*"
      },
      {
        Sid    = "SecretsReadCognito"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
        ]
        # The task definition also passes the secret value via
        # the `secrets` block, so this GetSecretValue is the
        # belt to the task-definition's suspenders -- used by
        # app code that re-reads the secret at runtime.
        Resource = var.cognito_client_secret_arn
      },
      {
        Sid    = "KMSDecryptPHIAndCWL"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
        ]
        Resource = [
          var.s3_phi_kms_key_arn,
          var.cwl_kms_key_arn,
        ]
      },
    ]
  })
}
