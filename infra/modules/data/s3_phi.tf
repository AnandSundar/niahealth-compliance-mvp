###############################################################################
# modules/data/s3_phi.tf
# The data-tier PHI S3 bucket.
#
# The bucket name MUST be ${var.project_name}-data-${var.environment}.
# This is a hard contract: the observability module's Macie job
# targets this exact name pattern (see modules/observability/macie.tf
# -> local.data_bucket_name). U7's sample app's ECS task definition
# writes to this bucket via the data_ingest_role in lifecycle.tf.
#
# Requirements (R2, R4, R7, R8, R12, R16):
#   - versioning on (required for cross-region replication; a
#     locked-object-version is what CRR replicates, not the head).
#   - default KMS encryption with the s3_phi CMK (CKV_AWS_19 +
#     bucket_key_enabled for cost discipline on the per-object
#     envelope key).
#   - all 4 public-access blocks on (CKV_AWS_18 / CKV_AWS_53/54/55/56).
#   - lifecycle: transition to Glacier IR at 90 days (cost without
#     sacrificing retrieval latency) + Glacier Deep Archive at 365
#     days (cheaper long-term cold storage).
#   - NO Object Lock: Object Lock on PHI storage creates compliance
#     nightmares (PHIPA's right-to-erasure conflicts with WORM
#     retention; the audit bucket -- U5 -- has Object Lock; the PHI
#     bucket does not).
#   - replication configuration in lifecycle.tf (separate file to
#     keep the CRR IAM role + replica bucket creation local).
#
# Schema note (v5.100): the S3 resource was split in the v5 AWS
# provider. The `aws_s3_bucket` resource is now just the bucket
# itself; all sub-features (versioning, lifecycle, public-access
# block, server-side encryption, replication configuration) live
# on separate sub-resources. This is the post-split pattern,
# consistent with modules/observability/s3_archive.tf.
#
# Macie scope: the U5 Macie classification job targets this bucket
# (local.data_bucket_name in observability/main.tf). Macie will
# scan all objects including versions; lifecycle transitions to
# Glacier are transparent to Macie (Macie fetches the current
# version of each object on its daily cadence).
###############################################################################

# ----------------------------------------------------------------------------
# The bucket itself. Just `bucket` + `tags` (per the v5 split).
# ----------------------------------------------------------------------------
resource "aws_s3_bucket" "phi" {
  # Bucket name MUST be globally unique across all of AWS. The
  # name_prefix = "${project_name}-data-${environment}" pattern is
  # unlikely to collide but a real deploy would suffix with the AWS
  # account ID for a guaranteed-unique name. The dev path uses a
  # plain name to keep the plan output readable.
  bucket = local.phi_bucket_name

  # Force destroy is intentionally NOT set. The PHI bucket holds
  # PHI; a `terraform destroy` would orphan any objects not
  # transitioned to Glacier yet. An operator-driven destroy is the
  # only path that should empty the bucket first.

  tags = merge(var.tags, {
    Name      = local.phi_bucket_name
    Purpose   = "data-tier-phi"
    DataClass = "phi"
    Owner     = "niahealth-security"
  })
}

# ----------------------------------------------------------------------------
# Public access block: the 4 public-access flags (CKV_AWS_18
# passes when all 4 are true). Separate sub-resource in v5.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "phi" {
  bucket = aws_s3_bucket.phi.id

  # The four public-access flags. Each one closes a different
  # public-access vector. CKV_AWS_18 / CKV_AWS_53 / CKV_AWS_54 /
  # CKV_AWS_55 / CKV_AWS_56 all pass when these are all true.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ----------------------------------------------------------------------------
# Versioning. Required for cross-region replication (CRR replicates
# object versions, not just the head; without versioning CRR would
# be a no-op).
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_versioning" "phi" {
  bucket = aws_s3_bucket.phi.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ----------------------------------------------------------------------------
# Server-side encryption with the s3_phi CMK. The CMK is the same
# one used to encrypt the audit-bucket-adjacent secrets (the Cognito
# client secret); the cross-bucket re-use is intentional because
# both resources sit in the PHI-adjacent trust boundary.
#
# bucket_key_enabled = true tells S3 to generate a per-object
# envelope key and encrypt the envelope key with the bucket key
# (derived from the CMK). This dramatically reduces the KMS API
# call volume (and the per-call cost) for high-write buckets.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "phi" {
  bucket = aws_s3_bucket.phi.id

  rule {
    apply_server_side_encryption_by_default {
      # The same CMK is reused for the source and the replica.
      # Multi-region CMKs are out of scope for the MVP; the trade-
      # off is that the replica bucket's objects are encrypted in
      # ca-central-1 and decrypted / re-encrypted for the replica
      # in ca-west-1 using the same key ARN.
      kms_master_key_id = local.s3_phi_kms_key_arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# ----------------------------------------------------------------------------
# Lifecycle rule: transition to Glacier IR at 90 days (cost
# discipline; retrieval latency still milliseconds), then to
# Glacier Deep Archive at 365 days (cheapest long-term cold
# storage). No expiration -- PHI retention is governed by the
# application layer + PHIPA / PIPEDA, not by a lifecycle rule.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "phi" {
  bucket = aws_s3_bucket.phi.id

  rule {
    id     = "transition-to-cold-storage"
    status = "Enabled"

    # Apply to all object keys (the empty filter means "all").
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

  # depends_on versioning: the lifecycle configuration needs the
  # bucket's versioning state to be fully resolved.
  depends_on = [aws_s3_bucket_versioning.phi]
}

# ----------------------------------------------------------------------------
# Bucket policy: explicit deny on unencrypted PUTs. Defense-in-
# depth on top of the default encryption configuration: any PUT
# request that does not include `x-amz-server-side-encryption:
# aws:kms` is rejected. This prevents accidental plaintext writes
# from a misconfigured client.
# ----------------------------------------------------------------------------
data "aws_iam_policy_document" "phi_bucket_policy" {
  # Deny unencrypted PUTs.
  statement {
    sid    = "DenyUnencryptedObjectUploads"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:PutObject"]

    resources = [
      local.phi_bucket_arn,
      local.phi_bucket_prefix,
    ]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  # Deny unencrypted-over-HTTPS PUTs (belt-and-suspenders: any PUT
  # request that does not arrive over HTTPS is rejected, even if
  # the SSE header is present). The ALB -> ECS path terminates
  # TLS at the ALB; the ECS task re-encrypts to RDS Proxy / S3 over
  # TLS -- this rule is a safety net for any future integration that
  # forgets the TLS hop.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      local.phi_bucket_arn,
      local.phi_bucket_prefix,
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "phi" {
  bucket = aws_s3_bucket.phi.id
  policy = data.aws_iam_policy_document.phi_bucket_policy.json

  depends_on = [aws_s3_bucket_public_access_block.phi]
}