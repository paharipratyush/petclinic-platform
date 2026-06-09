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

# ── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.base_tags, {
    Name = "${var.project}-${var.environment}-vpc"
  })
}

# ── Public Subnets (one per AZ) ───────────────────────────────────────────────

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.base_tags, {
    Name                                          = "${var.project}-${var.environment}-public-${var.availability_zones[count.index]}"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
    # Karpenter uses this tag to discover which subnets to launch nodes into.
    # If missing, EC2NodeClass subnetSelectorTerms finds no subnets and provisioning fails silently.
    "karpenter.sh/discovery" = local.cluster_name
  })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.base_tags, {
    Name = "${var.project}-${var.environment}-igw"
  })
}

# ── Route Table (single public route table, 0.0.0.0/0 → IGW) ─────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.base_tags, {
    Name = "${var.project}-${var.environment}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Security Groups ───────────────────────────────────────────────────────────
#
# Each SG is defined here with no inline rules. All ingress/egress rules are
# added via separate aws_security_group_rule resources below. This is required
# because the four SGs reference each other (e.g. cluster→node, node→alb), which
# would create Terraform circular-dependency errors if rules were inline.
#
# In this all-public subnet design (ADR-0001) these SGs are the primary access
# control boundary — treat them like a firewall.

# Protects the EKS API server. Only worker nodes can reach it (port 443).
resource "aws_security_group" "eks_cluster" {
  name        = "${var.project}-${var.environment}-eks-cluster-sg"
  description = "EKS control plane: API server access from worker nodes only"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.base_tags, {
    Name = "${var.project}-${var.environment}-eks-cluster-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Attached to every EC2 worker node. The `owned` tag tells the EKS cluster
# this SG belongs to it, which is required for managed node groups.
resource "aws_security_group" "eks_node" {
  name        = "${var.project}-${var.environment}-eks-node-sg"
  description = "EKS worker nodes: node-to-node, control-plane-to-node, and ALB-to-node traffic"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.base_tags, {
    Name                                          = "${var.project}-${var.environment}-eks-node-sg"
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
    # Karpenter uses this tag to discover the security group to attach to new nodes.
    # If missing, EC2NodeClass securityGroupSelectorTerms finds no SGs — nodes launch
    # with no security group and cannot join the cluster.
    "karpenter.sh/discovery" = local.cluster_name
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Locked to MySQL port 3306 from EKS nodes only. No public access, ever.
resource "aws_security_group" "rds" {
  name        = "${var.project}-${var.environment}-rds-sg"
  description = "RDS MySQL: port 3306 from EKS nodes only, no public access"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.base_tags, {
    Name = "${var.project}-${var.environment}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# The only internet-facing SG. Accepts HTTP/HTTPS from anywhere; egress is
# scoped to EKS nodes (port 8080 for target-type: ip pod traffic and health checks).
resource "aws_security_group" "alb" {
  name        = "${var.project}-${var.environment}-alb-sg"
  description = "ALB: HTTP/HTTPS from internet, egress to EKS nodes on pod port 8080"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.base_tags, {
    Name = "${var.project}-${var.environment}-alb-sg"
  })
}

# ── EKS Cluster SG Rules ──────────────────────────────────────────────────────

# Nodes talk to the API server over HTTPS (kubectl, kubelet bootstrap, IRSA token exchange).
resource "aws_security_group_rule" "cluster_ingress_nodes_443" {
  type                     = "ingress"
  description              = "API server access from worker nodes"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_node.id
}

# Control plane needs to reach AWS services (ECR, STS, CloudWatch, S3).
resource "aws_security_group_rule" "cluster_egress_all" {
  type              = "egress"
  description       = "Outbound to AWS services and the internet"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_cluster.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# ── EKS Node SG Rules ─────────────────────────────────────────────────────────

# protocol = "-1" (all ports) is intentional: the control plane pushes kubelet
# commands, exec/logs streams, and port-forward traffic through this path.
resource "aws_security_group_rule" "node_ingress_cluster_all" {
  type                     = "ingress"
  description              = "All traffic from EKS control plane (kubelet, exec, logs, port-forward)"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.eks_cluster.id
}

# Pods on different nodes communicate via the VPC CNI; this rule allows
# cross-node pod traffic and kube-proxy rule synchronisation.
resource "aws_security_group_rule" "node_ingress_self" {
  type              = "ingress"
  description       = "Inter-node traffic (pod-to-pod via VPC CNI, kube-proxy sync)"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_node.id
  self              = true
}

# Explicit kubelet API rule per the technical spec. Although node_ingress_cluster_all
# already covers all ports from the cluster SG, this rule is kept as specified.
resource "aws_security_group_rule" "node_ingress_kubelet" {
  type                     = "ingress"
  description              = "Kubelet API from control plane"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.eks_cluster.id
}

# NodePort range kept for compatibility; primary traffic path is target-type: ip (see below).
resource "aws_security_group_rule" "node_ingress_nodeport_from_alb" {
  type                     = "ingress"
  description              = "NodePort range from ALB (fallback for target-type: instance)"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.alb.id
}

# Required for target-type: ip. The ALB registers pod ENI IPs directly as targets
# and sends traffic to the container port, bypassing NodePort entirely.
resource "aws_security_group_rule" "node_ingress_pod_from_alb" {
  type                     = "ingress"
  description              = "ALB to pod port 8080 (target-type: ip, direct pod routing)"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.alb.id
}

# Nodes pull images from ECR, call STS for IRSA, and send metrics to CloudWatch.
resource "aws_security_group_rule" "node_egress_all" {
  type              = "egress"
  description       = "Outbound to ECR, STS, S3, CloudWatch, and the internet"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_node.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# ── RDS SG Rules ─────────────────────────────────────────────────────────────

# Only EKS nodes (running the three DB-backed services) can reach MySQL.
# No 0.0.0.0/0 ingress and no explicit egress — RDS never initiates
# outbound connections; stateful SG tracking handles TCP responses automatically.
resource "aws_security_group_rule" "rds_ingress_nodes_mysql" {
  type                     = "ingress"
  description              = "MySQL from EKS nodes only"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.eks_node.id
}

# ── ALB SG Rules ─────────────────────────────────────────────────────────────

# HTTP is accepted so the ALB can redirect it to HTTPS (redirect is configured
# in the Ingress resource annotations, not here at the SG layer).
resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  description       = "HTTP from internet (redirected to HTTPS by ALB listener rule)"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "alb_ingress_https" {
  type              = "ingress"
  description       = "HTTPS from internet"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# Retained for target-type: instance fallback. Primary path is port 8080 via target-type: ip.
resource "aws_security_group_rule" "alb_egress_nodeport" {
  type                     = "egress"
  description              = "NodePort range egress (target-type: instance fallback)"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.eks_node.id
}

# ALB health-checks the api-gateway pod directly on its container port.
resource "aws_security_group_rule" "alb_egress_health_check" {
  type                     = "egress"
  description              = "Health check to api-gateway container port 8080"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.eks_node.id
}

# ── Default SG Lockdown ───────────────────────────────────────────────────────
#
# Every VPC gets a default security group from AWS that allows all traffic
# between members of that SG. Locking it down (no rules) prevents any resource
# from accidentally using it and getting unintended open access.
resource "aws_default_security_group" "lockdown" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.base_tags, {
    Name = "${var.project}-${var.environment}-default-sg-locked"
  })
}
