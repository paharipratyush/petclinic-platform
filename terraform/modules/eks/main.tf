locals {
  cluster_name = "${var.project}-${var.environment}"

  base_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# ── Cluster IAM Role ──────────────────────────────────────────────────────────

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = merge(local.base_tags, { Name = "${local.cluster_name}-cluster-role" })
}

resource "aws_iam_role_policy_attachment" "cluster_eks_cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [var.cluster_sg_id]
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  # api + audit + authenticator per technical spec (PETPLAT-12)
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  tags = merge(local.base_tags, { Name = local.cluster_name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster_eks_cluster_policy,
  ]
}

# ── OIDC Provider (required for IRSA) ────────────────────────────────────────
#
# EKS exposes an OIDC issuer URL per cluster. Registering it as an IAM OIDC
# provider lets pods assume IAM roles via projected service account tokens
# (IRSA — IAM Roles for Service Accounts).

data "tls_certificate" "cluster_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "main" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(local.base_tags, { Name = "${local.cluster_name}-oidc-provider" })
}

# ── Node IAM Role ─────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = merge(local.base_tags, { Name = "${local.cluster_name}-node-role" })
}

resource "aws_iam_role_policy_attachment" "node_eks_worker_node_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_eks_cni_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_read_only" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ── Node Launch Template ──────────────────────────────────────────────────────
#
# Using a launch template is the only way to attach a custom security group
# (var.node_sg_id) to managed node group instances. EKS still adds its own
# primary cluster SG; the launch template SG is applied in addition to it.
# disk_size must be set here (not on the node group) when using a launch template.

resource "aws_launch_template" "node" {
  name_prefix = "${local.cluster_name}-node-"

  # Attach the VPC module's node security group to every node instance.
  # EKS adds the cluster primary SG automatically alongside this.
  vpc_security_group_ids = [var.node_sg_id]

  block_device_mappings {
    device_name = "/dev/xvda" # root volume on AL2 ARM64 AMIs
    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp2"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.base_tags, { Name = "${local.cluster_name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.base_tags, { Name = "${local.cluster_name}-node-volume" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Managed Node Group ────────────────────────────────────────────────────────

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  instance_types = var.node_instance_types
  ami_type       = var.node_ami_type
  # ON_DEMAND to use the Graviton free trial (t4g.small, 750 hrs/month until Dec 2026)
  capacity_type = "ON_DEMAND"
  # disk_size is set in the launch template, not here

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }

  tags = merge(local.base_tags, { Name = "${local.cluster_name}-nodes" })

  depends_on = [
    aws_iam_role_policy_attachment.node_eks_worker_node_policy,
    aws_iam_role_policy_attachment.node_eks_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_read_only,
  ]
}

# ── kubectl Access Entries ────────────────────────────────────────────────────
#
# Always grants the deploying IAM principal cluster-admin (PETPLAT-14).
# Additional principals can be added via admin_iam_arns. The deploying
# principal is always included so `kubectl get nodes` works immediately after
# terraform apply without any manual configuration.

locals {
  all_admin_arns = distinct(concat(
    [data.aws_caller_identity.current.arn],
    var.admin_iam_arns,
  ))
}

resource "aws_eks_access_entry" "admin" {
  for_each = toset(local.all_admin_arns)

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = local.base_tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(local.all_admin_arns)

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# ── EBS CSI Driver IRSA Role ──────────────────────────────────────────────────
#
# The EBS CSI driver needs permission to create/attach/detach EBS volumes.
# IRSA scopes these permissions to the ebs-csi-controller-sa service account
# in kube-system — no node-level IAM permissions required.

locals {
  oidc_url_stripped = trimprefix(aws_iam_openid_connect_provider.main.url, "https://")
}

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.main.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url_stripped}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url_stripped}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.cluster_name}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = merge(local.base_tags, { Name = "${local.cluster_name}-ebs-csi-role" })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ── EKS Managed Add-ons ───────────────────────────────────────────────────────
#
# Versions are pinned — never use "latest". To find the latest compatible version:
#   aws eks describe-addon-versions --kubernetes-version 1.34 --addon-name <name>
#
# Upgrade deliberately by updating the addon_version_* variables.

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = var.addon_version_coredns
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.base_tags, { Name = "${local.cluster_name}-coredns" })

  # CoreDNS runs as a Deployment — nodes must exist first
  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = var.addon_version_kube_proxy
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.base_tags, { Name = "${local.cluster_name}-kube-proxy" })
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = var.addon_version_vpc_cni
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.base_tags, { Name = "${local.cluster_name}-vpc-cni" })
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = var.addon_version_ebs_csi
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.base_tags, { Name = "${local.cluster_name}-ebs-csi-driver" })

  depends_on = [aws_eks_node_group.main]
}
