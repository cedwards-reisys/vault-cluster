#!/bin/bash
#
# recover-raft-cluster.sh - Recover a Vault Raft cluster with no leader
#
# When to use:
#   All Vault nodes are unsealed but stuck in standby because the Raft
#   cluster references a leader node_id that no longer exists and can't
#   elect a new leader (lost quorum).
#
# What it does:
#   1. Identifies running Vault nodes and confirms none is leader
#   2. Selects a recovery node (or accepts --node flag)
#   3. Writes a single-node peers.json to the recovery node via SSM
#   4. Restarts Vault on the recovery node so it bootstraps as leader
#   5. Waits for the other nodes to rejoin via auto_join
#   6. Verifies full cluster health
#
# Usage: ./recover-raft-cluster.sh <env> [--node <instance-id>] [--yes]
#
# Options:
#   --node <id>  Pick a specific instance as the recovery node
#   --yes        Skip confirmation prompt (for automation)
#
# Prerequisites:
#   - AWS CLI configured with SSM permissions
#   - The target instances must have SSM agent running (Amazon Linux default)

set -euo pipefail

# Parse arguments
ENV=""
RECOVERY_NODE=""
AUTO_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --node)
            RECOVERY_NODE="$2"
            shift 2
            ;;
        --yes|-y)
            AUTO_CONFIRM=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 <env> [--node <instance-id>] [--yes]"
            exit 1
            ;;
        *)
            if [ -z "$ENV" ]; then
                ENV="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$ENV" ]; then
    echo "Usage: $0 <env> [--node <instance-id>] [--yes]"
    echo "Environments: nonprod-test, nonprod, prod"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve environment, cluster name, and region
source "$SCRIPT_DIR/resolve-env.sh" "$ENV"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Run a command on an EC2 instance via SSM
ssm_run() {
    local instance_id="$1"
    shift
    local command="$*"

    local params_file
    params_file=$(mktemp)
    jq -n --arg cmd "$command" '{"commands":[$cmd]}' > "$params_file"

    local cmd_id
    cmd_id=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "file://$params_file" \
        --query 'Command.CommandId' \
        --output text)

    rm -f "$params_file"

    # Wait for completion
    aws ssm wait command-executed \
        --region "$AWS_REGION" \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" 2>/dev/null || true

    aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    command -v aws >/dev/null 2>&1 || { log_error "aws CLI not found"; exit 1; }
    command -v jq >/dev/null 2>&1 || { log_error "jq not found"; exit 1; }
    log_info "Prerequisites met"
}

# Discover running Vault instances with their IPs and AZs
discover_instances() {
    log_step "Discovering running Vault instances..."

    INSTANCES_JSON=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:vault-cluster,Values=$CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].{
            InstanceId: InstanceId,
            PrivateIp: PrivateIpAddress,
            AZ: Placement.AvailabilityZone,
            Name: Tags[?Key==`Name`].Value | [0]
        }' \
        --output json)

    INSTANCE_COUNT=$(echo "$INSTANCES_JSON" | jq 'length')

    if [ "$INSTANCE_COUNT" -eq 0 ]; then
        log_error "No running instances found for cluster: $CLUSTER_NAME"
        exit 1
    fi

    log_info "Found $INSTANCE_COUNT running instance(s):"
    echo "$INSTANCES_JSON" | jq -r '.[] | "  - \(.InstanceId)  \(.PrivateIp)  \(.AZ)  \(.Name // "unnamed")"'
}

