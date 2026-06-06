output "repository_urls" {
  description = "Map of service name to ECR repository URL (e.g., {account}.dkr.ecr.eu-central-1.amazonaws.com/petclinic-dev/api-gateway)"
  value = {
    for name, repo in aws_ecr_repository.services : name => repo.repository_url
  }
}

output "repository_arns" {
  description = "Map of service name to ECR repository ARN"
  value = {
    for name, repo in aws_ecr_repository.services : name => repo.arn
  }
}

output "registry_url" {
  description = "ECR registry base URL for docker login and image tagging (account.dkr.ecr.region.amazonaws.com)"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com"
}
