###############################################################################
# modules/compute/task.tf
#
# The Fargate task definition.
#
# Security posture (per the plan + Checkov hard-fail IDs):
#   - network_mode = "awsvpc"     : required for Fargate; each task
#                                    gets an ENI in the isolated
#                                    subnets.
#   - readonly_root_filesystem = true  : CKV_AWS_339. Combined with
#                                    the non-root user in the
#                                    Dockerfile, this is the
#                                    container-hardening baseline.
#   - user = "10001:10001"  : the non-root user created by the
#                                    Dockerfile. Pinning the UID
#                                    means the in-container user is
#                                    deterministic across builds.
#   - log KMS key = CWL CMK  : the log group is created in
#                                    cluster.tf and encrypted with
#                                    the CWL CMK; the task
#                                    definition points at it. ECS
#                                    does NOT manage the log
#                                    group; the task definition
#                                    creates log streams inside it.
#
# Container environment:
#   - Plain env vars   : AWS_REGION, RDS_PROXY_ENDPOINT,
#                        RDS_DB_NAME, RDS_DB_USER,
#                        COGNITO_USER_POOL_ID, COGNITO_CLIENT_ID,
#                        COGNITO_ISSUER_URL, AUDIT_BUCKET_NAME,
#                        GIT_SHA, BUILD_TIMESTAMP.
#   - Secrets          : COGNITO_CLIENT_SECRET sourced from
#                        Secrets Manager via the `secrets` block.
#                        The secret value is mounted as an env
#                        var at container start, NEVER baked
#                        into the image.
#
# Health check: in-container curl /healthz. The /healthz route is
# unauthenticated and returns build metadata; ECS uses it to
# decide when the task is ready to receive ALB traffic.
###############################################################################

resource "aws_ecs_task_definition" "app" {
  family                   = local.ecs_task_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.fargate_cpu)
  memory                   = tostring(var.fargate_memory)
  execution_role_arn       = aws_iam_role.ecs_exec.arn
  task_role_arn            = aws_iam_role.ecs_task_app.arn

  # Ephemeral tmp volume for the non-root user. Required because
  # the root filesystem is read-only (CKV_AWS_339) and the user
  # needs somewhere to write (uvicorn's pid file, pip cache, etc.).
  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.app.repository_url}:${var.app_image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      # CKV_AWS_339: read-only root filesystem.
      readonlyRootFilesystem = true

      # Non-root user. The Dockerfile creates the matching UID.
      user = "10001:10001"

      # Health check: in-container curl /healthz. CKV_AWS_339 does
      # not require this; it is defense-in-depth.
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      # Mount the tmp volume to /tmp so the non-root user has a
      # writable scratch space.
      mountPoints = [
        {
          sourceVolume  = "tmp"
          containerPath = "/tmp"
          readOnly      = false
        }
      ]

      # Plain environment variables. These are NOT secrets.
      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "RDS_PROXY_ENDPOINT", value = var.rds_proxy_endpoint },
        { name = "RDS_DB_NAME", value = var.rds_db_name },
        { name = "RDS_DB_USER", value = var.rds_db_user },
        { name = "COGNITO_USER_POOL_ID", value = aws_cognito_user_pool.this.id },
        { name = "COGNITO_CLIENT_ID", value = aws_cognito_user_pool_client.this.id },
        { name = "COGNITO_ISSUER_URL", value = "${local.cognito_issuer_url}/${aws_cognito_user_pool.this.id}" },
        { name = "AUDIT_BUCKET_NAME", value = var.audit_bucket_name },
        # Build metadata; passed by the CI build job (U8).
        { name = "GIT_SHA", value = "unknown" },
        { name = "BUILD_TIMESTAMP", value = "unknown" },
      ]

      # Secrets: the Cognito client secret. ECS retrieves the value
      # from Secrets Manager at task start; the value is mounted
      # as the COGNITO_CLIENT_SECRET env var. Never baked into the
      # image. The execution role is granted GetSecretValue on
      # this secret in iam_task.tf.
      secrets = [
        {
          name      = "COGNITO_CLIENT_SECRET"
          valueFrom = var.cognito_client_secret_arn
        }
      ]

      # Log configuration. The log group is pre-created in
      # cluster.tf; awslogs-create-group is FALSE so ECS does not
      # try to create a duplicate. CKV_AWS_163 is satisfied
      # because the log group has the CWL CMK attached.
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = local.ecs_log_group
          awslogs-region        = var.region
          awslogs-stream-prefix = "app"
        }
        secretOptions = []
      }
    }
  ])

  # The container image is metadata; the data the image processes
  # is PHI. DataClass = "metadata" on the task definition is the
  # right classification for the artifact itself.
  tags = merge(var.tags, {
    Name      = local.ecs_task_family
    Purpose   = "fargate-task-definition"
    DataClass = "metadata"
  })
}

# Pre-create the per-task log group so the CWL CMK encryption is
# applied at create-time. The task definition points at this
# group; awslogs-create-group is FALSE on the container def so
# ECS does not race against this create.
resource "aws_cloudwatch_log_group" "ecs_app" {
  name              = local.ecs_log_group
  retention_in_days = 2557
  kms_key_id        = var.cwl_kms_key_arn

  tags = merge(var.tags, {
    Name    = local.ecs_log_group
    Purpose = "ecs-app-logs"
  })
}
