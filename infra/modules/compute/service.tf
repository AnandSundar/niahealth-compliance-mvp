###############################################################################
# modules/compute/service.tf
#
# The Fargate service, its security group, the ALB target group,
# the listener rule, and the auto-scaling target + tracking policy.
#
# SG posture:
#   - Ingress: from the ALB SG on the container port. The ALB
#     SG is the ONLY source -- the SG is NOT open to the VPC
#     CIDR. (Defense in depth: the ALB already enforces
#     WAFv2 + Cognito JWT at the application layer; the SG
#     enforces the network-layer boundary.)
#   - Egress: all. The task needs to reach Secrets Manager
#     (via the VPC endpoint from U3), ECR (via the VPC endpoint),
#     KMS (via the VPC endpoint), and the RDS Proxy (private IP
#     in the same VPC).
#
# Target group:
#   - target_type = "ip"  : Fargate tasks get a static ENI IP;
#                            the TG registers the IP, not an
#                            instance ID.
#   - health_check.path = "/healthz"  : the unauthenticated
#                            liveness probe.
#
# Listener rule:
#   - priority = 100  : the edge module's placeholder TG rule
#                       is the default forward; 100 is a higher
#                       number that wins the priority sort only
#                       when the path matches.
#   - Forward to the U7 TG (not the U3 placeholder). The U3
#                       placeholder never receives traffic in this
#                       design -- it exists only so the ALB has
#                       a default forward target until U7 lands.
#
# Auto-scaling: target tracking on ECS service average CPU at
# 60%. Bounds: var.fargate_min_count .. var.fargate_max_count.
###############################################################################

# ---------------------------------------------------------------------------
# ECS task security group.
# ---------------------------------------------------------------------------
resource "aws_security_group" "ecs_task" {
  name        = local.ecs_task_sg_name
  description = "ECS Fargate task SG for ${local.name_prefix}. Ingress: container port from ALB SG. Egress: all (Secrets Manager / ECR / KMS via VPC endpoints; RDS Proxy via private IP)."
  vpc_id      = var.vpc_id

  ingress {
    description     = "Container port from ALB SG (the only source)"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  egress {
    description = "Allow all egress (VPC endpoints + RDS Proxy in the same VPC)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name      = local.ecs_task_sg_name
    Purpose   = "ecs-task-security-group"
    DataClass = "metadata"
  })
}

# ---------------------------------------------------------------------------
# ALB target group.
# ---------------------------------------------------------------------------
resource "aws_lb_target_group" "app" {
  name        = local.ecs_target_group_name
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    path                = "/healthz"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # No stickiness for the MVP; a sticky session would be a U8+ concern.
  tags = merge(var.tags, {
    Name      = local.ecs_target_group_name
    Purpose   = "ecs-app-target-group"
    DataClass = "metadata"
  })
}

# ---------------------------------------------------------------------------
# Listener rule. The U3 placeholder TG exists so the ALB has a
# default forward target; U7 adds this higher-priority rule that
# matches the API paths and forwards to the U7 TG.
#
# Note: this rule is in ADDITION to the U3 default forward. Both
# rules coexist; the path-pattern rule wins for matching requests
# and the default forwards everything else to the U3 placeholder.
# ---------------------------------------------------------------------------
resource "aws_lb_listener_rule" "api" {
  listener_arn = var.alb_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    path_pattern {
      values = [
        "/health-summary/*",
        "/access-request",
        "/access-request/*",
        "/delete-my-data",
        "/delete-my-data/*",
      ]
    }
  }

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-api-listener-rule"
    Purpose = "route-api-to-fargate"
  })
}

# ---------------------------------------------------------------------------
# ECS service.
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name             = local.ecs_service_name
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.app.arn
  launch_type      = "FARGATE"
  desired_count    = var.fargate_desired_count
  platform_version = "LATEST"

  # Auto-rollback on failed deploys. Defense-in-depth.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.isolated_subnet_ids
    security_groups  = [aws_security_group.ecs_task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  tags = merge(var.tags, {
    Name      = local.ecs_service_name
    Purpose   = "fargate-service"
    DataClass = "metadata"
  })

  # Ignore changes to desired_count -- the auto-scaling target
  # controls this in production. Prevents a perpetual diff when
  # the ASG scales the service.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ---------------------------------------------------------------------------
# Auto-scaling.
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_target" "app" {
  max_capacity       = var.fargate_max_count
  min_capacity       = var.fargate_min_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# Target tracking: scale to keep average CPU at 60%.
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.ecs_service_name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  service_namespace  = aws_appautoscaling_target.app.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
