data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  instance_profile_name = "${var.project}-${var.environment}-karpenter-node-profile"
  queue_name            = "${var.project}-${var.environment}-karpenter-interruption"
  cluster_arn           = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"

  # Extract the role name from the ARN. Use the last path component so that roles
  # with path prefixes (arn:aws:iam::ACCOUNT:role/path/ROLE_NAME) are handled correctly.
  node_role_name = element(split("/", var.node_role_arn), length(split("/", var.node_role_arn)) - 1)

  common_tags = merge(var.tags, {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# ------- Instance profile for Karpenter-launched nodes -------
# The exact name is referenced in EC2NodeClass.spec.instanceProfile CRD field.

resource "aws_iam_instance_profile" "karpenter_node" {
  name = local.instance_profile_name
  role = local.node_role_name
  # aws_iam_instance_profile does not support tags in AWS — omitted intentionally.
}

# ------- SQS interruption queue -------
# Karpenter reads from this queue to respond to spot interruptions and health events
# before they terminate nodes, allowing graceful pod eviction.

resource "aws_sqs_queue" "karpenter_interruption" {
  name = local.queue_name

  # 20-minute visibility timeout: pods have this window to finish work and reschedule
  # before the interrupted node is actually terminated by AWS.
  visibility_timeout_seconds = 1200

  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = local.common_tags
}

# ------- SQS queue resource policy — EventBridge delivery -------
# Without this policy, EventBridge rules fire but messages never reach the queue.
# Karpenter would be unaware of spot interruptions → abrupt node termination.

data "aws_iam_policy_document" "karpenter_interruption_queue" {
  statement {
    sid    = "AllowEventBridgePublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter_interruption.arn]

    # Confused-deputy guard: restrict to this account so that an EventBridge rule
    # in another AWS account cannot publish to this queue even if it has the URL.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy    = data.aws_iam_policy_document.karpenter_interruption_queue.json
}

# ------- EventBridge rules → SQS (4 event types) -------

resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name        = "${var.project}-${var.environment}-karpenter-spot-interruption"
  description = "Karpenter: EC2 Spot Instance Interruption Warning"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  rule      = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  name        = "${var.project}-${var.environment}-karpenter-rebalance"
  description = "Karpenter: EC2 Instance Rebalance Recommendation"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_rebalance" {
  rule      = aws_cloudwatch_event_rule.karpenter_rebalance.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_instance_state" {
  name        = "${var.project}-${var.environment}-karpenter-instance-state"
  description = "Karpenter: EC2 Instance State-change Notification"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_instance_state" {
  rule      = aws_cloudwatch_event_rule.karpenter_instance_state.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_scheduled_change" {
  name        = "${var.project}-${var.environment}-karpenter-scheduled-change"
  description = "Karpenter: AWS Health Scheduled Change"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_scheduled_change" {
  rule      = aws_cloudwatch_event_rule.karpenter_scheduled_change.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ------- Karpenter controller IAM policy -------

data "aws_iam_policy_document" "karpenter_controller" {
  # EC2 read — Karpenter discovers available instance types, subnets, AMIs, and
  # spot pricing before deciding what to launch.
  statement {
    sid    = "AllowEC2Describe"
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeCapacityReservations",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:DescribeVolumes",
    ]
    resources = ["*"]
  }

  # EC2 write — Karpenter provisions and terminates nodes on demand.
  # resources = "*" is required because launch templates, fleets, and instances
  # are created dynamically and their ARNs are not known at policy creation time.
  # Scoped to the current region to prevent provisioning in unexpected regions.
  # Note: VPC-level scoping (ec2:Vpc condition) would be tighter but requires
  # passing the VPC ID into the module — deferred as a future hardening step.
  statement {
    sid    = "AllowEC2NodeProvisioning"
    effect = "Allow"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DeleteLaunchTemplate",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [data.aws_region.current.name]
    }
  }

  # IAM PassRole — scoped to the specific node IAM role. Using * here would allow
  # Karpenter to launch instances with any role, enabling privilege escalation.
  statement {
    sid       = "AllowPassNodeRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.node_role_arn]
  }

  # IAM: Read the pre-provisioned instance profile.
  # We use `instanceProfile:` in EC2NodeClass (not `role:`), which means Karpenter
  # only reads the profile — it does not create or delete it. Create/Delete/Modify
  # actions are only required when using EC2NodeClass.spec.role (dynamic profile mode).
  # Using the Terraform-managed profile avoids granting CreateInstanceProfile on "*".
  statement {
    sid       = "AllowGetInstanceProfile"
    effect    = "Allow"
    actions   = ["iam:GetInstanceProfile"]
    resources = [aws_iam_instance_profile.karpenter_node.arn]
  }

  # SQS — Karpenter polls this queue for interruption signals, then cordons and
  # drains the affected node before AWS terminates it.
  statement {
    sid    = "AllowSQSInterruption"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.karpenter_interruption.arn]
  }

  # SSM — Karpenter resolves the latest EKS-optimized AMI ID via SSM parameter store.
  statement {
    sid     = "AllowSSMGetAMIParameter"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}::parameter/aws/service/eks/optimized-ami/*",
    ]
  }

  # Pricing — Karpenter calls the Pricing API to determine the cheapest instance
  # type/AZ combination for on-demand and spot nodes.
  statement {
    sid       = "AllowPricingGetProducts"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  # EKS — Karpenter reads cluster details (API endpoint, CA cert) to bootstrap nodes.
  statement {
    sid       = "AllowEKSDescribeCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [local.cluster_arn]
  }
}

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.project}-${var.environment}-karpenter-controller-policy"
  description = "IAM policy for Karpenter controller on petclinic-${var.environment}"
  policy      = data.aws_iam_policy_document.karpenter_controller.json

  tags = local.common_tags
}

# ------- Karpenter controller IRSA role -------

data "aws_iam_policy_document" "karpenter_controller_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.project}-${var.environment}-karpenter-role"
  description        = "IRSA role for Karpenter controller (petclinic-${var.environment})"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}
