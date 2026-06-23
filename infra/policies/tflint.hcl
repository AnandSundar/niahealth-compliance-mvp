# tflint configuration for the NiaHealth compliance reference architecture.
#
# Goals:
#   1. Style: lowercase + hyphens (no underscores) in resource names.
#   2. Tagging: every taggable resource carries Environment, DataClass, Owner.
#   3. Plugin: enable the AWS provider plugin so resource-specific
#      deprecated attributes and missing required arguments are caught.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.35.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Rule: enforce the 3 required tags on every taggable resource.
# Duplicated with conftest.rego on purpose: tflint runs at `terraform
# plan` time (cheaper feedback loop) and conftest runs at policy
# time. Both gates must pass before merge.
rule "terraform.required_tags" {
  enabled = true
  tags    = ["Environment", "DataClass", "Owner"]
}

# Rule: naming convention. Lowercase, hyphens, no underscores in
# resource NAME values. The resource address (e.g. `aws_s3_bucket.foo`)
# is governed by the linter, not by this rule.
#
# Sample failing input:
#   name = "niahealth_Data_Tier"        # underscored, mixed case
# Sample passing input:
#   name = "niahealth-data-tier"
rule "terraform.naming_convention" {
  enabled = true
  # Matches resource `name` arguments whose value is a literal string
  # containing uppercase letters or underscores. The pattern is a
  # negative lookahead: anything containing A-Z or _ is flagged.
  format  = "^[a-z][a-z0-9-]*$"
  regex   = true
}
