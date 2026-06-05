output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "public_subnet_cidrs" {
  description = "CIDR blocks of the public subnets"
  value       = aws_subnet.public[*].cidr_block
}

output "eks_cluster_sg_id" {
  description = "Security group ID for the EKS control plane"
  value       = aws_security_group.eks_cluster.id
}

output "eks_node_sg_id" {
  description = "Security group ID for EKS worker nodes"
  value       = aws_security_group.eks_node.id
}

output "rds_sg_id" {
  description = "Security group ID for RDS (MySQL port 3306 from EKS nodes only)"
  value       = aws_security_group.rds.id
}

output "alb_sg_id" {
  description = "Security group ID for the ALB (HTTP/HTTPS from internet)"
  value       = aws_security_group.alb.id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}
