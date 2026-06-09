#!/usr/bin/env bash
# Install ArgoCD on the EKS cluster at the pinned version in VERSION file.
# Run from repo root: bash k8s/argocd/install/install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION")

echo "Installing ArgoCD ${VERSION}..."

kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
# Use --server-side + --force-conflicts to handle large CRD schemas and re-run safety
# -n argocd is required: install.yaml does not embed namespace in resource metadata
kubectl apply --server-side --force-conflicts -n argocd -f "$SCRIPT_DIR/install.yaml"

echo "Waiting for ArgoCD CRDs to be established..."
kubectl wait --for=condition=Established crd/applications.argoproj.io crd/applicationsets.argoproj.io crd/appprojects.argoproj.io --timeout=60s

echo "Waiting for ArgoCD deployments to become ready..."
kubectl wait deployment -n argocd \
  argocd-server argocd-repo-server argocd-applicationset-controller argocd-notifications-controller \
  --for=condition=Available --timeout=300s

echo ""
echo "ArgoCD ${VERSION} installed."
echo ""
echo "Retrieve the initial admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "Access the UI via port-forward:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "  Then open: https://localhost:8443"
echo ""
echo "IMPORTANT: Change the admin password after first login."
echo "  argocd login localhost:8443 --username admin --insecure"
echo "  argocd account update-password"
