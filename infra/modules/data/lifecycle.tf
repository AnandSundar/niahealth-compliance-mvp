###############################################################################
# modules/data/lifecycle.tf
# Cross-region replication of the PHI bucket + the data-ingest IAM role.
#
# Why this file is named "lifecycle.tf" but contains TWO unrelated
# concerns (CRR + ingest role): the plan's Files list contains only
# this filename (no ingest.tf). The CRR role + replica bucket live
# here because they are part of the source bucket's lifecycle
# (cross-region replication is a per-bucket property). The ingest
# role lives here because it is the WRITE side of the data bucket;
# colocating the write path with the bucket's replication
# configuration keeps the PR diff focused on a single concern:
# "what can write to the data bucket, and where does the data end
# up?" Documented as a deviation from a strict one-resource-per-
# file split; both concerns are tightly coupled to the bucket.
#
# Cross-region replication (R7, R12, R16, DR posture):
#   - Source: ${var.project_name}-data-${var.environment} in
#             var.region (ca-central-1).
#   - Replica: ${var.project_name}-data-${var.environment}-replica
#              in var.dr_region (ca-west-1).
#   - Replica storage class: STANDARD_IA (cheaper than Standard for
#     replicas that are rarely read; a DR replica is written-once,
#     read-on-disaster).
#   - Replica encryption: same s3_phi CMK as the source. This is
#     a deliberate trade-off: a multi-region CMK would be cleaner
#     but is out of scope for the MVP.
#   - Replica lifecycle: matches the source (Glacier IR at 90 days,
#     Deep Archive at 365 days).
#   - NO Object Lock on the replica (the source has no Object Lock
#     either; Object Lock on PHI is a compliance hazard per the
#     header comment in s3_phi.tf).
#
# CRR ordering (the plan called this out):
#   CRR requires (a) the source bucket to have versioning enabled
#   AND (b) the IAM role to exist BEFORE the replication
#   configuration is set. We use `depends_on` to enforce order.
#
# Data residency: ca-west-1 is a Canadian region (the second
# commercial region in Canada after ca-central-1). Cross-region
# replication of PHI to ca-west-1 stays within Canada, satisfying
# R1 + PIPEDA Schedule 1 + PHIPA s.13. If a future requirement
# mandates a non-Canadian DR region, the data-residency policy
# MUST be revisited (this is a hard control; see CONTROLS.md U9).
#
# Data ingest role (the WRITE side of the data bucket):
#   The U4 subagent report identified a critical gap: the ECS task
#   role CANNOT write to its own env's data bucket (the boundary
#   blocks PutObject via the wildcard wildcard deny, AND the ECS
#   task role's inline policy has an explicit Deny on s3:PutObject
#   on the data bucket). The ECS task role is the READ path
#   (PHI readback via the sample app). The WRITE path is a separate
#   ingest role -- assumed by the future ingest pipeline (U7+) --
#   that CAN PutObject on the data bucket.
#
#   This role lives in lifecycle.tf (not in a separate ingest.tf)
#   because the plan's Files list contains only this filename. The
#   deviation is documented in the report.
#
#   Ingest role policy:
#     - Allow s3:PutObject on the PHI bucket (and on the replica,
#       for U7's future data-sync-back-to-source path).
#     - Allow s3:GetObject on the PHI bucket (the ingest path may
#       need to read for validation / dedup).
#     - Deny s3:DeleteObject + s3:DeleteBucket: the ingest path
#       must NOT be able to destroy PHI (Deny at the role level,
#       independent of the boundary's wildcard deny).
#     - Allow kms:GenerateDataKey on the s3_phi CMK so the ingest
#       path can encrypt each PutObject with a fresh envelope key.
###############################################################################

# ===========================================================================
# REPLICA BUCKET (ca-west-1)
# ===========================================================================
# The replica bucket lives in the DR region. Because Terraform is
# stateful across regions, we declare a provider alias for the DR
# region and route the replica resources through it. The source
# bucket resources (in s3_phi.tf) use the default provider (home
# region).
#
# Provider alias is declared in main.tf of the root module (not
# here) so the alias is discoverable; the data module just uses
# `aws.dr` to route to the DR provider. NOTE: the provider alias
# must be created in the root module; this file references it as
# `aws.dr`. If the alias is not declared in the root, terraform
# validate fails -- see infra/main.tf for the `provider "aws" { alias
# = "dr" }` block.
# ===========================================================================

# ----------------------------------------------------------------------------
# The replica bucket itself. v5 split: just `bucket` + `tags`.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket" "phi_replica" {
  provider = aws.dr

  bucket = local.phi_bucket_replica_name

  # Force destroy is NOT set (same posture as the source bucket;
  # PHI replicas are not casually destroyed).

  tags = merge(var.tags, {
    Name      = local.phi_bucket_replica_name
    Purpose   = "data-tier-phi-replica"
    DataClass = "phi"
    Owner     = "niahealth-security"
    Replica   = "true"
  })
}

