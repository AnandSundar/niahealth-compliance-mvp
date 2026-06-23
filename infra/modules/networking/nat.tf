###############################################################################
# modules/networking/nat.tf
# NAT gateway wiring.
#
# The plan calls for one NAT gateway per AZ (HA across AZ failure
# domains) in the public tier. Non-PHI egress from the PRIVATE tier
# flows through these NATs; the ISOLATED tier (RDS) has NO route to
# a NAT, which is the PHI-egress-deny invariant the Conftest policy
# enforces.
#
# Implementation: the v5 wrapper handles the per-AZ NAT allocation
# when `one_nat_gateway_per_az = true` is set on module.vpc
# (declared in vpc.tf). It also creates one EIP per NAT. The NAT
# IDs are re-exported via outputs.tf so a future unit (e.g. U4's
# "no PHI-bearing SG may route to a NAT" check) can read them.
#
# The isolated tier's route table (created by the v5 wrapper) is
# configured with `create_database_internet_gateway_route = false`
# AND `create_database_nat_gateway_route = false` (in vpc.tf) so
# the wrapper does NOT add a 0.0.0.0/0 route to the IGW or NAT
# from the database subnets. That is the load-bearing control:
# no PHI ever traverses the public NAT, and no route exists from
# the isolated tier to the IGW.
#
# This file is documentation-only. All the actual inputs live in
# vpc.tf; this file exists so a reader can find the NAT posture
# narrative in one place.
###############################################################################
