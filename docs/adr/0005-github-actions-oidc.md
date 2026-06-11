# ADR-0005: GitHub Actions with OIDC Federation for CI Authentication

**Status:** Accepted
**Date:** 2026-06-08
**Jira:** PETPLAT-52

## Context

The CI pipeline (GitHub Actions) needs to push Docker images to Amazon ECR. This requires authenticating to AWS. There are two approaches:

1. **Long-lived IAM access keys** stored as GitHub Secrets — simple to set up, but static credentials that never expire, vulnerable to secret exposure, and violate least-privilege because they must be stored long-term.

2. **OIDC federation** — GitHub Actions requests a short-lived JWT from GitHub's OIDC provider. AWS IAM verifies the JWT signature against the GitHub OIDC thumbprint and issues temporary STS credentials via `AssumeRoleWithWebIdentity`. No static secrets needed.

The project security rules explicitly prohibit committing credentials to Git. Long-lived IAM keys stored in GitHub Secrets are effectively long-lived credentials that could be leaked via log output, compromised repos, or supply-chain attacks on GitHub Actions.

## Decision

Use **GitHub Actions OIDC federation** to authenticate CI workflows to AWS.

The implementation:
- `aws_iam_openid_connect_provider` resource registers GitHub's OIDC provider (`token.actions.githubusercontent.com`) in AWS IAM.
- `aws_iam_role` (`petclinic-github-actions-role`) with a trust policy scoped to a single repository and branch: `repo:{owner}/spring-petclinic-microservices:ref:refs/heads/main` (set via the `github_repo` Terraform variable).
- Inline IAM policy grants only the ECR push permissions needed: `GetAuthorizationToken` on `*` (required by ECR), plus `BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, `GetDownloadUrlForLayer`, `BatchGetImage` scoped to `arn:aws:ecr:eu-central-1:{account}:repository/petclinic-*`.
- CI workflow uses `aws-actions/configure-aws-credentials@v4` with `role-to-assume` set from the `AWS_ROLE_ARN` secret (contains the role ARN, not a credential).

The Terraform module lives at `terraform/modules/github-oidc/` and is called from `terraform/environments/dev/main.tf`. The IAM role ARN is exported as `github_actions_role_arn`.

## Consequences

**Positive:**
- No static AWS credentials stored anywhere — tokens are ephemeral (15 minutes by default).
- Trust policy is narrow: only `main` branch of the app repo can assume the role. PR branches, forks, and other repos cannot.
- ECR permissions are the minimum required; no ability to create/delete repositories, modify policies, or access other AWS services.
- Credentials cannot be leaked from GitHub Secrets because none are stored.
- Audit trail: every role assumption is logged in CloudTrail with the GitHub workflow run metadata in the `ExternalId`/`SourceIdentity` context.

**Negative:**
- Initial Terraform setup is more complex than creating an IAM user.
- If the app repo is renamed or the main branch is renamed, the trust policy must be updated in Terraform. Forgetting this breaks CI silently (auth failure at runtime, not at plan time).
- The OIDC provider thumbprint must be kept current as GitHub rotates their certificate chain. Terraform variable `thumbprint_list` pins this and must be updated when GitHub announces rotation.

**Trade-offs accepted:**
- The `GetAuthorizationToken` action cannot be scoped to specific repositories (it is a global ECR action). This is a known ECR API limitation — every ECR client needs this permission to get the Docker login token.
