locals {
  identifier = "${var.project}-${var.environment}-mysql"

  base_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

# ── Master password ───────────────────────────────────────────────────────────
# Excludes @ / \ " ' ` which can break connection strings or shell quoting.
# Password is stored in Secrets Manager — never in plaintext state.

resource "random_password" "master" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]<>?"
}

# ── Secrets Manager — RDS credentials ────────────────────────────────────────
# Single JSON secret consumed by External Secrets Operator (PETPLAT-33).
# Name follows forward-slash convention: petclinic/{env}/rds-credentials

resource "aws_secretsmanager_secret" "rds_credentials" {
  name                    = "petclinic/${var.environment}/rds-credentials"
  description             = "RDS MySQL master credentials for petclinic-${var.environment}"
  recovery_window_in_days = var.secret_recovery_window_in_days

  tags = merge(local.base_tags, { Name = "petclinic/${var.environment}/rds-credentials" })
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.master.result
  })
}

# ── DB Subnet Group ───────────────────────────────────────────────────────────
# Must span at least 2 AZs even for single-AZ instances.

resource "aws_db_subnet_group" "main" {
  name        = local.identifier
  description = "DB subnet group for ${local.identifier}"
  subnet_ids  = var.subnet_ids

  tags = merge(local.base_tags, { Name = local.identifier })
}

# ── DB Parameter Group ────────────────────────────────────────────────────────
# utf8mb4 + utf8mb4_unicode_ci — full Unicode (including emoji) for all string cols.

resource "aws_db_parameter_group" "main" {
  name        = local.identifier
  family      = "mysql8.0"
  description = "MySQL 8.0 parameters for ${local.identifier}"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  tags = merge(local.base_tags, { Name = local.identifier })
}

# ── RDS Instance ──────────────────────────────────────────────────────────────
# db.t4g.micro (ARM/Graviton) — AWS RDS free tier (750 hrs/month, 12 months).
# publicly_accessible = false — only reachable from EKS nodes via the RDS SG
# (which allows 3306 from the EKS node SG only).

resource "aws_db_instance" "main" {
  identifier = local.identifier

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.db_username
  password = random_password.master.result

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp2"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.main.name

  multi_az            = var.multi_az
  publicly_accessible = false

  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.identifier}-final"
  deletion_protection       = var.deletion_protection

  tags = merge(local.base_tags, { Name = local.identifier })

  depends_on = [aws_secretsmanager_secret_version.rds_credentials]
}
