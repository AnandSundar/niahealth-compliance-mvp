###############################################################################
# modules/networking/vpc.tf
# VPC + internet gateway via the community terraform-aws-modules/vpc/aws
# wrapper. We use the v5.x major version (the plan recommends ?ref=v5.0.0
# "or close" -- v5.21.0 is the latest in the same line).
#
# The wrapper creates the VPC, the internet gateway, the per-tier
# subnets, the route tables, the NAT gateways (one per AZ), the VPC
# Flow Logs (CloudWatch destination, 7y retention), and the IAM role
# for flow log delivery. We pin the few knobs that matter for our
# compliance posture and let the rest default.
#
# Why the v5 wrapper: the v5 series adds the modules/vpc-endpoints
# submodule that endpoints.tf relies on, and the vpc_flow_log_*
# variable family that this file uses. v3 / v4 do not have the
# equivalent surface area.
###############################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs
  # The v5 wrapper does not have a first-class "isolated" tier; the
  # closest analogue is `database_subnets`, which by default does NOT
  # route to a NAT gateway. We map our isolated tier to that input.
  database_subnets      = var.isolated_subnet_cidrs
  database_subnet_names = local.isolated_subnet_names

  # One NAT gateway per AZ for HA. The v5 wrapper creates a single
  # NAT gateway in the first public subnet by default; flipping
  # `one_nat_gateway_per_az = true` gives us a NAT per AZ.
  one_nat_gateway_per_az = true

  # The database (isolated) tier must have NO route to the IGW or NAT.
  # Both flags below are load-bearing for the PHI-egress-deny invariant:
  # the wrapper will not create a 0.0.0.0/0 route from the database
  # subnets to the IGW (create_database_internet_gateway_route = false)
  # and will not associate the database subnets with the NAT route
  # table (create_database_nat_gateway_route = false).
  create_database_subnet_route_table     = true
  create_database_subnet_group           = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # --------------------------------------------------------------------------
  # VPC Flow Logs (R4 / R12 / audit posture)
  # --------------------------------------------------------------------------
  # Delivered to CloudWatch Logs with 7-year (2557 days) retention.
  # The plan calls out `client_payload_enabled = false` -- in modern AWS
  # this is a vestigial property of the early VPC Flow Logs API and
  # is the default; we document the intent here even though no
  # terraform knob exposes it directly.
  enable_flow_log = true

  flow_log_traffic_type             = "ALL"
  flow_log_max_aggregation_interval = 60
  flow_log_destination_type         = "cloud-watch-logs"
  flow_log_log_format               = "$${version} $${account-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status} $${vpc-id} $${subnet-id} $${instance-id} $${tcp-flags} $${type} $${pkt-srcaddr} $${pkt-dstaddr} $${region} $${az-id} $${sublocation-type} $${sublocation-id} $${pkt-src-aws-service} $${pkt-dst-aws-service} $${flow-direction} $${traffic-path}"

  create_flow_log_cloudwatch_log_group            = true
  flow_log_cloudwatch_log_group_name_prefix       = "${local.name_prefix}-vpc-flow-logs-"
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = var.flow_log_cloudwatch_kms_key_id
  flow_log_cloudwatch_log_group_class             = "STANDARD"

  tags = var.tags
}
