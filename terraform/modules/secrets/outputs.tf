output "grafana_secret_arn" {
  description = "Secrets Manager ARN for the Grafana admin credentials"
  value       = aws_secretsmanager_secret.grafana_admin.arn
  sensitive   = true
}

output "grafana_secret_name" {
  description = "Secrets Manager secret name for the Grafana admin credentials"
  value       = aws_secretsmanager_secret.grafana_admin.name
  sensitive   = true
}

output "openai_secret_arn" {
  description = "Secrets Manager ARN for the OpenAI API key"
  value       = aws_secretsmanager_secret.openai_api_key.arn
  sensitive   = true
}

output "openai_secret_name" {
  description = "Secrets Manager secret name for the OpenAI API key"
  value       = aws_secretsmanager_secret.openai_api_key.name
  sensitive   = true
}