# Check each node's Vault health via SSM — confirm no leader exists
check_no_leader() {
    log_step "Checking Vault status on each node..."

    local has_leader=false

    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        local iid ip name
        iid=$(echo "$INSTANCES_JSON" | jq -r ".[$i].InstanceId")
        ip=$(echo "$INSTANCES_JSON" | jq -r ".[$i].PrivateIp")
        name=$(echo "$INSTANCES_JSON" | jq -r ".[$i].Name // \"unnamed\"")

        local health
        health=$(ssm_run "$iid" "curl -sk https://127.0.0.1:8200/v1/sys/health -o /dev/stdout -w '' 2>/dev/null || echo '{}'") || health='{}'

        local sealed standby initialized
        initialized=$(echo "$health" | jq -r '.initialized')
        sealed=$(echo "$health" | jq -r '.sealed')
        standby=$(echo "$health" | jq -r '.standby')

        local status_label=""
        if [ "$sealed" == "true" ]; then
            status_label="SEALED"
        elif [ "$standby" == "false" ]; then
            status_label="ACTIVE (LEADER)"
            has_leader=true
        elif [ "$standby" == "true" ]; then
            status_label="STANDBY"
        else
            status_label="UNKNOWN"
        fi

        echo -e "  $iid ($ip) — ${status_label}"
    done

    if [ "$has_leader" == "true" ]; then
        log_error "A leader already exists — this recovery script is for leaderless clusters"
        log_error "Use cluster-status.sh to diagnose, or rolling-update.sh for normal operations"
        exit 1
    fi

    log_warn "Confirmed: no leader found — cluster needs Raft recovery"
}

# Select the recovery node
select_recovery_node() {
    if [ -n "$RECOVERY_NODE" ]; then
        # Validate the provided instance is in our list
        if ! echo "$INSTANCES_JSON" | jq -e --arg id "$RECOVERY_NODE" '.[] | select(.InstanceId == $id)' >/dev/null 2>&1; then
            log_error "Specified node $RECOVERY_NODE is not a running member of cluster $CLUSTER_NAME"
            exit 1
        fi
        log_info "Using specified recovery node: $RECOVERY_NODE"
    else
        # Pick the first instance (sorted by AZ for determinism)
        RECOVERY_NODE=$(echo "$INSTANCES_JSON" | jq -r 'sort_by(.AZ) | .[0].InstanceId')
        log_info "Auto-selected recovery node: $RECOVERY_NODE (first by AZ)"
    fi

    RECOVERY_IP=$(echo "$INSTANCES_JSON" | jq -r --arg id "$RECOVERY_NODE" '.[] | select(.InstanceId == $id) | .PrivateIp')
    RECOVERY_AZ=$(echo "$INSTANCES_JSON" | jq -r --arg id "$RECOVERY_NODE" '.[] | select(.InstanceId == $id) | .AZ')
    RECOVERY_NODE_ID="${CLUSTER_NAME}-${RECOVERY_AZ}"
}

# Build and write the peers.json recovery file
write_peers_json() {
    log_step "Writing peers.json on recovery node..."

    # Single-node peers.json — only the recovery node
    local peers_json
    peers_json=$(jq -n --arg id "$RECOVERY_NODE_ID" --arg addr "${RECOVERY_IP}:8201" \
        '[{"id": $id, "address": $addr, "non_voter": false}]')

    log_info "Recovery peers.json:"
    echo "$peers_json" | jq '.'

    # Stop Vault, write peers.json, start Vault
    log_info "Stopping Vault on recovery node..."
    ssm_run "$RECOVERY_NODE" "systemctl stop vault" >/dev/null

    log_info "Writing peers.json to /opt/vault/data/raft/peers.json..."
    ssm_run "$RECOVERY_NODE" "cat > /opt/vault/data/raft/peers.json << 'PEERSEOF'
${peers_json}
PEERSEOF
chown vault:vault /opt/vault/data/raft/peers.json" >/dev/null

    log_info "Starting Vault on recovery node..."
    ssm_run "$RECOVERY_NODE" "systemctl start vault" >/dev/null
}

# Wait for the recovery node to become leader
wait_for_recovery_leader() {
    log_step "Waiting for recovery node to become leader..."

    local max_wait=120
    local wait_interval=10
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))

        local health
        health=$(ssm_run "$RECOVERY_NODE" "curl -sk https://127.0.0.1:8200/v1/sys/health 2>/dev/null || echo '{}'") || health='{}'

        local sealed standby
        sealed=$(echo "$health" | jq -r '.sealed')
        standby=$(echo "$health" | jq -r '.standby')

        if [ "$sealed" == "false" ] && [ "$standby" == "false" ]; then
            log_info "Recovery node is now the active leader"
            return 0
        fi

        local status="sealed=$sealed standby=$standby"
        log_info "Not ready yet ($status) — ${elapsed}s/${max_wait}s..."
    done

    log_error "Timed out waiting for recovery node to become leader"
    return 1
}

