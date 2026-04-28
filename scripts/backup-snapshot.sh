#!/bin/bash
#
# backup-snapshot.sh - Automated Vault Raft snapshot backup
#
# Runs on each Vault node via systemd timer. Only the leader performs backups.
# Authenticates via AWS IAM auth method to get a Vault token.
#
# Prerequisites:
#   - Vault AWS auth method enabled with a "backup" role
#   - Backup policy granting access to sys/storage/raft/snapshot
#   - S3 backup bucket accessible via instance IAM role
#
# Environment variables (set by systemd unit):
#   VAULT_ADDR          - Vault address (default: https://127.0.0.1:8200)
#   VAULT_CACERT        - CA cert path (default: /opt/vault/tls/ca.crt)
#   BACKUP_S3_BUCKET    - S3 bucket name for backups
#   CLUSTER_NAME        - Vault cluster name

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_CACERT="${VAULT_CACERT:-/opt/vault/tls/ca.crt}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"

export VAULT_ADDR VAULT_CACERT

log() { logger -t vault-backup "$1"; echo "$1"; }

# Validate required variables
if [ -z "$BACKUP_S3_BUCKET" ]; then
    log "ERROR: BACKUP_S3_BUCKET not set"
    exit 1
fi

if [ -z "$CLUSTER_NAME" ]; then
    log "ERROR: CLUSTER_NAME not set"
    exit 1
fi

# Check if this node is the active leader
log "Checking if this node is the active leader..."
HEALTH=$(curl -sk "$VAULT_ADDR/v1/sys/health" 2>/dev/null || echo '{}')

INITIALIZED=$(echo "$HEALTH" | jq -r '.initialized')
SEALED=$(echo "$HEALTH" | jq -r '.sealed')
STANDBY=$(echo "$HEALTH" | jq -r '.standby')

if [ "$INITIALIZED" != "true" ] || [ "$SEALED" != "false" ]; then
    log "Node is not initialized or is sealed. Skipping backup."
    exit 0
fi

if [ "$STANDBY" != "false" ]; then
    log "Node is a standby. Only the leader performs backups. Skipping."
    exit 0
fi

log "This node is the active leader. Proceeding with backup."

# Authenticate via AWS IAM auth method
log "Authenticating via AWS IAM auth..."
VAULT_TOKEN=$(vault login -method=aws role=backup -token-only 2>/dev/null) || {
    log "ERROR: Failed to authenticate via AWS IAM auth. Is the auth method configured?"
    log "See docs/backup-setup.md for setup instructions."
    exit 1
}
export VAULT_TOKEN

# Take the snapshot
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
SNAP_FILE="/tmp/vault-snapshot-${TIMESTAMP}.snap"

log "Taking Raft snapshot..."
vault operator raft snapshot save "$SNAP_FILE"

SNAP_SIZE=$(stat -f%z "$SNAP_FILE" 2>/dev/null || stat -c%s "$SNAP_FILE" 2>/dev/null || echo "unknown")
log "Snapshot saved: $SNAP_FILE (${SNAP_SIZE} bytes)"

# Upload to S3 - daily prefix
DAILY_KEY="${CLUSTER_NAME}/daily/vault-snapshot-${TIMESTAMP}.snap"
log "Uploading to s3://${BACKUP_S3_BUCKET}/${DAILY_KEY}..."
aws s3 cp "$SNAP_FILE" "s3://${BACKUP_S3_BUCKET}/${DAILY_KEY}" --quiet

# If Sunday, also upload to weekly prefix
DAY_OF_WEEK=$(date -u +"%u")
if [ "$DAY_OF_WEEK" = "7" ]; then
    WEEKLY_KEY="${CLUSTER_NAME}/weekly/vault-snapshot-${TIMESTAMP}.snap"
    log "Sunday - also uploading to weekly: s3://${BACKUP_S3_BUCKET}/${WEEKLY_KEY}"
    aws s3 cp "$SNAP_FILE" "s3://${BACKUP_S3_BUCKET}/${WEEKLY_KEY}" --quiet
fi

# Clean up
rm -f "$SNAP_FILE"

# Revoke the token
vault token revoke -self 2>/dev/null || true

log "Backup completed successfully."
