#!/usr/bin/env bash
# Hook: block-destroy.sh (PreToolUse on Bash)
# Purpose: Prevents 'terraform destroy' from running. This is a HARD BLOCK.
# Why: Destroy is irreversible. In a shared AWS account, accidental destroy
#      can delete VPCs, EKS clusters, RDS databases — causing hours of downtime.
# How: Reads the tool input JSON from stdin, extracts the command, checks for
#      'terraform destroy' or 'terragrunt destroy'. Exits 2 to deny execution.

set -euo pipefail

# Claude Code passes tool input as JSON on stdin
INPUT=$(cat)

# Extract the command field from the JSON payload
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# If no command found, allow (not a Bash tool call we care about)
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Check for terraform/terragrunt destroy commands
# Match: terraform destroy, terragrunt destroy, terraform apply -destroy, with any flags
if echo "$COMMAND" | grep -qE '(terraform|terragrunt)\s+destroy'; then
  echo "BLOCKED: 'terraform destroy' is not allowed via Claude Code."
  echo ""
  echo "Destroying infrastructure must be done manually with explicit human oversight:"
  echo "  1. Run 'terraform plan -destroy' to review what will be destroyed"
  echo "  2. Review the plan carefully"
  echo "  3. Run 'terraform destroy' directly in your terminal (not via Claude)"
  echo ""
  echo "This safety hook exists because destroy is irreversible and can cause"
  echo "significant downtime if run accidentally."
  exit 2
fi

# Also catch 'terraform apply -destroy' (alternative destroy syntax)
if echo "$COMMAND" | grep -qE '(terraform|terragrunt)\s+apply\s+.*(--|-){1}destroy'; then
  echo "BLOCKED: 'terraform apply -destroy' is equivalent to 'terraform destroy'."
  echo ""
  echo "This syntax destroys all resources. Use your terminal directly if intentional."
  exit 2
fi

# Block kubectl delete namespace on production
if echo "$COMMAND" | grep -qE 'kubectl\s+delete\s+(namespace|ns)\s+petclinic-prod'; then
  echo "BLOCKED: Deleting the production namespace is not allowed via Claude Code."
  echo ""
  echo "This would destroy ALL resources in petclinic-prod (deployments, services,"
  echo "configmaps, secrets, ingress, PVCs — everything)."
  echo ""
  echo "If you need to do this, run it directly in your terminal with full awareness."
  exit 2
fi

# Block kubectl delete of critical resource types in production namespace
# This catches: kubectl delete deployment/service/ingress/secret/configmap/pvc in petclinic-prod
if echo "$COMMAND" | grep -qE 'kubectl\s+delete\s+(deployment|deploy|service|svc|ingress|ing|secret|configmap|cm|pvc|persistentvolumeclaim|daemonset|ds|statefulset|sts)\b' && \
   echo "$COMMAND" | grep -qE '(-n|--namespace)[= ]?petclinic-prod'; then
  RESOURCE_TYPE=$(echo "$COMMAND" | grep -oE '(deployment|deploy|service|svc|ingress|ing|secret|configmap|cm|pvc|persistentvolumeclaim|daemonset|ds|statefulset|sts)' | head -1)
  echo "BLOCKED: 'kubectl delete ${RESOURCE_TYPE}' in petclinic-prod is not allowed via Claude Code."
  echo ""
  echo "Deleting resources in production can cause downtime. If intentional:"
  echo "  1. Run the command directly in your terminal"
  echo "  2. Verify the impact first: kubectl get ${RESOURCE_TYPE} -n petclinic-prod"
  exit 2
fi

# Allow all other commands
exit 0
