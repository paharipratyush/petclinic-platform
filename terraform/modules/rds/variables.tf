variable "project" {
  description = "Project name prefix used in resource names and tags"
  type        = string
  default     = "petclinic"
}

variable "environment" {
  description = "Environment (dev or prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be 'dev' or 'prod'."
  }
}

variable "subnet_ids" {
  description = "Subnet IDs for the DB subnet group (must span at least 2 AZs)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "At least 2 subnet IDs are required for the DB subnet group."
  }
}

variable "security_group_id" {
  description = "Security group ID to attach to the RDS instance (RDS SG from VPC module)"
  type        = string
}

variable "db_name" {
  description = "Initial database name to create on the RDS instance"
  type        = string
  default     = "petclinic"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "petclinic"
  sensitive   = true
}

variable "instance_class" {
  description = "RDS instance class (db.t4g.micro is ARM/Graviton and RDS free-tier eligible)"
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial allocated storage in GB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Maximum storage in GB for autoscaling (set equal to allocated_storage to disable autoscaling)"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Enable Multi-AZ deployment (false for cost optimization; enable for production HA)"
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Number of days to retain automated backups (0 disables backups; required for AWS free-tier accounts; use 30 for prod)"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 0 and 35."
  }
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on instance deletion (true for dev, false for prod)"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Enable deletion protection on the RDS instance"
  type        = bool
  default     = false
}

variable "secret_recovery_window_in_days" {
  description = "Days Secrets Manager waits before permanently deleting the RDS credentials secret. Use 0 for dev (force delete — allows same-day destroy+recreate), 30 for prod. Valid: 0 or 7–30."
  type        = number
  default     = 30

  validation {
    condition     = var.secret_recovery_window_in_days == 0 || (var.secret_recovery_window_in_days >= 7 && var.secret_recovery_window_in_days <= 30)
    error_message = "secret_recovery_window_in_days must be 0 (force delete) or between 7 and 30."
  }
}

variable "tags" {
  description = "Additional tags to merge with default resource tags"
  type        = map(string)
  default     = {}
}
