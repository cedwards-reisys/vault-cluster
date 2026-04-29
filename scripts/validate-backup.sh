#!/bin/bash
#
# validate-backup.sh - Daily validation of the latest Vault Raft snapshot in S3.
#
# Purpose:
#   Prove that the most recent daily snapshot is not corrupted, is not stale,
#   and is large enough to plausibly contain cluster state. Runs purely locally
#   via `vault operator raft snapshot inspect` — no Vault connection, no token.
#
#   This is a LIGHTWEIGHT check. It catches file-format corruption, truncated
#   uploads, stale timers, HTML-error-page-as-snapshot, etc. It does NOT catch:
#     - Vault version incompatibility on restore
#     - KMS/seal-type mismatch
#     - Logical data corruption
#   For those, a full restore drill is still required.
#
# Usage:
#   ./scripts/validate-backup.sh <environment>
#
# Environment variables (all optional with defaults):
#   MAX_AGE_HOURS              Freshness ceiling in hours (default: 8)
#   MIN_SIZE_BYTES             Minimum acceptable snapshot size (default: 10240)
#   VALIDATE_CW_NAMESPACE      CloudWatch namespace (default: Vault/BackupValidation).
#                              Set empty to disable metrics.
#
# Exit codes:
#   0  snapshot passed all checks
#   1  validation failed (metric emitted, reason logged)
#   2  environment / preflight error (e.g., bucket not found)
#
# Requires: aws CLI, jq, vault CLI (1.17+ for snapshot inspect).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

MAX_AGE_HOURS="${MAX_AGE_HOURS:-8}"
MIN_SIZE_BYTES="${MIN_SIZE_BYTES:-10240}"
VALIDATE_CW_NAMESPACE="${VALIDATE_CW_NAMESPACE:-Vault/BackupValidation}"

