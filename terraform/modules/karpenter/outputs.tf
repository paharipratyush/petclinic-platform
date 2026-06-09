output "karpenter_role_arn" {
  description = "ARN of the Karpenter controller IRSA role. Annotate the karpenter ServiceAccount with this ARN."
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_queue_name" {
  description = "Name of the SQS interruption queue. Pass to Karpenter Helm chart as settings.interruptionQueue."
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "karpenter_instance_profile_name" {
  description = "Name of the IAM instance profile for Karpenter-launched nodes. Referenced in EC2NodeClass.spec.instanceProfile."
  value       = aws_iam_instance_profile.karpenter_node.name
}