# Wait for remaining nodes to rejoin via auto_join
wait_for_peers_rejoin() {
    local expected_peers="$INSTANCE_COUNT"

    if [ "$expected_peers" -le 1 ]; then
        log_info "Single-node cluster — no peers to wait for"
        return 0
    fi

    log_step "Waiting for $((expected_peers - 1)) peer(s) to rejoin..."

    # Restart Vault on the non-recovery nodes so they re-trigger auto_join
    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        local iid
        iid=$(echo "$INSTANCES_JSON" | jq -r ".[$i].InstanceId")
        [ "$iid" == "$RECOVERY_NODE" ] && continue

        log_info "Restarting Vault on $iid to trigger auto_join..."
        ssm_run "$iid" "systemctl restart vault" >/dev/null
    done

    local max_wait=300
    local wait_interval=15
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))

        local peer_count
        peer_count=$(ssm_run "$RECOVERY_NODE" \
            "VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/tls/ca.crt vault operator raft list-peers -format=json 2>/dev/null | jq '.data.config.servers | length'" \
            || echo "0")
        peer_count=$(echo "$peer_count" | tr -d '[:space:]')

        if [ "$peer_count" -ge "$expected_peers" ]; then
            log_info "All $peer_count peers have rejoined"
            return 0
        fi

        log_info "Peers: $peer_count/$expected_peers (${elapsed}s/${max_wait}s)..."
    done

    log_warn "Timed out waiting for all peers — $peer_count/$expected_peers rejoined"
    log_warn "Remaining nodes may need manual restart: systemctl restart vault"
    return 1
}

# Final status check
final_verification() {
    log_step "Final cluster verification..."

    local raft_status
    raft_status=$(ssm_run "$RECOVERY_NODE" \
        "VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/tls/ca.crt vault operator raft list-peers -format=json 2>/dev/null" \
        || echo '{}')

    echo ""
    echo "Raft peers:"
    echo "$raft_status" | jq -r '.data.config.servers[] | "  [\(if .leader then "LEADER" else "FOLLOWER" end)] \(.node_id) — \(.address)"' 2>/dev/null || echo "  (unable to list peers)"
}

# Main
main() {
    echo "=========================================="
    echo "   Vault Raft Cluster Recovery"
    echo "=========================================="
    echo ""

    check_prerequisites
    discover_instances
    echo ""
    check_no_leader

    echo ""
    select_recovery_node
    echo ""
    echo "Recovery plan:"
    echo "  Cluster:       $CLUSTER_NAME"
    echo "  Recovery node: $RECOVERY_NODE ($RECOVERY_IP)"
    echo "  Recovery AZ:   $RECOVERY_AZ"
    echo "  Raft node_id:  $RECOVERY_NODE_ID"
    echo ""
    log_warn "This will:"
    echo "  1. Stop Vault on the recovery node"
    echo "  2. Write a single-node peers.json (overrides Raft membership)"
    echo "  3. Restart Vault — recovery node bootstraps as sole leader"
    echo "  4. Restart Vault on remaining nodes to trigger auto_join"
    echo "  5. Wait for all peers to rejoin the cluster"
    echo ""
    log_warn "The Raft log on the recovery node becomes the source of truth."
    log_warn "Any writes that only reached non-recovery nodes will be LOST."

    if [ "$AUTO_CONFIRM" != "true" ]; then
        echo ""
        read -p "Continue with Raft recovery? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Aborted"
            exit 0
        fi
    fi

    echo ""
    write_peers_json
    echo ""

    if ! wait_for_recovery_leader; then
        log_error "Recovery failed — check /var/log/vault-setup.log on $RECOVERY_NODE"
        exit 1
    fi

    echo ""
    wait_for_peers_rejoin

    echo ""
    echo "=========================================="
    final_verification
    echo ""
    log_info "Raft cluster recovery complete"
    echo "=========================================="
}

main "$@"
