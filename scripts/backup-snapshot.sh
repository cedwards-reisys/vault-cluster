#!/bin/bash
#
# backup-snapshot.sh - Automated Vault Raft snapshot backup
#
# Runs on each Vault node via systemd timer. Only the confirmed Raft leader of
# a fully healthy 3-node cluster performs backups. Authenticates via AWS IAM
# auth method to get a Vault token.
#
# Prerequisites:
#   - Vault AWS auth method enabled with a "backup" role
#   - Backup policy grants:
#       path "sys/storage/raft/snapshot"      { capabilities = ["read"] }
#       path "sys/storage/raft/configuration" { capabilities = ["read"] }
#   - S3 backup bucket accessible via instance IAM role
#
# Environment variables (set by systemd unit):
#   VAULT_ADDR          - Vault address (default: https://127.0.0.1:8200)
#   VAULT_CACERT        - CA cert path (default: /opt/vault/tls/ca.crt)
#   BACKUP_S3_BUCKET    - S3 bucket name for backups
#   CLUSTER_NAME        - Vault cluster name
#   EXPECTED_PEERS      - expected Raft peer count (default: 3). Backup only
#                         runs when the cluster is fully healthy.
#   BACKUP_CW_NAMESPACE - CloudWatch metric namespace (default: Vault/Backup).
#                         Set empty to disable metrics.

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:8200}"
VAULT_CACERT="${VAULT_CACERT:-/opt/vault/tls/ca.crt}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
EXPECTED_PEERS="${EXPECTED_PEERS:-3}"
BACKUP_CW_NAMESPACE="${BACKUP_CW_NAMESPACE:-Vault/Backup}"

export VAULT_ADDR VAULT_CACERT

log()      { logger -t vault-backup "$1"; echo "$1"; }
log_warn() { logger -t vault-backup -p user.warning "WARN: $1"; echo "WARN: $1" >&2; }

# Emit a CloudWatch metric. No-op if BACKUP_CW_NAMESPACE is empty or aws CLI missing.
# Args: <MetricName> <Value> [<AZ>]
emit_metric() {
    [ -z "$BACKUP_CW_NAMESPACE" ] && return 0
    command -v aws >/dev/null 2>&1 || return 0
    local name="$1" value="$2" az="${3:-unknown}"
    local region
    region=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
    [ -z "$region" ] && return 0
    aws cloudwatch put-metric-data \
        --region "$region" \
        --namespace "$BACKUP_CW_NAMESPACE" \
        --metric-name "$name" \
        --value "$value" \
        --unit Count \
        --dimensions "Cluster=$CLUSTER_NAME,AZ=$az" \
        2>/dev/null || true
}

# Validate required variables
if [ -z "$BACKUP_S3_BUCKET" ]; then
    log "ERROR: BACKUP_S3_BUCKET not set"
    exit 1
fi

if [ -z "$CLUSTER_NAME" ]; then
    log "ERROR: CLUSTER_NAME not set"
    exit 1
fi

# Derive node_id — matches userdata: ${CLUSTER_NAME}-${AZ}
MY_AZ=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || echo "")
if [ -z "$MY_AZ" ]; then
    log "ERROR: could not determine AZ from IMDS"
    exit 1
fi
MY_NODE_ID="${CLUSTER_NAME}-${MY_AZ}"

# ---------------------------------------------------------------------------
# Stage 1: local health check (cheap — no auth required)
# ---------------------------------------------------------------------------
log "Stage 1: local health check..."
HEALTH=$(curl -sk "$VAULT_ADDR/v1/sys/health" 2>/dev/null || echo '{}')
[ -z "$HEALTH" ] && HEALTH='{}'

INITIALIZED=$(echo "$HEALTH" | jq -r '.initialized | tostring' 2>/dev/null || echo "unknown")
SEALED=$(echo "$HEALTH"      | jq -r '.sealed      | tostring' 2>/dev/null || echo "unknown")
STANDBY=$(echo "$HEALTH"     | jq -r '.standby     | tostring' 2>/dev/null || echo "unknown")

if [ "$INITIALIZED" != "true" ] || [ "$SEALED" != "false" ]; then
    log "Skipping: node not initialized or sealed (initialized=$INITIALIZED, sealed=$SEALED)"
    exit 0
fi

if [ "$STANDBY" != "false" ]; then
    log "Skipping: node is standby (standby=$STANDBY). Only the leader performs backups."
    exit 0
fi

# Authenticate via AWS IAM auth method (needed for Raft peer query and snapshot)
log "Authenticating via AWS IAM auth..."
VAULT_TOKEN=$(vault login -method=aws role=backup -token-only 2>/dev/null) || {
    log "ERROR: Failed to authenticate via AWS IAM auth. Is the auth method configured?"
    log "See docs/backup-setup.md for setup instructions."
    emit_metric "AuthFailure" 1 "$MY_AZ"
    exit 1
}
export VAULT_TOKEN

# ---------------------------------------------------------------------------
# Stage 2: Raft consensus check — confirm cluster agrees I'm leader.
# Prevents corrupt backups during partition, split-brain, or stale-leader.
# ---------------------------------------------------------------------------
log "Stage 2: Raft consensus check (my_node_id=$MY_NODE_ID, expected_peers=$EXPECTED_PEERS)..."
RAFT=$(vault operator raft list-peers -format=json 2>/dev/null || echo '{}')
[ -z "$RAFT" ] && RAFT='{}'

PEER_COUNT=$(echo "$RAFT" | jq -r '.data.config.servers | length? // 0' 2>/dev/null || echo "0")
IS_LEADER=$(echo "$RAFT"  | jq -r --arg id "$MY_NODE_ID" '.data.config.servers[]? | select(.node_id==$id) | .leader | tostring' 2>/dev/null || echo "false")
[ -z "$IS_LEADER" ] && IS_LEADER="false"
NON_VOTERS=$(echo "$RAFT" | jq -r '[.data.config.servers[]? | select(.voter==false)] | length' 2>/dev/null || echo "0")

SKIP_REASON=""
if [ "$IS_LEADER" != "true" ]; then
    SKIP_REASON="Raft does not confirm me as leader (is_leader=$IS_LEADER, peers=$PEER_COUNT)"
elif [ "$PEER_COUNT" -ne "$EXPECTED_PEERS" ]; then
    SKIP_REASON="cluster not fully healthy (peer_count=$PEER_COUNT, expected=$EXPECTED_PEERS)"
elif [ "$NON_VOTERS" -gt 0 ]; then
    SKIP_REASON="$NON_VOTERS non-voter peer(s) detected — cluster is mid-promotion"
fi

if [ -n "$SKIP_REASON" ]; then
    log_warn "Skipping backup: $SKIP_REASON"
    emit_metric "BackupSkipped" 1 "$MY_AZ"
    vault token revoke -self 2>/dev/null || true
    exit 0
fi

log "Confirmed: leader of a healthy $PEER_COUNT-node cluster. Proceeding."

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

emit_metric "BackupSuccess" 1 "$MY_AZ"
log "Backup completed successfully."
