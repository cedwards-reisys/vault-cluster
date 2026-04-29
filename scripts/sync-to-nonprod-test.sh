#!/bin/bash
#
# sync-to-nonprod-test.sh - Copy nonprod Vault data to nonprod-test
#
# Takes a snapshot from nonprod and restores it to nonprod-test.
#
# Usage: ./scripts/sync-to-nonprod-test.sh [--yes]
#
# Requires:
#   VAULT_NONPROD_ADDR    - nonprod Vault address
#   VAULT_NONPROD_TOKEN   - nonprod root/operator token
#   VAULT_TEST_ADDR       - nonprod-test Vault address
#   VAULT_TEST_TOKEN      - nonprod-test root/operator token

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

AUTO_CONFIRM=false
[ "${1:-}" = "--yes" ] && AUTO_CONFIRM=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Validate prerequisites
command -v vault >/dev/null 2>&1 || { log_error "vault CLI not found"; exit 1; }
command -v aws >/dev/null 2>&1 || { log_error "aws CLI not found"; exit 1; }

for var in VAULT_NONPROD_ADDR VAULT_NONPROD_TOKEN VAULT_TEST_ADDR VAULT_TEST_TOKEN; do
    if [ -z "${!var:-}" ]; then
        log_error "$var not set"
        echo ""
        echo "Required environment variables:"
        echo "  VAULT_NONPROD_ADDR    - nonprod Vault address"
        echo "  VAULT_NONPROD_TOKEN   - nonprod root/operator token"
        echo "  VAULT_TEST_ADDR       - nonprod-test Vault address"
        echo "  VAULT_TEST_TOKEN      - nonprod-test root/operator token"
        exit 1
    fi
done

echo "=================================="
echo "  Sync nonprod -> nonprod-test"
echo "=================================="
echo ""
echo "Source:      $VAULT_NONPROD_ADDR (nonprod)"
echo "Destination: $VAULT_TEST_ADDR (nonprod-test)"
echo ""

# Take snapshot from nonprod
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
SNAP_FILE="/tmp/vault-sync-${TIMESTAMP}.snap"

log_info "Taking snapshot from nonprod..."
VAULT_ADDR="$VAULT_NONPROD_ADDR" VAULT_TOKEN="$VAULT_NONPROD_TOKEN" \
    vault operator raft snapshot save "$SNAP_FILE"

SNAP_SIZE=$(ls -lh "$SNAP_FILE" | awk '{print $5}')
log_info "Snapshot saved: $SNAP_FILE ($SNAP_SIZE)"

# Optionally upload to nonprod-test backup bucket for audit trail
BACKUP_BUCKET=$(grep '^backup_s3_bucket' "$PROJECT_DIR/terraform/environments/nonprod-test.tfvars" 2>/dev/null \
    | sed 's/.*= *"\(.*\)"/\1/' || true)

if [ -n "$BACKUP_BUCKET" ]; then
    SYNC_KEY="vault-nonprod-test/sync/nonprod-sync-${TIMESTAMP}.snap"
    log_info "Uploading to s3://${BACKUP_BUCKET}/${SYNC_KEY} (audit trail)..."
    aws s3 cp "$SNAP_FILE" "s3://${BACKUP_BUCKET}/${SYNC_KEY}" --quiet || \
        log_warn "Failed to upload audit copy (non-fatal)"
fi

# Confirm
if [ "$AUTO_CONFIRM" != "true" ]; then
    echo ""
    log_warn "This will REPLACE all data in nonprod-test with nonprod data."
    log_warn "nonprod-test's existing data will be lost."
    echo ""
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Aborted"
        rm -f "$SNAP_FILE"
        exit 0
    fi
fi

# Restore to nonprod-test
echo ""
log_info "Restoring snapshot to nonprod-test..."
VAULT_ADDR="$VAULT_TEST_ADDR" VAULT_TOKEN="$VAULT_TEST_TOKEN" \
    vault operator raft snapshot restore -force "$SNAP_FILE"

# Clean up
rm -f "$SNAP_FILE"

# Verify (post-restore, nonprod token is valid on nonprod-test)
log_info "Verifying nonprod-test..."
sleep 5
if ! VAULT_ADDR="$VAULT_TEST_ADDR" VAULT_TOKEN="$VAULT_NONPROD_TOKEN" vault status; then
    log_error "Post-restore vault status check failed on $VAULT_TEST_ADDR"
    log_error "The snapshot may have been applied but the cluster is not healthy."
    exit 1
fi

echo ""
echo "=================================="
log_info "Sync completed!"
echo "=================================="
echo ""
log_warn "Post-sync notes:"
echo "  - The nonprod root token is now valid on nonprod-test"
echo "  - All auth tokens from nonprod are now valid on nonprod-test"
echo "  - All policies and secrets from nonprod are now on nonprod-test"
echo "  - KMS auto-unseal is NOT affected (config-level, not in snapshot)"
echo "  - You may want to rotate the nonprod-test root token"
