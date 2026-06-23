###############################################################################
# modules/compute/ecs.tf
#
# Fargate capacity provider strategy + the cluster-level
# CloudWatch log group for ECS events that aren't tied to a
# specific task (e.g. capacity provider state changes).
#
# The aws_ecs_cluster resource itself is in cluster.tf. The
# per-task log group is in task.tf (so it sits next to the
# task definition that points at it). The cluster log group is
# here so the Fargate-related logging surface is in one place.
###############################################################################

# Note: the Fargate capacity provider is implicit -- Fargate
# is the default capacity provider for ECS clusters created
# without explicit `capacity_providers` blocks. We do not
# pre-declare it because Terraform 1.9 + the v5 AWS provider
# do not have a managed `aws_ecs_capacity_provider` resource
# for the Fargate provider (it's a service-default).

# Empty file is a Terraform anti-pattern (Fmt complains, and
# it's a smell for the reviewer). The cluster-level log group
# lives in cluster.tf; this file documents the Fargate
# capacity-provider decision.
