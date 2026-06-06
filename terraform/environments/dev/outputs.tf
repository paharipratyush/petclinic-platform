output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "eks_cluster_sg_id" {
  description = "EKS cluster security group ID"
  value       = module.vpc.eks_cluster_sg_id
}

output "eks_node_sg_id" {
  description = "EKS node security group ID"
  value       = module.vpc.eks_node_sg_id
}

output "rds_sg_id" {
  description = "RDS security group ID"
  value       = module.vpc.rds_sg_id
}

output "alb_sg_id" {
  description = "ALB security group ID"
  value       = module.vpc.alb_sg_id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = module.vpc.internet_gateway_id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks.cluster_ca_certificate
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN (used in downstream IRSA role trust policies)"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL without https:// (used in IRSA trust policy conditions)"
  value       = module.eks.oidc_provider_url
}

output "node_group_name" {
  description = "Managed node group name"
  value       = module.eks.node_group_name
}

output "ebs_csi_role_arn" {
  description = "IRSA role ARN for the EBS CSI driver"
  value       = module.eks.ebs_csi_role_arn
}

output "kubeconfig_command" {
  description = "Command to configure kubectl for this cluster"
  value       = module.eks.kubeconfig_command
}

output "ecr_registry_url" {
  description = "ECR registry base URL for docker login and image tagging"
  value       = module.ecr.registry_url
}

output "ecr_repository_urls" {
  description = "Map of service name to full ECR repository URL"
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  description = "Map of service name to ECR repository ARN (used for IAM push policies in E-10)"
  value       = module.ecr.repository_arns
}

output "rds_endpoint" {
  description = "RDS MySQL hostname (use in JDBC URL: jdbc:mysql://{endpoint}:3306/petclinic)"
  value       = module.rds.endpoint
  sensitive   = true
}

output "rds_port" {
  description = "RDS MySQL port"
  value       = module.rds.port
}

output "rds_db_instance_id" {
  description = "RDS instance identifier"
  value       = module.rds.db_instance_id
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN for RDS credentials (used by External Secrets Operator)"
  value       = module.rds.secret_arn
  sensitive   = true
}

output "rds_secret_name" {
  description = "Secrets Manager secret name for RDS credentials"
  value       = module.rds.secret_name
  sensitive   = true
}

output "rds_db_name" {
  description = "Database name on the RDS instance (used in K8s ConfigMaps and JDBC URLs)"
  value       = module.rds.db_name
}

output "certificate_arn" {
  description = "ACM wildcard certificate ARN — used in Ingress annotation and by install-lb-controller.sh"
  value       = module.dns.certificate_arn
}

output "lb_controller_role_arn" {
  description = "IRSA role ARN for AWS Load Balancer Controller — passed to Helm via install-lb-controller.sh"
  value       = aws_iam_role.lb_controller.arn
}

output "app_url" {
  description = "Application URL (accessible after DNS propagation and ALB provisioning)"
  value       = "https://petclinic-dev.${var.domain_name}"
}

output "eso_role_arn" {
  description = "IRSA role ARN for External Secrets Operator — passed to Helm via install-eso.sh"
  value       = aws_iam_role.eso.arn
}

output "openai_secret_arn" {
  description = "Secrets Manager ARN for the OpenAI API key"
  value       = module.secrets.openai_secret_arn
  sensitive   = true
}
