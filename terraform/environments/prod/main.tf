module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = var.environment

  vpc_cidr = "10.1.0.0/16"

  public_subnet_cidrs = [
    "10.1.1.0/24",
    "10.1.2.0/24",
  ]

  availability_zones = [
    "eu-central-1a",
    "eu-central-1b",
  ]
}

module "ecr" {
  source = "../../modules/ecr"

  project     = var.project
  environment = var.environment

  service_names = [
    "config-server",
    "discovery-server",
    "api-gateway",
    "customers-service",
    "visits-service",
    "vets-service",
    "genai-service",
    "admin-server",
  ]

  # IMMUTABLE in prod — deployed image tags cannot be overwritten, ensuring
  # what was tested is exactly what runs
  tag_mutability = "IMMUTABLE"
}

module "rds" {
  source = "../../modules/rds"

  project     = var.project
  environment = var.environment

  subnet_ids        = module.vpc.public_subnet_ids
  security_group_id = module.vpc.rds_sg_id

  # db.t4g.micro (ARM/Graviton) — RDS free tier eligible (750 hrs/month, 12 months)
  # Note: in real production use db.r7g.large with Multi-AZ, gp3 storage
  instance_class          = "db.t4g.micro"
  multi_az                = false
  skip_final_snapshot     = false
  backup_retention_period = 30
  deletion_protection     = true
}

module "eks" {
  source = "../../modules/eks"

  project     = var.project
  environment = var.environment

  subnet_ids    = module.vpc.public_subnet_ids
  cluster_sg_id = module.vpc.eks_cluster_sg_id
  node_sg_id    = module.vpc.eks_node_sg_id

  # t4g.small (ARM/Graviton) — eligible for free trial until Dec 2026
  node_instance_types = ["t4g.small"]
  node_ami_type       = "AL2023_ARM_64_STANDARD"
  node_min_size       = 2
  node_max_size       = 4
  node_desired_size   = 2
}

# ------- E-6: DNS & Ingress (PETPLAT-28, PETPLAT-32) -------

module "dns" {
  source = "../../modules/dns"

  domain_name = var.domain_name

  tags = {
    Component = "networking"
  }
}

# ------- E-6: LB Controller IRSA (PETPLAT-29) -------

data "aws_iam_policy_document" "lb_controller" {
  statement {
    sid       = "CreateServiceLinkedRole"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid    = "DescribeResources"
    effect = "Allow"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools",
      "ec2:GetSecurityGroupsForVpc",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:DescribeListenerAttributes",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "cognito-idp:DescribeUserPoolClient",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ManageEC2SecurityGroups"
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:CreateSecurityGroup",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "TagSecurityGroupOnCreate"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*:*:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }
  }

  statement {
    sid    = "ManageLBControllerSecurityGroups"
    effect = "Allow"
    actions = [
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
    ]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid    = "CreateLoadBalancersAndTargetGroups"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
    ]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid    = "ManageListenersAndRules"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:SetWebAcl",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:AddListenerCertificates",
      "elasticloadbalancing:RemoveListenerCertificates",
      "elasticloadbalancing:ModifyRule",
    ]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid    = "ManageLBControllerResources"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup",
    ]
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid     = "TagLBOnCreate"
    effect  = "Allow"
    actions = ["elasticloadbalancing:AddTags"]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "elasticloadbalancing:CreateAction"
      values   = ["CreateTargetGroup", "CreateLoadBalancer"]
    }
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid    = "ManageTagsOnLBControlledResources"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
    ]
    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["true"]
    }
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid    = "ManageListenerAndRuleTags"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
    ]
  }

  statement {
    sid    = "RegisterDeregisterTargets"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
    ]
    resources = ["arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"]
  }

  statement {
    sid    = "WAFPermissions"
    effect = "Allow"
    actions = [
      "waf-regional:GetWebACL",
      "waf-regional:GetWebACLForResource",
      "waf-regional:AssociateWebACL",
      "waf-regional:DisassociateWebACL",
      "wafv2:GetWebACL",
      "wafv2:GetWebACLForResource",
      "wafv2:AssociateWebACL",
      "wafv2:DisassociateWebACL",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ShieldPermissions"
    effect = "Allow"
    actions = [
      "shield:GetSubscriptionState",
      "shield:DescribeProtection",
      "shield:CreateProtection",
      "shield:DeleteProtection",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lb_controller" {
  name        = "petclinic-${var.environment}-lb-controller-policy"
  description = "IAM policy for AWS Load Balancer Controller on the petclinic-${var.environment} EKS cluster"
  policy      = data.aws_iam_policy_document.lb_controller.json

  tags = {
    Component = "networking"
  }
}

data "aws_iam_policy_document" "lb_controller_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name               = "petclinic-${var.environment}-lb-controller-role"
  description        = "IRSA role for AWS Load Balancer Controller (petclinic-${var.environment})"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume.json

  tags = {
    Component = "networking"
  }
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# ------- E-7: Secrets (PETPLAT-33, PETPLAT-37) -------

data "aws_caller_identity" "current" {}

module "secrets" {
  source = "../../modules/secrets"

  project                  = var.project
  environment              = var.environment
  openai_api_key           = var.openai_api_key
  grafana_admin_password   = var.grafana_admin_password
  recovery_window_in_days  = 30

  tags = {
    Component = "secrets"
  }
}

# ------- E-7: ESO IRSA (PETPLAT-37) -------

data "aws_iam_policy_document" "eso" {
  statement {
    sid    = "SecretsManagerRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:petclinic/${var.environment}/*",
    ]
  }
}

resource "aws_iam_policy" "eso" {
  name        = "petclinic-${var.environment}-eso-policy"
  description = "IAM policy for External Secrets Operator on petclinic-${var.environment}"
  policy      = data.aws_iam_policy_document.eso.json

  tags = {
    Component = "secrets"
  }
}

data "aws_iam_policy_document" "eso_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "petclinic-${var.environment}-eso-role"
  description        = "IRSA role for External Secrets Operator (petclinic-${var.environment})"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json

  tags = {
    Component = "secrets"
  }
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}

# ------- E-6: App DNS record in Cloudflare (PETPLAT-31) -------
# Leave var.alb_dns_name empty on first apply — no DNS record is created yet.
# scripts/install-lb-controller.sh provisions the ALB and automatically calls:
#   terraform apply -var="alb_dns_name=<alb-hostname>"
# which creates this record. The ALB hostname is also stored in SSM at
# /petclinic/{env}/alb-dns-name for reference and disaster recovery.
# See ADR-0004 for why Cloudflare provider is used instead of Route53.

resource "cloudflare_record" "app" {
  count = var.alb_dns_name != "" ? 1 : 0

  zone_id = module.dns.cloudflare_zone_id
  name    = "petclinic"
  content = var.alb_dns_name
  type    = "CNAME"
  ttl     = 1
  proxied = false
}

# ------- E-14: Karpenter node autoscaling (PETPLAT-73) -------

module "karpenter" {
  source = "../../modules/karpenter"

  project     = var.project
  environment = var.environment

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  node_role_arn     = module.eks.node_role_arn

  tags = {
    Component = "scaling"
  }
}

# ------- E-14: AWS Budget alerts (PETPLAT-75) -------
# Three notifications fired on actual (not forecasted) spend: 50%, 80%, 100%.
# Forecasted alerts can fire before money is actually spent — ACTUAL ensures
# the alert only fires when the threshold has genuinely been crossed.

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-${var.environment}-monthly"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"

  time_unit         = "MONTHLY"
  time_period_start = "2025-01-01_00:00"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
