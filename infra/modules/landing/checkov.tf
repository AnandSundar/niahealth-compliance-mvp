###############################################################################
# modules/landing/checkov.tf
#
# Resource-group / tagging baseline hook for the landing module. In
# U2 we don't add any new AWS resources here beyond what iam.tf and
# oidc.tf already create, so this file is intentionally empty. The
# Checkov policy at infra/policies/checkov.yaml governs ALL resources
# in the tree, and the AWS provider's default_tags block in
# providers.tf adds the 3 required tags (Environment, DataClass,
# Owner) to everything created here automatically.
#
# When U3+ adds VPC / KMS / S3 resources that need module-local
# Checkov skip annotations, this is the file to put them in.
###############################################################################
