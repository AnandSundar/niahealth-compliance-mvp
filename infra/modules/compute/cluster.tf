###############################################################################
# modules/compute/cluster.tf
#
# The ECS Fargate cluster + cluster-level CloudWatch log group.
#
# containerInsights = enabled: turns on CloudWatch Container Insights
# (CPU/memory/network metrics per task, per service, per cluster).
# The Insights log group is created automatically in the
# /aws/ecs/containerinsights/<cluster> namespace; we do not
# pre-create it because the Insights agent manages its own group.
#
# The cluster-level CloudWatch log group is for the cluster's
# own diagnostic events (e.g. capacity provider state changes).
# Encrypted with the CWL CMK; 7-year retention matches the audit
# posture.
###############################################################################

resource "aws_ecs_cluster" "this" {
  name = local.ecs_cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, {
    Name      = local.ecs_cluster_name
    Purpose   = "fargate-cluster"
    DataClass = "metadata"
  })
}

# Cluster-level CloudWatch log group. Encrypted with the CWL CMK;
# 7-year retention matches the audit posture (the cluster's own
# diagnostic events are not PHI but are part of the audit trail).
resource "aws_cloudwatch_log_group" "ecs_cluster" {
  name              = local.ecs_cluster_log_group
  retention_in_days = 2557
  kms_key_id        = var.cwl_kms_key_arn

  tags = merge(var.tags, {
    Name    = local.ecs_cluster_log_group
    Purpose = "ecs-cluster-logs"
  })
}
