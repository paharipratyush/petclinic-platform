variable "project" {
  description = "Project name"
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

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.34"
}

variable "subnet_ids" {
  description = "Subnet IDs for the EKS cluster and managed node group"
  type        = list(string)
}

variable "cluster_sg_id" {
  description = "Security group ID for the EKS control plane"
  type        = string
}

variable "node_sg_id" {
  description = "Security group ID for EKS worker nodes"
  type        = string
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["t4g.small"]
}

variable "node_ami_type" {
  description = "AMI type for managed node group (AL2023_ARM_64_STANDARD for Graviton t4g)"
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of nodes in the managed node group"
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Desired number of nodes in the managed node group"
  type        = number
  default     = 2
}

variable "node_disk_size" {
  description = "EBS disk size in GB per node (20 GB fits within the 30 GB EBS free tier)"
  type        = number
  default     = 20
}

variable "admin_iam_arns" {
  description = "IAM user/role ARNs granted cluster-admin via EKS access entries. The cluster creator already has implicit admin access with API_AND_CONFIG_MAP mode."
  type        = list(string)
  default     = []
}

# ── Add-on versions ───────────────────────────────────────────────────────────
# Pinned per spec — never use "latest". Update deliberately during K8s upgrades.
# Find compatible versions:
#   aws eks describe-addon-versions --kubernetes-version 1.34 --addon-name <name>

variable "addon_version_coredns" {
  description = "Pinned version for the coredns EKS managed add-on"
  type        = string
  default     = "v1.12.4-eksbuild.10"
}

variable "addon_version_kube_proxy" {
  description = "Pinned version for the kube-proxy EKS managed add-on"
  type        = string
  default     = "v1.34.6-eksbuild.2"
}

variable "addon_version_vpc_cni" {
  description = "Pinned version for the vpc-cni EKS managed add-on"
  type        = string
  default     = "v1.20.5-eksbuild.1"
}

variable "addon_version_ebs_csi" {
  description = "Pinned version for the aws-ebs-csi-driver EKS managed add-on"
  type        = string
  default     = "v1.61.1-eksbuild.1"
}

variable "eks_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint. Default allows any IP; restrict to known CIDRs in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Additional tags to merge with default resource tags"
  type        = map(string)
  default     = {}
}
