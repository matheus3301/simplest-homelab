#!/bin/bash
set -e

VAULT_NAME="Kubernetes"
SERVICE_ACCOUNT_NAME="homelab-k8s"
NAMESPACE="external-secrets"
SECRET_NAME="onepassword-service-account"

echo "Setting up 1Password for External Secrets..."

# Check if op CLI is installed
if ! command -v op &> /dev/null; then
  echo "Error: 1Password CLI (op) is not installed"
  echo "Install it from: https://developer.1password.com/docs/cli/get-started/"
  exit 1
fi

# Check if logged in
if ! op account list &> /dev/null; then
  echo "Error: Not logged into 1Password CLI"
  echo "Run: op signin"
  exit 1
fi

# List accounts and let user choose
echo ""
echo "Available 1Password accounts:"
op account list --format=json | jq -r '.[] | "\(.account_uuid) - \(.email) (\(.url))"'
echo ""
read -p "Enter account UUID (or press enter to use default): " ACCOUNT_UUID

# Build op command args
OP_ARGS=()
if [[ -n "$ACCOUNT_UUID" ]]; then
  OP_ARGS+=(--account "$ACCOUNT_UUID")
fi

# Create namespace if not exists
kubectl create namespace $NAMESPACE 2>/dev/null || true

# Check if service account already exists
if kubectl get secret $SECRET_NAME -n $NAMESPACE &> /dev/null; then
  echo "Secret $SECRET_NAME already exists in $NAMESPACE"
  read -p "Do you want to recreate it? (y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted"
    exit 0
  fi
  kubectl delete secret $SECRET_NAME -n $NAMESPACE
fi

# Create service account and capture token
echo "Creating 1Password service account..."
TOKEN=$(op service-account create "$SERVICE_ACCOUNT_NAME" --vault "$VAULT_NAME:read_items" "${OP_ARGS[@]}" --raw)

if [[ -z "$TOKEN" ]]; then
  echo "Error: Failed to create service account or capture token"
  echo "If the service account already exists, revoke it in 1Password and try again"
  exit 1
fi

# Create Kubernetes secret
echo "Creating Kubernetes secret..."
kubectl create secret generic $SECRET_NAME \
  -n $NAMESPACE \
  --from-literal=token="$TOKEN"

echo ""
echo "1Password setup complete!"
echo "Service account: $SERVICE_ACCOUNT_NAME"
echo "Vault: $VAULT_NAME"
echo "Secret: $NAMESPACE/$SECRET_NAME"
