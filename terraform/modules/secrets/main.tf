resource "aws_secretsmanager_secret" "openai_api_key" {
  name                    = "petclinic/${var.environment}/openai-api-key"
  description             = "OpenAI API key for the GenAI service (petclinic-${var.environment})"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(var.tags, {
    Component = "secrets"
  })
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id     = aws_secretsmanager_secret.openai_api_key.id
  secret_string = var.openai_api_key
}
