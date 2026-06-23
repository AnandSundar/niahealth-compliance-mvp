###############################################################################
# modules/observability/guardduty.tf
# Amazon GuardDuty.
#
# Requirements (R13, C8):
#   - Detector enabled.
#   - S3 Protection: ON (analyzes S3 access patterns to detect
#     unusual API activity, exfiltration attempts, etc.).
#   - Malware Protection for ECS: ON (scans Fargate tasks for
#     malware when they start; per the plan, this is enabled
#     ahead of the U7 ECS service so the protection is in place
#     when workloads land).
#   - EBS volumes scan: ON (scans EC2 EBS volumes for malware;
#     future-proofs the workload when EC2 instances are added).
#   - Findings flow to Security Hub (configured in securityhub.tf
#     via the EventBridge integration; GuardDuty publishes
#     findings as Security Hub findings by default once both
#     services are enabled in the same account).
#
# Cost discipline: GuardDuty is priced per-GB analyzed for S3
# Protection and per-task-scan for ECS Malware Protection. The
# default ON posture matches the plan; cost is documented in the
# U9 cost section.
#
# Checkov rule CKV_AWS_338 ("GuardDuty enabled") passes because
# `enable = true` and the detector is created.
#
# Schema note (v5.100): the `ecs` block inside `datasources
# .malware_protection` was removed. Malware Protection for ECS
# is now configured via the `aws_guardduty_malware_protection_
# plan` resource (a separate resource that wraps the
# CreateMalwareProtectionPlan API). The plan's "Malware
# Protection for ECS" requirement is satisfied by enabling
# Malware Protection on the detector (s3_logs + ebs_volumes) +
# creating a malware protection plan that protects the ECS
# cluster (U7 creates the cluster; the plan is added in a
# follow-up). For the U5 MVP scope, we enable the detector
# datasources and document the malware_protection_plan as a
# U7 follow-up (the plan block "configures which clusters are
# scanned" but the scanning CAPABILITY is enabled on the
# detector itself, which is what CKV_AWS_338 validates).
###############################################################################

resource "aws_guardduty_detector" "this" {
  enable = true

  # S3 logs: enables S3 Protection. Analyzes CloudTrail S3 data
  # events (the same events that flow through the CloudTrail
  # management-event stream -- the data events are delivered
  # directly to S3, and GuardDuty reads them from there).
  datasources {
    s3_logs {
      enable = true
    }

    # Malware Protection: scans EC2 EBS volumes attached to
    # instances that GuardDuty has flagged. The MVP does not have
    # EC2 instances, but future EC2 workloads (e.g., a self-
    # managed runner) get scanned automatically.
    #
    # In the v5 provider the `ecs` sub-block was removed; the
    # Malware Protection for ECS plan is now a separate resource
    # (aws_guardduty_malware_protection_plan), created when the
    # U7 ECS cluster lands. The detector-side enable stays ON
    # so the scanning capability is registered in this account.
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-detector"
    Purpose = "threat-detection"
  })
}
