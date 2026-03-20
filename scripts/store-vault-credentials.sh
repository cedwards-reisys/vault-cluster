#!/bin/bash
#
# store-vault-credentials.sh - Store root token and recovery keys in Secrets Manager
#
# Usage: ./scripts/store-vault-credentials.sh <environment>
#
# Prompts for root token and recovery keys, then stores them
# in AWS Secrets Manager for the specified environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ $# -lt 1 ]; then
    echo "Usage: $0 <environment>"
    echo ""
    echo "Examples:"
    echo "  $0 nonprod-test"
    echo "  $0 nonprod"
    echo "  $0 prod"
    exit 1
fi

ENV="$1"

# Validate prerequisites
command -v aws >/dev/null 2>&1 || { log_error "aws CLI not found"; exit 1; }

# Get cluster name and region from tfvars
VAR_FILE="$PROJECT_DIR/terraform/environments/$ENV.tfvars"
if [ ! -f "$VAR_FILE" ]; then
    log_error "Environment file not found: $VAR_FILE"
    exit 1
fi

CLUSTER_NAME=$(grep '^cluster_name' "$VAR_FILE" | sed 's/.*= *"\(.*\)"/\1/')
AWS_REGION=$(grep '^aws_region' "$VAR_FILE" | sed 's/.*= *"\(.*\)"/\1/')

if [ -z "$CLUSTER_NAME" ] || [ -z "$AWS_REGION" ]; then
    log_error "Could not parse cluster_name or aws_region from $VAR_FILE"
    exit 1
fi

echo "=================================="
echo "  Store Vault Credentials"
echo "=================================="
echo ""
echo "Environment: $ENV"
echo "Cluster:     $CLUSTER_NAME"
echo "Region:      $AWS_REGION"
echo ""

# Store root token
echo "--- Root Token ---"
read -sp "Enter root token (or press Enter to skip): " ROOT_TOKEN
echo ""

if [ -n "$ROOT_TOKEN" ]; then
    SECRET_ID="${CLUSTER_NAME}/vault/root-token"
    TOKEN_JSON=$(jq -n --arg token "$ROOT_TOKEN" '{"token": $token}')

    log_info "Storing root token in Secrets Manager: $SECRET_ID"
    aws secretsmanager put-secret-value \
        --region "$AWS_REGION" \
        --secret-id "$SECRET_ID" \
        --secret-string "$TOKEN_JSON" 2>/dev/null || \
    aws secretsmanager create-secret \
        --region "$AWS_REGION" \
        --name "$SECRET_ID" \
        --description "Vault root token for $CLUSTER_NAME" \
        --secret-string "$TOKEN_JSON"

    log_info "Root token stored."
    unset ROOT_TOKEN TOKEN_JSON
else
    log_info "Skipping root token."
fi

echo ""

# Store recovery keys
echo "--- Recovery Keys ---"
echo "Enter recovery keys one per line. Press Enter on empty line when done."
echo "(Or press Enter immediately to skip)"

KEYS=()
while true; do
    read -sp "Recovery key (or Enter to finish): " key
    echo ""
    if [ -z "$key" ]; then
        break
    fi
    KEYS+=("$key")
done

if [ ${#KEYS[@]} -gt 0 ]; then
    SECRET_ID="${CLUSTER_NAME}/vault/recovery-keys"

    # Build JSON array of keys
    KEYS_JSON=$(printf '%s\n' "${KEYS[@]}" | jq -R . | jq -s '{"keys_base64": .}')

    log_info "Storing ${#KEYS[@]} recovery keys in Secrets Manager: $SECRET_ID"
    aws secretsmanager put-secret-value \
        --region "$AWS_REGION" \
        --secret-id "$SECRET_ID" \
        --secret-string "$KEYS_JSON" 2>/dev/null || \
    aws secretsmanager create-secret \
        --region "$AWS_REGION" \
        --name "$SECRET_ID" \
        --description "Vault recovery keys for $CLUSTER_NAME" \
        --secret-string "$KEYS_JSON"

    log_info "Recovery keys stored."
    unset KEYS KEYS_JSON
else
    log_info "Skipping recovery keys."
fi

echo ""
log_info "Done."
