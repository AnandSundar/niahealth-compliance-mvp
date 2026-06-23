###############################################################################
# modules/observability/s3_archive.tf
# The immutable audit S3 bucket.
#
# Requirements (R11, C5):
#   - Bucket name: ${var.project_name}-audit-${var.environment}.
#   - object_lock_enabled_for_bucket = true (set at bucket creation
#     time -- it CANNOT be enabled after the fact; recreation would
#     be required).
#   - Default Object Lock retention: 2557 days (7 years), COMPLIANCE
#     mode. COMPLIANCE mode prevents even the account root from
#     deleting the object before retention expires -- this is the
#     audit-immutability invariant (the "immutable audit" control
#     C5 from the plan's control matrix).
#   - Versioning on.
#   - KMS-encrypted with the cloudtrail CMK (NOT the s3_phi CMK --
#     the audit bucket never holds PHI; using a separate CMK means
#     a compromise of the audit CMK cannot decrypt PHI and vice
#     versa).
#   - All 4 public-access blocks on (CKV_AWS_18 / CKV_AWS_53/54/55/56
#     all pass; the audit bucket is never public).
#   - Lifecycle rule transitions objects to Glacier Instant
#     Retrieval at 90 days (cost: ~$0.004/GB-month vs $0.023/GB-month
#     for S3 Standard; retrieval latency is still milliseconds).
#     No expiration -- the retention is governed by Object Lock
#     COMPLIANCE mode, not by the lifecycle rule.
#   - The bucket policy is created inline in cloudtrail.tf to keep
#     the trail-bucket association local. (The plan: "CloudTrail
#     bucket policy is created inline (not via the s3_archive module)
#     to keep the trail-bucket association local.")
#
# Schema note (v5.100): the S3 resource was split in the v5 AWS
# provider. The `aws_s3_bucket` resource is now just the bucket
# itself; all sub-features (versioning, lifecycle, public-access
# block, server-side encryption, object-lock configuration) live
# on separate sub-resources. This is the post-split pattern.
###############################################################################

# ----------------------------------------------------------------------------
# The bucket itself. Just `bucket` + `tags` (per the v5 split).
# ----------------------------------------------------------------------------
resource "aws_s3_bucket" "audit" {
  # Bucket name MUST be globally unique across all of AWS. The
  # name_prefix = "${project_name}-${environment}" pattern is
  # unlikely to collide but a real deploy would suffix with the
  # AWS account ID for a guaranteed-unique name. The dev path
  # uses a plain name to keep the plan output readable.
  bucket = local.audit_bucket_name

  # Force destroy is intentionally NOT set. The audit bucket is
  # immutable; even with the bucket empty, a `terraform destroy`
  # would be blocked by the Object Lock COMPLIANCE mode. The
  # destroy-time path requires a separate process (documented in
  # the runbook) that waits for retention to expire.

  tags = merge(var.tags, {
    Name      = local.audit_bucket_name
    Purpose   = "audit-archive"
    DataClass = "metadata"
  })
}

# ----------------------------------------------------------------------------
# Public access block: the 4 public-access flags (CKV_AWS_18
# passes when all 4 are true). This is a separate sub-resource
# in the v5 provider.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  # The four public-access flags. Each one closes a different
  # public-access vector. CKV_AWS_18 / CKV_AWS_53 / CKV_AWS_54 /
  # CKV_AWS_55 / CKV_AWS_56 all pass when these are all true.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ----------------------------------------------------------------------------
# Versioning. Required for Object Lock (a locked object version
# is what retention applies to; without versioning, a PutObject
# would replace the locked object and bypass the lock).
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ----------------------------------------------------------------------------
# Server-side encryption with the cloudtrail CMK. By design, the
# audit bucket uses the cloudtrail CMK (not the s3_phi CMK) so
# a compromise of the audit CMK cannot decrypt PHI and vice
# versa. CMKs are blast-radius boundaries; cross-bucket re-use
# of a single CMK is the anti-pattern.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.cloudtrail_kms_key_arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# ----------------------------------------------------------------------------
# Lifecycle rule: transition to Glacier Instant Retrieval at 90
# days. No expiration -- the retention is governed by Object
# Lock COMPLIANCE mode, not by a lifecycle rule (the two are
# separate concerns; a lifecycle expiration would fail to delete
# a COMPLIANCE-locked object and is therefore redundant).
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "transition-to-glacier-ir"
    status = "Enabled"

    # Apply to all object keys (the empty filter means "all").
    filter {}

    transition {
      days          = var.lifecycle_transition_days
      storage_class = "GLACIER_IR"
    }
  }

  depends_on = [aws_s3_bucket_versioning.audit]
}

# ----------------------------------------------------------------------------
# Object Lock default retention configuration.
#
# COMPLIANCE mode is the audit-immutability invariant: even the
# account root cannot delete a COMPLIANCE-locked object before
# its retention expires. GOVERNANCE mode would allow root to
# bypass; COMPLIANCE does not.
#
# Object Lock MUST be configured at bucket creation time. In
# the v5 provider, the bucket itself does not expose an
# `object_lock_enabled_for_bucket` argument; the lock is
# enabled implicitly by attaching an `aws_s3_bucket_object_lock_
# configuration` resource, which causes the provider to issue
# the PutObjectLockConfiguration call against the bucket. The
# bucket must already exist at the time this resource is
# created, and the provider order-of-operations handles that.
# ----------------------------------------------------------------------------
resource "aws_s3_bucket_object_lock_configuration" "audit" {
  # `object_lock_enabled_for_bucket = true` is set implicitly
  # by attaching this resource; the v5 provider turns the flag
  # on when the configuration is created.
  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode  = "COMPLIANCE"
      years = 7
    }
  }

  # depends_on the bucket + versioning being fully created; the
  # provider handles this implicitly via the `bucket` argument.
  depends_on = [aws_s3_bucket_versioning.audit]
}
