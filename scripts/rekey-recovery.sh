#!/bin/bash
#
# rekey-recovery.sh - ROTATE recovery keys for a Vault cluster.
#
# SCOPE — read before running:
#   This script ROTATES (replaces) recovery keys. It is NOT a recovery
#   mechanism for a cluster whose recovery keys have been lost.
#
#   Vault's rekey API requires the CURRENT recovery keys to authorize
#   generation of new ones. This is a deliberate Vault security property
#   (recovery keys are the strongest DR credential — a root token alone
#   cannot rotate them).
#
#   If your recovery keys are LOST, this script CANNOT help you. See
#   docs/dr-lost-recovery-keys.md for the break-glass procedure
#   (fresh-deploy + snapshot-restore).
#
# Prerequisites:
#   - Cluster uses KMS auto-unseal (SealType=awskms)
#   - Cluster is unsealed and reachable
#   - You have the CURRENT recovery keys and a root token
#
# Usage: ./scripts/rekey-recovery.sh
#
# Requires:
#   VAULT_ADDR  - Vault address
#   VAULT_TOKEN - Root token
#   VAULT_CACERT - (optional) path to CA cert

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Validate prerequisites
command -v curl >/dev/null 2>&1 || { log_error "curl not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { log_error "jq not found"; exit 1; }

if [ -z "${VAULT_ADDR:-}" ]; then
    log_error "VAULT_ADDR not set"
    exit 1
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
    log_error "VAULT_TOKEN not set (root token required)"
    exit 1
fi

VAULT_CACERT="${VAULT_CACERT:-}"
CURL_OPTS=(-sk)
if [ -n "$VAULT_CACERT" ]; then
    CURL_OPTS=(--cacert "$VAULT_CACERT" -s)
fi

echo "=================================="
echo "  Recovery Key Regeneration"
echo "=================================="
echo ""
echo "Vault Address: $VAULT_ADDR"
echo ""

# Verify connection and seal type
log_info "Verifying Vault status..."
HEALTH=$(curl "${CURL_OPTS[@]}" "$VAULT_ADDR/v1/sys/health" || echo '{}')
[ -z "$HEALTH" ] && HEALTH='{}'

SEALED=$(echo "$HEALTH" | jq -r '.sealed | tostring' 2>/dev/null || echo "unknown")
if [ "$SEALED" != "false" ]; then
    log_error "Vault is sealed or unreachable (sealed=$SEALED). Raw response:"
    echo "$HEALTH"
    exit 1
fi

SEAL_STATUS=$(curl "${CURL_OPTS[@]}" -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/seal-status" || echo '{}')
[ -z "$SEAL_STATUS" ] && SEAL_STATUS='{}'
SEAL_TYPE=$(echo "$SEAL_STATUS" | jq -r '.type // "unknown"' 2>/dev/null || echo "unknown")

if [ "$SEAL_TYPE" != "awskms" ]; then
    log_error "Expected seal type 'awskms', got '$SEAL_TYPE'"
    log_error "This script is designed for KMS auto-unseal clusters only"
    exit 1
fi

log_info "Seal type: $SEAL_TYPE (KMS auto-unseal)"

# Configure rekey parameters
KEY_SHARES=5
KEY_THRESHOLD=3

echo ""
echo "New recovery key configuration:"
echo "  Key shares:    $KEY_SHARES"
echo "  Key threshold: $KEY_THRESHOLD"
echo ""
log_warn "This will generate new recovery keys, replacing any existing ones."
read -p "Continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    log_info "Aborted"
    exit 0
fi

# Cancel any existing rekey operation
log_info "Cancelling any existing rekey operation..."
curl "${CURL_OPTS[@]}" \
    -X DELETE \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/sys/rekey-recovery-key/init" >/dev/null 2>&1 || true

# Initialize recovery key rekey
log_info "Initializing recovery key rekey..."
INIT_RESPONSE=$(curl "${CURL_OPTS[@]}" \
    -X PUT \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    -d "{\"secret_shares\": $KEY_SHARES, \"secret_threshold\": $KEY_THRESHOLD, \"require_verification\": false}" \
    "$VAULT_ADDR/v1/sys/rekey-recovery-key/init" || echo '{}')
[ -z "$INIT_RESPONSE" ] && INIT_RESPONSE='{}'

NONCE=$(echo "$INIT_RESPONSE" | jq -r '.nonce // empty' 2>/dev/null || echo "")

if [ -z "$NONCE" ]; then
    log_error "Failed to initialize rekey. Response:"
    echo "$INIT_RESPONSE"
    exit 1
fi

REQUIRED=$(echo "$INIT_RESPONSE" | jq -r '.required // 0' 2>/dev/null || echo "0")
PROGRESS=$(echo "$INIT_RESPONSE" | jq -r '.progress // 0' 2>/dev/null || echo "0")

log_info "Rekey initialized. Nonce: $NONCE"
log_info "Required keys: $REQUIRED"

if [ "$REQUIRED" -gt 0 ] && [ "$PROGRESS" -eq 0 ]; then
    echo ""
    log_warn "Vault requires $REQUIRED CURRENT recovery key(s) to authorize this rekey."
    log_warn "This is a Vault security property, not a script limitation."
    echo ""
    echo "If you have the current recovery keys, enter them below."
    echo "If they are LOST, cancel now (Ctrl+C) and see:"
    echo "  docs/dr-lost-recovery-keys.md   # break-glass procedure"
    echo ""
    echo "Enter existing recovery keys (base64 encoded):"
    echo ""

    KEYS_SUBMITTED=0
    while [ "$KEYS_SUBMITTED" -lt "$REQUIRED" ]; do
        read -sp "Recovery key $((KEYS_SUBMITTED + 1))/$REQUIRED: " key
        echo ""

        if [ -z "$key" ]; then
            log_error "Empty key provided"
            exit 1
        fi

        RESPONSE=$(curl "${CURL_OPTS[@]}" \
            -X PUT \
            -H "X-Vault-Token: $VAULT_TOKEN" \
            -d "{\"key\": \"$key\", \"nonce\": \"$NONCE\"}" \
            "$VAULT_ADDR/v1/sys/rekey-recovery-key/update")

        COMPLETE=$(echo "$RESPONSE" | jq -r '.complete')
        KEYS_SUBMITTED=$((KEYS_SUBMITTED + 1))

        if [ "$COMPLETE" = "true" ]; then
            # Extract new keys
            echo ""
            log_info "Rekey complete! New recovery keys:"
            echo ""
            echo "$RESPONSE" | jq -r '.keys_base64[]' | nl -ba
            echo ""

            # Store keys
            echo "$RESPONSE" | jq '{keys: .keys, keys_base64: .keys_base64}'

            log_info "IMPORTANT: Store these keys securely!"
            log_warn "Use ./store-vault-credentials.sh to save them to Secrets Manager."
            exit 0
        fi

        CURRENT_PROGRESS=$(echo "$RESPONSE" | jq -r '.progress // 0')
        log_info "Progress: $CURRENT_PROGRESS/$REQUIRED"
    done
fi

echo ""
log_info "Rekey operation completed."
