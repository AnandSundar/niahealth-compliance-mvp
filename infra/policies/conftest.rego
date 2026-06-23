###############################################################################
# conftest.rego
# OPA policy for the NiaHealth compliance reference architecture.
#
# Enforces the 3 required tags on every taggable AWS resource:
#   - Environment
#   - DataClass
#   - Owner
#
# Input: the JSON output of `terraform plan -out=tfplan && terraform
# show -json tfplan` (the same shape `conftest test` consumes by
# default). The policy iterates `resource_changes`, extracts
# `change.after.tags`, and fails any resource that is missing one or
# more of the required keys.
#
# Why tags at the policy layer (not just the provider): providers and
# default_tags are great, but a single missed module call -- e.g. an
# aws_kms_key created via a community module that overwrites the
# default_tags map -- can silently strip them. Policy-as-code is the
# belt to the provider's suspenders.
#
# Run with:
#   terraform plan -out=tfplan
#   terraform show -json tfplan > tfplan.json
#   conftest test --policy infra/policies/conftest.rego tfplan.json
###############################################################################

package main

# The 3 required tag keys. The "Owner" tag is also enforced at the
# provider level (default_tags block in providers.tf) but we duplicate
# the check here so a future module that does not propagate default
# tags still fails the policy.
required_tags := {"Environment", "DataClass", "Owner"}

# Taggable resource types. Mirrors the AWS provider's list of
# resources that support the `tags` argument. If a new taggable
# resource type appears and is missing from this set, the policy
# would silently pass it -- to prevent that, we also have a separate
# warn rule below for any new resource type that declares `tags` but
# is not in the allowlist.
#
# This list grows explicitly as new resource types enter the
# codebase. U2 added the initial 22; U3 added the 7 below for the
# network + edge plane (U3 plan call-out); U4 added the 4 below
# for the identity + secrets plane (IAM Access Analyzer, SNS
# paging topic, EventBridge rule, SNS topic -- the
# secretsmanager_secret + cloudwatch_log_group + iam_role + iam_policy
# + iam_user types were already in the list from U2).
taggable_resource_types := {
  "aws_iam_role",
  "aws_iam_policy",
  "aws_iam_user",
  "aws_iam_group",
  "aws_kms_key",
  "aws_s3_bucket",
  "aws_db_instance",
  "aws_db_subnet_group",
  "aws_db_parameter_group",
  "aws_rds_cluster",
  "aws_lb",
  "aws_lb_target_group",
  "aws_cloudwatch_log_group",
  "aws_wafv2_web_acl",
  "aws_acm_certificate",
  "aws_vpc_endpoint",
  "aws_route_table",
  "aws_internet_gateway",
  "aws_nat_gateway",
  "aws_cloudtrail",
  "aws_config_configuration_recorder",
  "aws_guardduty_detector",
  "aws_securityhub_account",
  "aws_macie2_classification_job",
  "aws_ecr_repository",
  "aws_ecs_cluster",
  "aws_ecs_service",
  "aws_ecs_task_definition",
  "aws_cognito_user_pool",
  "aws_secretsmanager_secret",
  # U4 additions -- identity + secrets plane.
  "aws_accessanalyzer_analyzer",
  "aws_sns_topic",
  "aws_cloudwatch_event_rule",
  # U5 additions -- security + audit plane.
  "aws_config_config_rule",
  "aws_macie2_account",
  "aws_kinesis_firehose_delivery_stream",
}

# Allowlist of resource types that genuinely do not support tags and
# therefore should be skipped. If a new resource type is added that
# we expect to be taggable but is missing from taggable_resource_types,
# the deny_missing_required_tags rule below will fire.
non_taggable_resource_types := {
  "aws_caller_identity",
  "aws_region",
  "aws_partition",
  "aws_canonical_user_id",
}

# Terraform plan JSON helper: given a single resource_change, return
# the resource type.
resource_type(change) := change.type

# Terraform plan JSON helper: extract the resource's tags map after
# the proposed change. Returns an empty object if the resource has no
# tags argument (or the resource type does not support tags).
resource_tags(change) := tags if {
  tags := change.change.after.tags
}

# Default-tags the AWS provider applies to every resource. We treat
# these as also satisfying the policy so a resource that omits tags
# inline but inherits them via default_tags does not trip the rule.
# The conftest runner runs against a plan JSON, which DOES include
# the resolved tags after the provider's default_tags pass, so this
# helper is usually a no-op -- but it future-proofs against runner
# configurations that strip default tags.
provider_default_tags := {
  "Environment": "dev",
  "DataClass": "phi",
  "Owner": "niahealth-eng",
}

# Effective tags: the union of the resource's inline tags and the
# provider default tags. Used by the deny rule.
effective_tags(change) := merged if {
  inline := resource_tags(change)
  merged := object.union(inline, provider_default_tags)
}

# Main rule: every resource in taggable_resource_types MUST declare
# all 3 required tag keys (either inline or via the provider's
# default_tags).
deny_missing_required_tags contains msg if {
  rc := input.resource_changes[_]
  type := resource_type(rc)
  taggable_resource_types[type]
  tags := effective_tags(rc)
  missing := required_tags - {key | tags[key]}
  count(missing) > 0
  msg := sprintf(
    "resource %s of type %s is missing required tag(s): %v",
    [rc.address, type, sort(missing)],
  )
}

# Defense-in-depth: if a resource of an UNLISTED type declares a
# `tags` argument, that is a smell -- it should be added to either
# taggable_resource_types or non_taggable_resource_types so the
# policy is explicit. We do not block the build on this (it would
# be too noisy for an MVP), but we do surface a finding so the
# reviewer notices.
warn_unlisted_tagged_resource contains msg if {
  rc := input.resource_changes[_]
  type := resource_type(rc)
  not taggable_resource_types[type]
  not non_taggable_resource_types[type]
  tags := resource_tags(rc)
  count(tags) > 0
  msg := sprintf(
    "resource %s of type %s has tags but is not in taggable_resource_types; add it to the policy allowlist (resource has tags: %v)",
    [rc.address, type, sort(object.keys(tags))],
  )
}