# ----------------------------------------------------------------------------
# Public access block on the replica. Same 4-flag posture as the
# source.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "phi_replica" {
  provider = aws.dr
  bucket   = aws_s3_bucket.phi_replica.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ----------------------------------------------------------------------------
# Versioning on the replica (required for CRR).
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_versioning" "phi_replica" {
  provider = aws.dr
  bucket   = aws_s3_bucket.phi_replica.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ----------------------------------------------------------------------------
# Server-side encryption on the replica. Same s3_phi CMK as the
# source (multi-region CMKs are out of scope; documented in the
# header).
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "phi_replica" {
  provider = aws.dr
  bucket   = aws_s3_bucket.phi_replica.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = local.s3_phi_kms_key_arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# ----------------------------------------------------------------------------
# Lifecycle on the replica. Matches the source: Glacier IR at 90
# days + Deep Archive at 365 days. The replica is written-once,
# read-on-disaster; the cold-storage tier makes economic sense.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "phi_replica" {
  provider = aws.dr
  bucket   = aws_s3_bucket.phi_replica.id

  rule {
    id     = "transition-to-cold-storage"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }
  }

  depends_on = [aws_s3_bucket_versioning.phi_replica]
}

# ----------------------------------------------------------------------------
# Bucket policy on the replica: same deny-unencrypted-PUTs +
# deny-insecure-transport posture as the source. Defense-in-depth.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "phi_replica_bucket_policy" {
  provider = aws.dr

  statement {
    sid    = "DenyUnencryptedObjectUploads"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:PutObject"]

    resources = [
      local.phi_bucket_replica_arn,
      "${local.phi_bucket_replica_arn}/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      local.phi_bucket_replica_arn,
      "${local.phi_bucket_replica_arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "phi_replica" {
  provider = aws.dr
  bucket   = aws_s3_bucket.phi_replica.id
  policy   = data.aws_iam_policy_document.phi_replica_bucket_policy.json

  depends_on = [aws_s3_bucket_public_access_block.phi_replica]
}

# ===========================================================================
# CROSS-REGION REPLICATION IAM ROLE
# ===========================================================================
# CRR requires the S3 service to assume a role that has read
# access on the source + write access on the replica. The role
# lives in the home region (the source bucket's region); S3
# assumes it from the home region even when the replica is in
# the DR region.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "s3_crr_assume_role" {
  statement {
    sid    = "S3CrrAssumeRole"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "s3.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "s3_crr" {
  name        = local.crr_role_name
  description = "S3 cross-region replication role for ${local.name_prefix}. Reads source bucket objects; writes replica objects in ${var.dr_region}. KMS-envelope-encrypts with the s3_phi CMK."

  assume_role_policy = data.aws_iam_policy_document.s3_crr_assume_role.json

  max_session_duration = 3600

  tags = merge(var.tags, {
    Name      = local.crr_role_name
    Purpose   = "s3-cross-region-replication"
    DataClass = "metadata"
  })
}

data "aws_iam_policy_document" "s3_crr_role_policy" {
  # Allow: read source bucket (Get + List).
  statement {
    sid    = "AllowReadSourceBucket"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetObjectTagging",
      "s3:ListBucket",
      "s3:GetReplicationConfiguration",
    ]

    resources = [
      local.phi_bucket_arn,
      local.phi_bucket_prefix,
    ]
  }

  # Allow: write to the replica (Put + ReplicateDelete + ReplicateTags).
  statement {
    sid    = "AllowWriteReplicaBucket"
    effect = "Allow"

    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
      "s3:GetObjectVersionForReplication",
      "s3:ObjectOwnerOverrideToBucketOwner",
    ]

    # The replica bucket ARN lives in the DR region; the partition
    # is the same (aws). We construct the ARN inline rather than
    # using the resource attribute because the replica resource
    # is in a different provider region.
    resources = [
      local.phi_bucket_replica_arn,
      "${local.phi_bucket_replica_arn}/*",
    ]
  }

  # Allow: KMS GenerateDataKey on the s3_phi CMK so the replica
  # objects can be encrypted with a fresh envelope key.
  statement {
    sid    = "AllowKmsForCrr"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
      "kms:Encrypt",
    ]

    resources = [
      var.s3_phi_kms_key_arn,
    ]
  }
}

resource "aws_iam_role_policy" "s3_crr_inline" {
  name   = "${local.crr_role_name}-inline"
  role   = aws_iam_role.s3_crr.id
  policy = data.aws_iam_policy_document.s3_crr_role_policy.json
}

