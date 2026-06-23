###############################################################################
# modules/networking/main.tf
#
# The "networking" module owns the network plane in ca-central-1:
#   - VPC + 3-AZ tier of public / private / isolated subnets (vpc.tf, subnets.tf)
#   - NAT gateways in public subnets for non-PHI egress from the private
#     tier only -- isolated subnets have NO route to NAT, which is the
#     PHI-egress-deny invariant the Conftest policy enforces (nat.tf)
#   - VPC endpoints (interface + gateway) so the private and isolated
#     tiers never reach the public internet for AWS API calls (endpoints.tf)
#   - VPC Flow Logs to CloudWatch with 7-year retention and
#     client_payload_enabled = false (flow_logs.tf)
#
# Module pattern: this is glue. The heavy lifting is in vpc.tf (which
# calls terraform-aws-modules/vpc/aws) and endpoints.tf (which calls the
# modules/vpc-endpoints submodule of the same wrapper). The split per
# concern follows the landing module convention.
###############################################################################

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}
