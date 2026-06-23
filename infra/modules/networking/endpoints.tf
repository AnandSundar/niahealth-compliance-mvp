###############################################################################
# modules/networking/endpoints.tf
# VPC endpoints for AWS service APIs the private and isolated tiers call.
#
# Goal: private and isolated subnets MUST reach AWS services (S3, KMS,
# Secrets Manager, ECR, CloudWatch Logs, Monitoring) without traversing
# the public internet. Each interface endpoint creates an ENI in the
# private subnets; the S3 endpoint is a gateway endpoint (free) that
# attaches to the private route table.
#
# Endpoint list (per plan U3):
#   Interface (ENI in private subnets):
#     - kms
#     - secretsmanager
#     - ecr.api
#     - ecr.dkr
#     - logs        (CloudWatch Logs)
#     - monitoring  (CloudWatch Monitoring)
#   Gateway (route table entry, no ENI):
#     - s3
#
# SG wiring: the v5 wrapper's vpc-endpoints submodule creates a
# placeholder SG by default. The plan tells us to "leave the SG wiring
# loose for now -- U7 will tighten it" (when the ECS task SG is known).
# We accept the wrapper's default SG behaviour, which is "open to
# the VPC CIDR", and add a TODO marker for U7.
###############################################################################

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id = module.vpc.vpc_id

  # Per-endpoint configuration. The wrapper's `endpoints` map accepts
  # one entry per service. Service names use the AWS-canonical
  # com.amazonaws.<region>.<service> form, which the wrapper resolves
  # to a service_name when the user passes a short alias.
  endpoints = {
    s3 = {
      service      = "s3"
      service_type = "Gateway"
      route_table_ids = concat(
        module.vpc.private_route_table_ids,
        module.vpc.database_route_table_ids,
      )
      tags = { Name = "${local.name_prefix}-vpce-s3" }
    }

    kms = {
      service             = "kms"
      vpc_endpoint_type   = "Interface"
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = []
      private_dns_enabled = true
      tags                = { Name = "${local.name_prefix}-vpce-kms" }
    }

    secretsmanager = {
      service             = "secretsmanager"
      vpc_endpoint_type   = "Interface"
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = []
      private_dns_enabled = true
      tags                = { Name = "${local.name_prefix}-vpce-secretsmanager" }
    }

    ecr_api = {
      service             = "ecr.api"
      vpc_endpoint_type   = "Interface"
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = []
      private_dns_enabled = true
      tags                = { Name = "${local.name_prefix}-vpce-ecr-api" }
    }

    ecr_dkr = {
      service             = "ecr.dkr"
      vpc_endpoint_type   = "Interface"
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = []
      private_dns_enabled = true
      tags                = { Name = "${local.name_prefix}-vpce-ecr-dkr" }
    }

    logs = {
      service             = "logs"
      vpc_endpoint_type   = "Interface"
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = []
      private_dns_enabled = true
      tags                = { Name = "${local.name_prefix}-vpce-logs" }
    }

    monitoring = {
      service             = "monitoring"
      vpc_endpoint_type   = "Interface"
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = []
      private_dns_enabled = true
      tags                = { Name = "${local.name_prefix}-vpce-monitoring" }
    }
  }

  tags = var.tags
}