# ----------------------------------------------------------------------------
# Replication configuration on the source bucket. The plan calls
# out that CRR requires the source bucket to have versioning
# enabled AND the IAM role to exist BEFORE the replication
# configuration is set; we use depends_on to enforce order.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_replication_configuration" "phi" {
  # Must have bucket versioning enabled before replication config
  # can be set.
  depends_on = [
    aws_s3_bucket_versioning.phi,
    aws_iam_role_policy.s3_crr_inline,
  ]

  bucket = aws_s3_bucket.phi.id
  role   = aws_iam_role.s3_crr.arn

  rule {
    id     = "replicate-to-ca-west-1"
    status = "Enabled"

    # Apply to all object keys (the empty filter means "all").
    filter {}

    destination {
      bucket        = local.phi_bucket_replica_arn
      storage_class = "STANDARD_IA"

      # Replica-side encryption with the same s3_phi CMK. The
      # replication role has kms:GenerateDataKey on this key (see
      # s3_crr_role_policy above).
      encryption_configuration {
        replica_kms_key_id = var.s3_phi_kms_key_arn
      }
    }

    # Delete marker replication: when the source object is deleted,
    # the replica also gets a delete marker. Without this, deletes
    # on the source are not propagated to the replica and the
    # replica drifts.
    delete_marker_replication {
      status = "Enabled"
    }
  }
}

# ===========================================================================
# DATA INGEST IAM ROLE
# ===========================================================================
# The WRITE side of the data bucket. The ECS task role (U4) is the
# READ path; this role is the WRITE path. The U4 subagent report
# flagged this as a critical gap: without a separate ingest role,
# the sample app cannot write PHI into the data bucket (the ECS
# task role's policy explicitly Denies s3:PutObject on the data
# bucket, and the permission boundary caps wildcards).
#
# Trust policy: ecs-tasks.amazonaws.com. The future ingest pipeline
# (U7) assumes this role via the ECS task's OIDC federation. (The
# task's actual execution-role vs task-role split is a U7 concern;
# U6 just creates the role + policy and exposes it as an output.)
#
# Permission boundary: service_boundary_arn from the identity
# module. This caps the role's effective permissions at the same
# level as every other service role (so the ingest path cannot,
# for example, mutate IAM or KMS).
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "data_ingest_assume_role" {
  statement {
    sid    = "ECSTasksAssumeRole"
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "ecs-tasks.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "data_ingest" {
  name        = local.data_ingest_role_name
  description = "Data ingest role for ${local.name_prefix}. Writes to the data-tier PHI bucket + replica; reads for validation/dedup. Cannot delete PHI. Permission-bounded by ${local.name_prefix}-service-boundary."

  assume_role_policy = data.aws_iam_policy_document.data_ingest_assume_role.json

  max_session_duration = 3600

  permissions_boundary = var.service_boundary_arn

  tags = merge(var.tags, {
    Name      = local.data_ingest_role_name
    Purpose   = "data-tier-ingest"
    DataClass = "phi"
  })
}

data "aws_iam_policy_document" "data_ingest_role_policy" {
  # Allow: write to the PHI bucket (and to the replica, for
  # U7's future data-sync-back-to-source path).
  statement {
    sid    = "AllowWriteDataBucket"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]

    resources = [
      local.phi_bucket_arn,
      local.phi_bucket_prefix,
      local.phi_bucket_replica_arn,
      "${local.phi_bucket_replica_arn}/*",
    ]
  }

  # Allow: KMS GenerateDataKey on the s3_phi CMK so each PutObject
  # can be encrypted with a fresh envelope key.
  statement {
    sid    = "AllowKmsForDataIngest"
    effect = "Allow"

    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]

    resources = [
      var.s3_phi_kms_key_arn,
    ]
  }

  # Deny: explicit deny on s3:DeleteObject + s3:DeleteBucket +
  # s3:DeleteObjectVersion. Load-bearing: the ingest path MUST NOT
  # be able to destroy PHI. The permission boundary already caps
  # wildcards, but a per-statement Deny makes the intent auditable
  # in PR (the boundary is a ceiling; this is a per-action deny
  # below the ceiling).
  statement {
    sid    = "DenyDeleteOnDataBucket"
    effect = "Deny"

    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:PutBucketAcl",
      "s3:PutBucketPublicAccessBlock",
      "s3:DeleteBucketPolicy",
      "s3:DeleteBucketPublicAccessBlock",
    ]

    resources = [
      local.phi_bucket_arn,
      local.phi_bucket_prefix,
      local.phi_bucket_replica_arn,
      "${local.phi_bucket_replica_arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "data_ingest_inline" {
  name   = "${local.data_ingest_role_name}-inline"
  role   = aws_iam_role.data_ingest.id
  policy = data.aws_iam_policy_document.data_ingest_role_policy.json
}