if [ $# -lt 1 ]; then
    log_error "Usage: $0 <environment>"
    exit 2
fi
ENV="$1"

command -v aws >/dev/null 2>&1    || { log_error "aws CLI not found"; exit 2; }
command -v jq  >/dev/null 2>&1    || { log_error "jq not found"; exit 2; }
command -v vault >/dev/null 2>&1  || { log_error "vault CLI not found"; exit 2; }

VAR_FILE="$PROJECT_DIR/terraform/environments/$ENV.tfvars"
if [ ! -f "$VAR_FILE" ]; then
    log_error "Environment file not found: $VAR_FILE"
    exit 2
fi

BACKUP_S3_BUCKET=$(grep '^backup_s3_bucket' "$VAR_FILE" 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' || true)
CLUSTER_NAME=$(grep '^cluster_name' "$VAR_FILE" 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' || true)
AWS_REGION=$(grep '^aws_region' "$VAR_FILE" 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' || true)

[ -z "$BACKUP_S3_BUCKET" ] && { log_error "backup_s3_bucket not in $VAR_FILE"; exit 2; }
[ -z "$CLUSTER_NAME" ]     && { log_error "cluster_name not in $VAR_FILE"; exit 2; }
[ -z "$AWS_REGION" ]       && AWS_REGION="us-east-1"

log_info "Environment:    $ENV"
log_info "Cluster:        $CLUSTER_NAME"
log_info "Bucket:         $BACKUP_S3_BUCKET"
log_info "Region:         $AWS_REGION"
log_info "Max age:        ${MAX_AGE_HOURS}h"
log_info "Min size:       ${MIN_SIZE_BYTES} bytes"

# Emit a single CloudWatch metric. No-op if disabled or aws CLI missing.
# Args: <MetricName> <Value> [<Unit> default Count]
emit_metric() {
    [ -z "$VALIDATE_CW_NAMESPACE" ] && return 0
    local name="$1" value="$2" unit="${3:-Count}"
    aws cloudwatch put-metric-data \
        --region "$AWS_REGION" \
        --namespace "$VALIDATE_CW_NAMESPACE" \
        --metric-name "$name" \
        --value "$value" \
        --unit "$unit" \
        --dimensions "Cluster=$CLUSTER_NAME,Environment=$ENV" \
        2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Stage 1: find the latest daily snapshot in S3
# ---------------------------------------------------------------------------
log_info "Listing latest daily snapshot..."
PREFIX="${CLUSTER_NAME}/daily/"

LATEST_LINE=$(aws s3api list-objects-v2 \
    --region "$AWS_REGION" \
    --bucket "$BACKUP_S3_BUCKET" \
    --prefix "$PREFIX" \
    --query 'reverse(sort_by(Contents || `[]`, &LastModified))[0].{Key:Key,Size:Size,LastModified:LastModified}' \
    --output json 2>/dev/null || echo 'null')

if [ "$LATEST_LINE" = "null" ] || [ -z "$LATEST_LINE" ] || echo "$LATEST_LINE" | jq -e '.Key == null' >/dev/null 2>&1; then
    log_error "No snapshots found under s3://${BACKUP_S3_BUCKET}/${PREFIX}"
    emit_metric "Failure" 1
    emit_metric "NoSnapshotsFound" 1
    exit 1
fi

S3_KEY=$(echo "$LATEST_LINE"      | jq -r '.Key')
S3_SIZE=$(echo "$LATEST_LINE"     | jq -r '.Size')
S3_MODIFIED=$(echo "$LATEST_LINE" | jq -r '.LastModified')

log_info "Latest:         $S3_KEY"
log_info "Size:           $S3_SIZE bytes"
log_info "LastModified:   $S3_MODIFIED"

# Compute age in hours. Use python3 if available (handles any ISO-8601), fall back to date.
AGE_HOURS=""
if command -v python3 >/dev/null 2>&1; then
    AGE_HOURS=$(python3 -c "
import sys, datetime
try:
    m = datetime.datetime.fromisoformat('$S3_MODIFIED'.replace('Z','+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    print(int((now - m).total_seconds() // 3600))
except Exception as e:
    sys.exit(1)
" 2>/dev/null || echo "")
fi
if [ -z "$AGE_HOURS" ]; then
    # Fallback: GNU date
    MOD_EPOCH=$(date -u -d "$S3_MODIFIED" +%s 2>/dev/null || echo "")
    if [ -n "$MOD_EPOCH" ]; then
        NOW_EPOCH=$(date -u +%s)
        AGE_HOURS=$(( (NOW_EPOCH - MOD_EPOCH) / 3600 ))
    fi
fi

if [ -z "$AGE_HOURS" ]; then
    log_warn "Could not compute snapshot age from '$S3_MODIFIED'"
fi
log_info "Age:            ${AGE_HOURS:-unknown}h"

emit_metric "AgeHours" "${AGE_HOURS:-0}" "None"
emit_metric "SizeBytes" "$S3_SIZE" "Bytes"

# ---------------------------------------------------------------------------
# Stage 2: download and inspect
# ---------------------------------------------------------------------------
TEMP_FILE=$(mktemp /tmp/vault-validate-XXXXXX.snap)
trap 'rm -f "$TEMP_FILE"' EXIT

log_info "Downloading..."
if ! aws s3 cp "s3://${BACKUP_S3_BUCKET}/${S3_KEY}" "$TEMP_FILE" --region "$AWS_REGION" --quiet; then
    log_error "Download failed"
    emit_metric "Failure" 1
    emit_metric "DownloadFailure" 1
    exit 1
fi

log_info "Running 'vault operator raft snapshot inspect'..."
INSPECT_OUT=$(vault operator raft snapshot inspect -format=json "$TEMP_FILE" 2>&1) && INSPECT_EXIT=0 || INSPECT_EXIT=$?
echo "$INSPECT_OUT" | head -30

# ---------------------------------------------------------------------------
# Stage 3: classify
# ---------------------------------------------------------------------------
REASONS=()
INDEX="null"
VERSION="null"

if [ "$INSPECT_EXIT" -ne 0 ]; then
    REASONS+=("inspect_exit=$INSPECT_EXIT")
elif ! echo "$INSPECT_OUT" | jq -e . >/dev/null 2>&1; then
    REASONS+=("inspect_json_unparseable")
else
    INDEX=$(echo   "$INSPECT_OUT" | jq -r '.Index   // 0')
    VERSION=$(echo "$INSPECT_OUT" | jq -r '.Version // 0')
    if [ "$INDEX" = "null" ] || [ "$INDEX" -eq 0 ] 2>/dev/null; then
        REASONS+=("index_zero_or_missing")
    fi
fi

if [ -z "$S3_SIZE" ] || [ "$S3_SIZE" = "null" ]; then
    REASONS+=("s3_size_missing")
elif [ "$S3_SIZE" -lt "$MIN_SIZE_BYTES" ]; then
    REASONS+=("size_below_floor(size=$S3_SIZE,min=$MIN_SIZE_BYTES)")
fi

if [ -z "$AGE_HOURS" ]; then
    REASONS+=("s3_age_unknown")
elif [ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]; then
    REASONS+=("too_old(age=${AGE_HOURS}h,max=${MAX_AGE_HOURS}h)")
fi

if [ "${#REASONS[@]}" -eq 0 ]; then
    log_info "PASS — snapshot is valid (index=$INDEX, version=$VERSION, size=$S3_SIZE, age=${AGE_HOURS}h)"
    emit_metric "Success" 1
    emit_metric "Failure" 0
    exit 0
fi

log_warn "FAIL — validation failed:"
for r in "${REASONS[@]}"; do
    log_warn "  - $r"
done
emit_metric "Success" 0
emit_metric "Failure" 1
exit 1
