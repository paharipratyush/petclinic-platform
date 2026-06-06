output "endpoint" {
  description = "RDS instance hostname (use in JDBC URL: jdbc:mysql://{endpoint}:3306/petclinic)"
  value       = aws_db_instance.main.address
}

output "port" {
  description = "RDS instance port (always 3306 for MySQL)"
  value       = aws_db_instance.main.port
}

output "db_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.main.identifier
}

output "db_name" {
  description = "Name of the initial database created on the instance"
  value       = aws_db_instance.main.db_name
}

output "secret_arn" {
  description = "Secrets Manager ARN for RDS credentials (used by External Secrets Operator in E-7)"
  value       = aws_secretsmanager_secret.rds_credentials.arn
  sensitive   = true
}

output "secret_name" {
  description = "Secrets Manager secret name for RDS credentials"
  value       = aws_secretsmanager_secret.rds_credentials.name
  sensitive   = true
}
