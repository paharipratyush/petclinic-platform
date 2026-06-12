resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "petclinic/${var.environment}/grafana-admin"
  description             = "Grafana admin credentials for the petclinic-${var.environment} monitoring stack"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge({
    Project     = "petclinic"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags, {
    Component = "secrets"
  })
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    admin-user     = "admin"
    admin-password = var.grafana_admin_password
  })
}

resource "aws_secretsmanager_secret" "openai_api_key" {
  name                    = "petclinic/${var.environment}/openai-api-key"
  description             = "OpenAI API key for the GenAI service (petclinic-${var.environment})"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge({
    Project     = "petclinic"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags, {
    Component = "secrets"
  })
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id     = aws_secretsmanager_secret.openai_api_key.id
  secret_string = var.openai_api_key
}
