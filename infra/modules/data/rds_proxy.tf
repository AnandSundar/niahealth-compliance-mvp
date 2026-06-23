###############################################################################
# modules/data/rds_proxy.tf
# The RDS Proxy in front of the Postgres instance.
#
# Why an RDS Proxy (R5 / R9):
#   - Connection pooling: Postgres has a hard cap on concurrent
#     connections; Fargate tasks can spin up hundreds of
#     short-lived connections. The Proxy pools them to a small
#     number of long-lived backend connections.
#   - IAM auth: the Proxy assumes the rds_proxy_role from the
#     identity module and mints short-lived IAM auth tokens for
#     each connect. Clients never see the master password; the
#     Proxy retrieves it from Secrets Manager.
#   - TLS enforcement on the client side: require_tls = true means
#     the Proxy rejects any non-TLS connection attempt on the
#     client side. Combined with the parameter group's
#     rds.force_ssl = 1, this gives end-to-end TLS enforcement.
#
# Resources in this file:
#   - aws_security_group.rds_proxy        : the Proxy's SG; accepts
#                                            5432 ingress from the
#                                            isolated subnet CIDRs
#                                            (placeholder; U7 tightens
#                                            to the ECS task SG).
#   - aws_cloudwatch_log_group.rds_proxy  : the Proxy's CloudWatch
#                                            log group (CWL-encrypted).
#   - aws_db_proxy.rds                    : the Proxy itself.
#   - aws_db_proxy_default_target_group.rds
#                                          : the default target group
#                                            (connection_pool_timeout).
#   - aws_db_proxy_target.rds             : registers the RDS instance
#                                            as a target of the default
#                                            target group.
#
# Auth scheme: SECRETS (the Proxy retrieves the master password
# from Secrets Manager). Combined with iam_auth = REQUIRED, every
# connection must present a valid IAM token AND the Proxy holds
# the master credential. A leaked IAM token is short-lived (15 min
# by default); a leaked master password would require the secret
# itself to be exfiltrated.
###############################################################################

# ----------------------------------------------------------------------------
# RDS Proxy security group. Accepts 5432 ingress from the isolated
# subnet CIDRs (placeholder; U7 tightens to the ECS task SG).
# Egress is unrestricted (the Proxy initiates connections to the
# RDS instance in the database subnets; it does not initiate
# outbound to the internet).
# ----------------------------------------------------------------------------
resource "aws_security_group" "rds_proxy" {
  name        = local.rds_proxy_security_group_name
  description = "RDS Proxy SG for ${local.name_prefix}. Ingress 5432 from isolated subnet CIDRs (placeholder; tighten to ECS task SG in U7). Egress all."
  vpc_id      = var.vpc_id

  # Ingress: Postgres port from the isolated subnets (placeholder
  # -- see rds.tf for the same caveat about subnet IDs vs CIDRs).
  ingress {
    description = "Postgres from ECS task isolated subnets (placeholder; tighten to ECS task SG in U7)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # placeholder VPC CIDR; U7 replaces
  }

  egress {
    description = "Allow all egress (Proxy initiates connections to RDS instance)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name      = local.rds_proxy_security_group_name
    Purpose   = "rds-proxy-security-group"
    DataClass = "phi"
  })
}

# ----------------------------------------------------------------------------
# CloudWatch log group for the RDS Proxy logs. The Proxy logs
# connection attempts + IAM auth decisions; encrypted with the
# CWL CMK, 7-year retention matching the audit posture.
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "rds_proxy" {
  name              = local.rds_proxy_log_group
  retention_in_days = var.rds_log_retention_days
  kms_key_id        = var.cwl_kms_key_arn

  tags = merge(var.tags, {
    Name    = local.rds_proxy_log_group
    Purpose = "rds-proxy-logs"
  })
}

# ----------------------------------------------------------------------------
# The RDS Proxy.
#
# Auth: SECRETS + iam_auth = REQUIRED. The Proxy holds the master
# password (retrieved from Secrets Manager on every connect) AND
# mints IAM tokens for each client connect.
#
# Engine family: POSTGRESQL (case-sensitive in the v5 provider).
#
# TLS: require_tls = true on the client side. The Proxy also
# enforces TLS to the RDS instance on the backend (the Proxy's
# internal connection uses TLS regardless of the require_tls
# argument, but the require_tls argument controls the client
# side).
#
# Idle client timeout: 1800s (30 min) -- a client connection
# idle for more than 30 minutes is closed.
#
# Max connections percent: 90 -- the Proxy will use up to 90% of
# the engine's max_connections for its connection pool. The
# remaining 10% is reserved for direct connections (operator
# break-glass + the Proxy's own internal sessions).
#
# Connection pool timeout: 120s -- a client that waits more than
# 120s for a pooled backend connection is rejected. Bounds the
# tail latency under load.
# ----------------------------------------------------------------------------
resource "aws_db_proxy" "rds" {
  name                   = local.rds_proxy_name
  debug_logging          = false
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800
  require_tls            = true
  role_arn               = var.rds_proxy_role_arn
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]
  vpc_subnet_ids         = var.database_subnet_ids

  # Auth block. The `secret_arn` is the RDS master password secret
  # owned by the security module. `iam_auth = REQUIRED` means every
  # client must present a valid IAM auth token.
  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "REQUIRED"
    secret_arn  = var.rds_master_password_secret_arn
  }

  tags = merge(var.tags, {
    Name      = local.rds_proxy_name
    Purpose   = "rds-proxy"
    DataClass = "phi"
  })
}

# ----------------------------------------------------------------------------
# Default target group. The connection pool settings live here.
# The v5 provider uses a `connection_pool_config` block:
#   - connection_borrow_timeout : how long a client waits for a
#     pooled connection before being rejected (the plan's
#     "Connection pool timeout").
#   - max_connections_percent    : percentage of the engine's
#     max_connections the pool will use.
#   - max_idle_connections_percent : percentage of pool connections
#     kept idle.
# ----------------------------------------------------------------------------
resource "aws_db_proxy_default_target_group" "rds" {
  db_proxy_name = aws_db_proxy.rds.name

  connection_pool_config {
    # connection_borrow_timeout = 120 -> plan's "Connection pool timeout: 120s"
    connection_borrow_timeout = 120
    # max_connections_percent = 90 -> the plan's "Max connections percent: 90"
    max_connections_percent = 90
  }
}

# ----------------------------------------------------------------------------
# Register the RDS instance as a target of the default target
# group. The Proxy will route client connections to this instance.
# ----------------------------------------------------------------------------
resource "aws_db_proxy_target" "rds" {
  db_proxy_name          = aws_db_proxy.rds.name
  target_group_name      = aws_db_proxy_default_target_group.rds.name
  db_instance_identifier = aws_db_instance.rds.identifier
}