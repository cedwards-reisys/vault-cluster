#!/bin/bash
#
# generate-ca.sh - Generate a self-signed CA and store in Secrets Manager
#
# Must run once per environment BEFORE 'tofu apply'.
# Creates the CA cert/key and stores them in Secrets Manager where
# Terraform reads them as data sources and nodes retrieve them at boot.
#
# Usage: ./generate-ca.sh <cluster-name> <aws-region>
#
# Example:
#   ./generate-ca.sh vault-nonprod-test us-east-1

set -euo pipefail

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <aws-region>}"
AWS_REGION="${2:?Usage: $0 <cluster-name> <aws-region>}"

CERT_SECRET_NAME="${CLUSTER_NAME}/tls/ca-cert"
KEY_SECRET_NAME="${CLUSTER_NAME}/tls/ca-key"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
command -v openssl >/dev/null 2>&1 || { log_error "openssl not found"; exit 1; }
command -v aws >/dev/null 2>&1 || { log_error "aws CLI not found"; exit 1; }

# Check if secrets already exist
cert_exists=false
if aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$CERT_SECRET_NAME" >/dev/null 2>&1; then
    cert_exists=true
    log_warn "Secret '$CERT_SECRET_NAME' already exists."
    echo ""
    read -p "Overwrite existing CA? This will require replacing all nodes. (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Aborted."
        exit 0
    fi
fi

# Generate CA in a temp directory
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

log_info "Generating CA for cluster: $CLUSTER_NAME"

# Generate CA private key
openssl genrsa -out "$WORK_DIR/ca.key" 4096 2>/dev/null

# Generate self-signed CA certificate (10 years validity)
openssl req -new -x509 \
  -days 3650 \
  -key "$WORK_DIR/ca.key" \
  -out "$WORK_DIR/ca.crt" \
  -subj "/CN=${CLUSTER_NAME} CA/O=Vault Cluster/OU=${CLUSTER_NAME}"

log_info "CA generated successfully."

# Display certificate info
echo ""
openssl x509 -in "$WORK_DIR/ca.crt" -text -noout | grep -A2 "Subject:" || true
echo ""

# Store in Secrets Manager
if [ "$cert_exists" = true ]; then
    log_info "Updating existing secrets..."
    aws secretsmanager put-secret-value \
        --region "$AWS_REGION" \
        --secret-id "$CERT_SECRET_NAME" \
        --secret-string "file://$WORK_DIR/ca.crt"

    aws secretsmanager put-secret-value \
        --region "$AWS_REGION" \
        --secret-id "$KEY_SECRET_NAME" \
        --secret-string "file://$WORK_DIR/ca.key"
else
    log_info "Creating secrets in Secrets Manager..."
    aws secretsmanager create-secret \
        --region "$AWS_REGION" \
        --name "$CERT_SECRET_NAME" \
        --description "CA certificate for Vault cluster internal TLS" \
        --secret-string "file://$WORK_DIR/ca.crt" >/dev/null

    aws secretsmanager create-secret \
        --region "$AWS_REGION" \
        --name "$KEY_SECRET_NAME" \
        --description "CA private key for Vault cluster internal TLS" \
        --secret-string "file://$WORK_DIR/ca.key" >/dev/null
fi

log_info "CA cert stored: $CERT_SECRET_NAME"
log_info "CA key stored:  $KEY_SECRET_NAME"
echo ""
log_info "Done. You can now run 'tofu apply' for this environment."
