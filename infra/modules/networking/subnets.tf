###############################################################################
# modules/networking/subnets.tf
# Subnet resources are created inside module.vpc in vpc.tf. This file
# surfaces the per-tier name + tag layers that the v5 wrapper exposes
# for the public / private / database (isolated) tiers.
#
# The split between vpc.tf and subnets.tf is intentional: vpc.tf owns
# the VPC + IGW + route-table wiring, subnets.tf owns the per-tier
# naming and tagging. Future units (U4, U5, U6) reference the subnet
# outputs from this file by name (`isolated_subnets` for RDS, etc.).
#
# Why this file is small: the v5 wrapper does the heavy lifting.
# Anything that needs to be defined OUTSIDE the wrapper (e.g. a
# per-AZ explicit route table association) would land here.
###############################################################################

locals {
  public_subnet_names = [
    for i, cidr in var.public_subnet_cidrs :
    "${local.name_prefix}-public-${var.availability_zones[i]}"
  ]

  private_subnet_names = [
    for i, cidr in var.private_subnet_cidrs :
    "${local.name_prefix}-private-${var.availability_zones[i]}"
  ]

  isolated_subnet_names = [
    for i, cidr in var.isolated_subnet_cidrs :
    "${local.name_prefix}-isolated-${var.availability_zones[i]}"
  ]

  # Per-AZ subnet name tags are applied at the module.vpc level via
  # the public_subnet_names / private_subnet_names inputs that the v5
  # wrapper supports. We expose them here as outputs for cross-module
  # use (e.g. a future U6 may want to assert an RDS subnet group maps
  # only to isolated subnets).
}
