data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  base_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

# ── ECR Repositories ──────────────────────────────────────────────────────────
#
# One private repository per service under the petclinic-{env}/ namespace.
# Repository names follow the pattern: petclinic-{env}/{service-name}
# Image URI: {account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-{env}/{service}:{tag}

resource "aws_ecr_repository" "services" {
  for_each = toset(var.service_names)

  name                 = "${var.project}-${var.environment}/${each.value}"
  image_tag_mutability = var.tag_mutability

  # Scan every image on push — fails CI if CRITICAL CVEs are found
  image_scanning_configuration {
    scan_on_push = true
  }

  # AES256 matches the encryption standard used across all project resources
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.base_tags, {
    Name    = "${var.project}-${var.environment}/${each.value}"
    Service = each.value
  })
}

# ── Lifecycle Policies ────────────────────────────────────────────────────────
#
# Rule 1 (priority 1): expire untagged images after 7 days — they accumulate
#   quickly from failed or rerun builds and waste storage.
# Rule 2 (priority 2): keep only the last 10 *tagged* images per repo —
#   limits storage to ~2 GB per service and enforces cleanup of old releases.
#   Untagged images are handled exclusively by rule 1; using tagStatus: tagged
#   here prevents the two rules from interfering with each other.

resource "aws_ecr_lifecycle_policy" "services" {
  for_each = toset(var.service_names)

  repository = aws_ecr_repository.services[each.value].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "tagged"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
