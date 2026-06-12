data "aws_caller_identity" "current" {}

# GitHub Actions OIDC identity provider (one per AWS account).
# If this provider already exists in your account, import it:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = merge({
    Project   = var.project
    ManagedBy = "terraform"
  }, var.tags, {
    Name = "${var.project}-github-oidc-provider"
  })
}

resource "aws_iam_role" "github_actions" {
  name = "${var.project}-github-actions-role"

  # Trust policy: only the app repo's main branch can assume this role.
  # sts:AssumeRoleWithWebIdentity is required for OIDC federation — not sts:AssumeRole.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = merge({
    Project   = var.project
    ManagedBy = "terraform"
  }, var.tags, {
    Name = "${var.project}-github-actions-role"
  })
}

resource "aws_iam_role_policy" "ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken is an account-level action — no specific resource ARN exists.
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Scoped to petclinic-* repos only. Covers push (layer upload + manifest) and
        # layer existence checks (BatchCheckLayerAvailability, GetDownloadUrlForLayer,
        # BatchGetImage) which Docker uses to avoid re-uploading unchanged layers.
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "arn:aws:ecr:eu-central-1:${data.aws_caller_identity.current.account_id}:repository/petclinic-*"
      },
    ]
  })
}
