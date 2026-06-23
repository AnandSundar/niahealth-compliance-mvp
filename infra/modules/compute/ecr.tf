###############################################################################
# modules/compute/ecr.tf
#
# ECR repository for the sample app image.
#
# Posture:
#   - image_tag_mutability = "IMMUTABLE"  : a tag cannot be overwritten;
#                                            a deploy must push a new tag
#                                            and update var.app_image_tag.
#                                            This is the supply-chain
#                                            control the plan calls for.
#   - image_scanning_configuration.scan_on_push = true  : Inspector scans
#                                            on every push; the plan's
#                                            "Amazon Inspector scans the
#                                            pushed image" requirement
#                                            is satisfied by the
#                                            Inspector default-ON for
#                                            ECR + this flag.
#   - encryption_configuration.kms_key = var.s3_phi_kms_key_arn : the
#                                            s3_phi CMK. The image
#                                            itself is not PHI, but
#                                            using the s3_phi CMK keeps
#                                            the encryption-key domain
#                                            consistent with the data
#                                            the image will process.
#   - Lifecycle policy: keep last 30 images; expire untagged after
#                       14 days. Bound the storage cost; preserve
#                       enough history to roll back a bad deploy.
#
# Repository policy: minimal -- the ECS execution role (created
# later in iam_task.tf) has the standard ecr:GetAuthorizationToken +
# ecr:BatchGetImage + ecr:GetDownloadLayerForImage permissions in
# its policy attachment. We do NOT add an aws_ecr_repository_policy
# resource because the IAM principal policy is sufficient for ECS
# to pull from its own account.
###############################################################################

resource "aws_ecr_repository" "app" {
  name                 = local.ecr_repo_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.s3_phi_kms_key_arn
  }

  tags = merge(var.tags, {
    Name      = local.ecr_repo_name
    Purpose   = "sample-app-image-registry"
    DataClass = "metadata"
  })
}

# Lifecycle policy: bound the image count so the registry doesn't
# grow unbounded; preserve enough history for rollback.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images; expire older"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
