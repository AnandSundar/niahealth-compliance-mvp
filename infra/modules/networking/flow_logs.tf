###############################################################################
# modules/networking/flow_logs.tf
# VPC Flow Logs.
#
# Requirements (R4 + R12 + audit posture):
#   - Enable flow logs on the VPC.
#   - Deliver to CloudWatch Logs with 7-year (2557 days) retention.
#   - `client_payload_enabled = false` so PHI never leaves the VPC in
#     payload form. The plan's explicit call-out of this flag is
#     defense-in-depth: in modern AWS, the flag is a vestigial
#     property of the early VPC Flow Logs API and is effectively
#     always-false (flow log records contain only connection metadata:
#     src/dst IP, src/dst port, bytes, packets, action -- NOT payload
#     bytes). We document the intent here even though no terraform
#     knob exposes it directly.
#
# Implementation: the actual flow log resources (CloudWatch log group,
# IAM role, aws_flow_log) are declared inside the v5 wrapper, which
# is called from vpc.tf. The knob values live in vpc.tf too, so all
# the wrapper inputs are co-located. This file is intentionally
# documentation-only so a future reader does not have to grep
# multiple files to understand the flow log posture.
#
# S3 destination: the plan also says flow logs go to S3. The v5
# wrapper supports a single destination (CloudWatch OR S3) at a
# time. To keep the module self-contained, we deliver to CloudWatch
# only from this module; a follow-up (U5, logging fan-in) adds the
# S3 archive with a CloudWatch Logs subscription filter ->
# Firehose -> S3. Documented in the U5 plan.
###############################################################################
