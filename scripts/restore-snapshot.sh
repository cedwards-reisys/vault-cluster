#!/bin/bash
#
# restore-snapshot.sh - Restore a Vault Raft snapshot from S3
#
# Usage: ./scripts/restore-snapshot.sh <environment> [s3-key]
#   If no s3-key provided, lists recent snapshots for interactive selection.
#
# Requires: VAULT_ADDR, VAULT_TOKEN
#
# Examples:
#   ./scripts/restore-snapshot.sh nonprod-test
#   ./scripts/restore-snapshot.sh nonprod vault-nonprod/daily/vault-snapshot-20260317-060000.snap

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
    echo "Usage: $0 <environment> [s3-key]"
    echo ""
    echo "Examples:"
    echo "  $0 nonprod-test"
    echo "  $0 nonprod vault-nonprod/daily/vault-snapshot-20260317-060000.snap"
    exit 1
fi

ENV="$1"
S3_KEY="${2:-}"

# Validate prerequisites
command -v aws >/dev/null 2>&1 || { log_error "aws CLI not found"; exit 1; }
command -v vault >/dev/null 2>&1 || { log_error "vault CLI not found"; exit 1; }

if [ -z "${VAULT_ADDR:-}" ]; then
    log_error "VAULT_ADDR not set"
    exit 1
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
    log_error "VAULT_TOKEN not set"
    exit 1
fi

# Get backup bucket from tfvars
VAR_FILE="$PROJECT_DIR/terraform/environments/$ENV.tfvars"
if [ ! -f "$VAR_FILE" ]; then
    log_error "Environment file not found: $VAR_FILE"
    exit 1
fi

BACKUP_S3_BUCKET=$(grep '^backup_s3_bucket' "$VAR_FILE" 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' || true)
CLUSTER_NAME=$(grep '^cluster_name' "$VAR_FILE" 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' || true)

if [ -z "$BACKUP_S3_BUCKET" ]; then
    log_error "backup_s3_bucket not found in $VAR_FILE"
    exit 1
fi

if [ -z "$CLUSTER_NAME" ]; then
    log_error "cluster_name not found in $VAR_FILE"
    exit 1
fi

log_info "Environment:  $ENV"
log_info "Cluster:      $CLUSTER_NAME"
log_info "Backup Bucket: $BACKUP_S3_BUCKET"
log_info "Vault Address: $VAULT_ADDR"
echo ""

# If no key provided, list recent snapshots
if [ -z "$S3_KEY" ]; then
    log_info "Listing recent snapshots..."
    echo ""

    echo "--- Daily snapshots (last 10) ---"
    aws s3 ls "s3://${BACKUP_S3_BUCKET}/${CLUSTER_NAME}/daily/" --recursive \
        | sort -r | head -10 || echo "  (none found)"

    echo ""
    echo "--- Weekly snapshots (last 5) ---"
    aws s3 ls "s3://${BACKUP_S3_BUCKET}/${CLUSTER_NAME}/weekly/" --recursive \
        | sort -r | head -5 || echo "  (none found)"

    echo ""
    echo "--- Sync snapshots (last 5) ---"
    aws s3 ls "s3://${BACKUP_S3_BUCKET}/${CLUSTER_NAME}/sync/" --recursive \
        | sort -r | head -5 || echo "  (none found)"

    echo ""
    read -p "Enter S3 key to restore (e.g., ${CLUSTER_NAME}/daily/vault-snapshot-YYYYMMDD-HHMMSS.snap): " S3_KEY

    if [ -z "$S3_KEY" ]; then
        log_error "No key provided"
        exit 1
    fi
fi

# Download snapshot
TEMP_FILE="/tmp/vault-restore-$(date +%s).snap"
log_info "Downloading s3://${BACKUP_S3_BUCKET}/${S3_KEY}..."
aws s3 cp "s3://${BACKUP_S3_BUCKET}/${S3_KEY}" "$TEMP_FILE"

SNAP_SIZE=$(ls -lh "$TEMP_FILE" | awk '{print $5}')
log_info "Downloaded snapshot: $SNAP_SIZE"
echo ""

# Require explicit confirmation
log_warn "WARNING: This will restore Vault from a snapshot."
log_warn "All current data will be REPLACED with the snapshot contents."
log_warn "This operation uses -force flag (required for cross-cluster restore)."
echo ""
echo "  Source:  s3://${BACKUP_S3_BUCKET}/${S3_KEY}"
echo "  Target:  $VAULT_ADDR"
echo "  Size:    $SNAP_SIZE"
echo ""
read -p "Type RESTORE to confirm: " confirm

if [ "$confirm" != "RESTORE" ]; then
    log_info "Aborted"
    rm -f "$TEMP_FILE"
    exit 0
fi

# Restore
log_info "Restoring snapshot..."
vault operator raft snapshot restore -force "$TEMP_FILE"

# Clean up
rm -f "$TEMP_FILE"

# Verify
log_info "Verifying Vault status..."
sleep 5
vault status || true

echo ""
log_info "Restore completed."
log_warn "Note: If this was a cross-cluster restore, the source cluster's root token is now valid here."
log_warn "KMS auto-unseal configuration is NOT affected by the snapshot (it's in the Vault config, not data)."
