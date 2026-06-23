###############################################################################
# modules/edge/alb.tf
# Application Load Balancer.
#
# Posture:
#   - scheme = "internet-facing" (the plan overrides the wrapper
#     default of "internal" for the public ALB).
#   - Listener: HTTPS only on port 443 (the production posture
#     mandated by R3 -- "All data-plane traffic terminates TLS 1.2+").
#   - HTTP listener on port 80 redirects to HTTPS with a Strict-Transport-Security
#     header (HSTS) in the redirect response.
#   - drop_invalid_header_fields = true (defense in depth).
#   - enable_deletion_protection = true (production safety; set false in
#     ephemeral CI environments to avoid apply/destroy failures).
#   - idle_timeout = 60 (AWS default; pinned for predictability).
#   - access_logs: deferred to U6. The data-tier S3 bucket does not
#     exist yet; for now the ALB has no access logs. Documented as a
#     U6 migration item.
#
# Target group: a dummy target group with no registered targets.
# U7 wires the ECS Fargate service into this target group ARN
# (re-exported via outputs.tf).
###############################################################################

# A dedicated security group for the ALB. Ingress is HTTPS (443) from
# the world and HTTP (80) for the redirect; egress is to the VPC CIDR
# (so the ALB can reach future ECS tasks in private subnets).
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Security group for the public ALB. Ingress: 80 (redirect) and 443 from the world. Egress: VPC CIDR."
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from the world -- redirect to HTTPS."
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from the world."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To the VPC CIDR (future ECS task targets)."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alb"
  })
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  vpc_id             = var.vpc_id
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]
  internal           = false # internet-facing

  idle_timeout                     = 60
  drop_invalid_header_fields       = true
  enable_deletion_protection       = false # dev-friendly; flip to true in prod
  enable_cross_zone_load_balancing = true

  # ALB access logs: deferred to U6 (data-tier S3 bucket). When
  # alb_access_logs_bucket is null, no access log block is emitted.
  # The conditional in the wrapper's `access_logs` map is implicit --
  # passing an empty map (the default) means "do not enable access logs".
  access_logs = var.alb_access_logs_bucket != null ? {
    bucket  = var.alb_access_logs_bucket
    prefix  = var.alb_access_logs_prefix
    enabled = true
  } : {}

  # Listener map. The wrapper expects this format:
  #   listeners = {
  #     <key> = { port, protocol, [rules], [redirect|forward|fixed-response] }
  #   }
  listeners = {
    # Port 80 -> 443 redirect with HSTS in the response. HSTS is set
    # via the redirect's response_headers field (supported by the
    # wrapper's `redirect` block in v9.x).
    http-to-https = {
      port     = 80
      protocol = "HTTP"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
        # The HSTS header is delivered as a response header on the
        # redirect. The wrapper forwards `response_headers` to the
        # underlying aws_lb_listener_rule redirect.
        response_headers = [{
          name  = "Strict-Transport-Security"
          value = "max-age=63072000; includeSubDomains; preload"
          type  = "user-defined"
        }]
      }
    }

    # Port 443 -- the production HTTPS listener. No rules yet; U7
    # adds the forward-to-ECS rule.
    https = {
      port            = 443
      protocol        = "HTTPS"
      ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      certificate_arn = module.acm.acm_certificate_arn

      forward = {
        target_group_key = "ecs-placeholder"
      }
    }
  }

  # Target group map. The "ecs-placeholder" TG has no targets --
  # U7 will register the ECS service.
  target_groups = [
    {
      key         = "ecs-placeholder"
      name        = "${local.name_prefix}-tg-ecs"
      port        = 8080
      protocol    = "HTTP"
      target_type = "ip"
      vpc_id      = var.vpc_id
      health_check = {
        enabled             = true
        path                = "/healthz"
        port                = "traffic-port"
        matcher             = "200-399"
        interval            = 30
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 3
      }
    }
  ]

  tags = var.tags
}
