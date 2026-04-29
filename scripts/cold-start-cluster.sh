#!/bin/bash
#
# cold-start-cluster.sh - Bring a Vault cluster back from zero running nodes
#
# When to use:
#   All Vault nodes were terminated (intentionally or otherwise). The persistent
#   EBS volumes still contain Raft data from the previous cluster, so new nodes
#   will auto-unseal via KMS but get stuck — the single node can't achieve Raft
#   quorum against a 3-node membership list and will never elect itself leader.
#
# What it does:
#   1. Launches node 0 (first AZ) via launch-node.sh
#   2. Waits for Vault to start and auto-unseal
#   3. Detects the stuck state (unsealed, no leader, no quorum)
#   4. Writes a single-node peers.json to force leader bootstrap
#   5. Restarts Vault — node 0 becomes the sole leader
#   6. Launches remaining nodes (1, 2) which rejoin via auto_join
#   7. Verifies full cluster health
#
# Usage: ./cold-start-cluster.sh <env> [--yes] [--node-0-only]
#
# Options:
#   --yes           Skip confirmation prompts (for automation / Jenkins)
#   --node-0-only   Only recover node 0 as leader; don't launch remaining nodes
#
# Prerequisites:
#   - AWS CLI configured with SSM permissions
#   - launch-node.sh and its dependencies available
#   - Persistent EBS volumes exist with prior Raft data (or fresh volumes for init)

set -euo pipefail

# Parse arguments
ENV=""
AUTO_CONFIRM=false
NODE_0_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --yes|-y)
            AUTO_CONFIRM=true
            shift
            ;;
        --node-0-only)
            NODE_0_ONLY=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 <env> [--yes] [--node-0-only]"
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
    echo "Usage: $0 <env> [--yes] [--node-0-only]"
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

# Verify no instances are already running for this cluster
check_no_running_instances() {
    log_step "Verifying no instances are currently running..."

    local running
    running=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:vault-cluster,Values=$CLUSTER_NAME" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)

    if [ -n "$running" ]; then
        log_error "Existing instances found for $CLUSTER_NAME:"
        echo "  $running"
        log_error "This script is for cold-start recovery from zero nodes."
        log_error "Use recover-raft-cluster.sh if nodes are running but leaderless."
        exit 1
    fi

    log_info "Confirmed: no running instances for $CLUSTER_NAME"
}

# Launch node 0 and capture its instance ID
launch_node_0() {
    log_step "Launching node 0 (AZ index 0)..."

    "$SCRIPT_DIR/launch-node.sh" "$VAULT_ENV" 0 --yes

    # Discover the instance we just launched
    NODE_0_ID=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:vault-cluster,Values=$CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[] | sort_by(@, &LaunchTime) | [-1].InstanceId' \
        --output text)

    if [ -z "$NODE_0_ID" ] || [ "$NODE_0_ID" = "None" ]; then
        log_error "launch-node.sh did not produce a running instance for cluster $CLUSTER_NAME"
        exit 1
    fi

    NODE_0_IP=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$NODE_0_ID" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text)

    NODE_0_AZ=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$NODE_0_ID" \
        --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
        --output text)

    NODE_0_RAFT_ID="${CLUSTER_NAME}-${NODE_0_AZ}"

    log_info "Node 0: $NODE_0_ID ($NODE_0_IP) in $NODE_0_AZ"
    log_info "Raft node_id: $NODE_0_RAFT_ID"
}

# Wait for Vault to be running (any state — sealed, standby, or active)
wait_for_vault_process() {
    log_step "Waiting for Vault process to start on node 0..."

    local max_wait=300
    local wait_interval=15
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        local http_code
        http_code=$(ssm_run "$NODE_0_ID" \
            "curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8200/v1/sys/health 2>/dev/null || echo 000") || true
        http_code=$(echo "$http_code" | tr -d '[:space:]')

        if [ "$http_code" != "000" ] && [ "$http_code" != "" ]; then
            log_info "Vault is responding (HTTP $http_code)"
            return 0
        fi

        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))
        log_info "Vault not responding yet (${elapsed}s/${max_wait}s)..."
    done

    log_error "Vault did not start within ${max_wait}s"
    log_error "Check logs: aws ssm start-session --target $NODE_0_ID --region $AWS_REGION"
    return 1
}

# Determine what state Vault is in and whether recovery is needed
assess_vault_state() {
    log_step "Assessing Vault state on node 0..."

    local health
    health=$(ssm_run "$NODE_0_ID" \
        "curl -sk https://127.0.0.1:8200/v1/sys/health 2>/dev/null || echo '{}'") || health='{}'
    [ -z "$health" ] && health='{}'

    local http_code
    http_code=$(ssm_run "$NODE_0_ID" \
        "curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8200/v1/sys/health 2>/dev/null || echo 000") || true
    http_code=$(echo "$http_code" | tr -d '[:space:]')
    [ -z "$http_code" ] && http_code="000"

    VAULT_INITIALIZED=$(echo "$health" | jq -r '.initialized // "unknown"' 2>/dev/null || echo "unknown")
    VAULT_SEALED=$(echo "$health" | jq -r '.sealed // "unknown"' 2>/dev/null || echo "unknown")
    VAULT_STANDBY=$(echo "$health" | jq -r '.standby // "unknown"' 2>/dev/null || echo "unknown")

    echo ""
    echo "  HTTP status:  $http_code"
    echo "  Initialized:  $VAULT_INITIALIZED"
    echo "  Sealed:       $VAULT_SEALED"
    echo "  Standby:      $VAULT_STANDBY"
    echo ""

    # Case 1: Already active leader (unlikely but handle it)
    if [ "$VAULT_SEALED" == "false" ] && [ "$VAULT_STANDBY" == "false" ]; then
        log_info "Node 0 is already the active leader — no recovery needed"
        NEEDS_RECOVERY=false
        return 0
    fi

    # Case 2: Not initialized (fresh EBS volumes — needs vault operator init)
    if [ "$VAULT_INITIALIZED" == "false" ]; then
        log_error "Vault is not initialized — this is a fresh cluster, not a recovery"
        log_error "Run 'vault operator init' to initialize, then launch remaining nodes"
        exit 1
    fi

    # Case 3: Sealed (KMS auto-unseal should handle this — wait longer)
    if [ "$VAULT_SEALED" != "false" ]; then
        log_warn "Vault is sealed or state unknown (sealed=$VAULT_SEALED) — waiting for KMS auto-unseal..."
        local max_wait=120
        local elapsed=0
        local sealed="$VAULT_SEALED"
        while [ $elapsed -lt $max_wait ]; do
            sleep 15
            elapsed=$((elapsed + 15))
            sealed=$(ssm_run "$NODE_0_ID" \
                "curl -sk https://127.0.0.1:8200/v1/sys/health 2>/dev/null | jq -r '.sealed // \"unknown\"'" || echo "unknown")
            sealed=$(echo "$sealed" | tr -d '[:space:]')
            [ -z "$sealed" ] && sealed="unknown"
            if [ "$sealed" = "false" ]; then
                log_info "Vault auto-unsealed successfully"
                break
            fi
            log_info "Still sealed/unknown (sealed=$sealed, ${elapsed}s/${max_wait}s)..."
        done

        # Strict check: only proceed to destructive recovery if we can *prove* unsealed.
        if [ "$sealed" != "false" ]; then
            log_error "Vault did not confirm unsealed (sealed=$sealed) — aborting before destructive recovery"
            log_error "Check KMS key and IAM permissions, or debug: aws ssm start-session --target $NODE_0_ID --region $AWS_REGION"
            exit 1
        fi
    fi

    # Case 4: Unsealed but standby (no quorum) — this is the expected stuck state
    log_info "Node is unsealed but has no leader — Raft quorum lost (expected)"
    NEEDS_RECOVERY=true
}

# Write single-node peers.json and restart Vault to force leader bootstrap
apply_peers_recovery() {
    log_step "Applying Raft peers.json recovery..."

    local peers_json
    peers_json=$(jq -n --arg id "$NODE_0_RAFT_ID" --arg addr "${NODE_0_IP}:8201" \
        '[{"id": $id, "address": $addr, "non_voter": false}]')

    log_info "Recovery peers.json:"
    echo "$peers_json" | jq '.'

    log_info "Stopping Vault..."
    ssm_run "$NODE_0_ID" "systemctl stop vault" >/dev/null

    log_info "Writing peers.json to /opt/vault/data/raft/peers.json..."
    ssm_run "$NODE_0_ID" "cat > /opt/vault/data/raft/peers.json << 'PEERSEOF'
${peers_json}
PEERSEOF
chown vault:vault /opt/vault/data/raft/peers.json" >/dev/null

    log_info "Starting Vault..."
    ssm_run "$NODE_0_ID" "systemctl start vault" >/dev/null
}

# Wait for node 0 to become the active leader
wait_for_leader() {
    log_step "Waiting for node 0 to become leader..."

    local max_wait=120
    local wait_interval=10
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))

        local health
        health=$(ssm_run "$NODE_0_ID" \
            "curl -sk https://127.0.0.1:8200/v1/sys/health 2>/dev/null || echo '{}'") || health='{}'

        local sealed standby
        sealed=$(echo "$health" | jq -r '.sealed')
        standby=$(echo "$health" | jq -r '.standby')

        if [ "$sealed" == "false" ] && [ "$standby" == "false" ]; then
            log_info "Node 0 is now the active leader"
            return 0
        fi

        log_info "Not leader yet (sealed=$sealed standby=$standby) — ${elapsed}s/${max_wait}s..."
    done

    log_error "Timed out waiting for node 0 to become leader"
    log_error "Check logs: aws ssm start-session --target $NODE_0_ID --region $AWS_REGION"
    return 1
}

# Launch remaining nodes and wait for them to join
launch_remaining_nodes() {
    log_step "Launching remaining nodes..."

    lookup_ebs_volumes
    local total_nodes=${#EBS_VOLUME_IDS[@]}

    if [ "$total_nodes" -le 1 ]; then
        log_info "Single-node cluster — no additional nodes to launch"
        return 0
    fi

    for az_index in $(seq 1 $((total_nodes - 1))); do
        log_info "Launching node $az_index..."
        "$SCRIPT_DIR/launch-node.sh" "$VAULT_ENV" "$az_index" --yes
    done

    # Wipe stale Raft data on new nodes so they rejoin as fresh peers
    # The leader (node 0) is source of truth and will replicate
    log_info "Waiting for new nodes to start..."
    sleep 30

    local new_instances
    new_instances=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:vault-cluster,Values=$CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)

    for iid in $new_instances; do
        [ "$iid" == "$NODE_0_ID" ] && continue
        log_info "Wiping stale Raft data on $iid so it rejoins fresh..."
        ssm_run "$iid" "systemctl stop vault && rm -rf /opt/vault/data/* && systemctl start vault" >/dev/null
    done

    # Wait for all peers to rejoin
    log_step "Waiting for all peers to rejoin..."
    local max_wait=300
    local wait_interval=15
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))

        local peer_count
        peer_count=$(ssm_run "$NODE_0_ID" \
            "VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/tls/ca.crt vault operator raft list-peers -format=json 2>/dev/null | jq '.data.config.servers | length'" \
            || true)
        peer_count=$(echo "$peer_count" | grep -oE '^[0-9]+$' | head -1 || true)
        peer_count="${peer_count:-0}"

        if [ "$peer_count" -ge "$total_nodes" ]; then
            log_info "All $peer_count peers have joined"
            return 0
        fi

        log_info "Peers: $peer_count/$total_nodes (${elapsed}s/${max_wait}s)..."
    done

    log_warn "Timed out — $peer_count/$total_nodes peers joined"
    log_warn "Remaining nodes may need: systemctl stop vault && rm -rf /opt/vault/data/* && systemctl start vault"
    return 1
}

# Final verification
final_verification() {
    log_step "Final cluster verification..."

    local raft_status
    raft_status=$(ssm_run "$NODE_0_ID" \
        "VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/tls/ca.crt vault operator raft list-peers -format=json 2>/dev/null" \
        || echo '{}')

    echo ""
    echo "Raft peers:"
    echo "$raft_status" | jq -r '.data.config.servers[] | "  [\(if .leader then "LEADER" else "FOLLOWER" end)] \(.node_id) — \(.address)"' 2>/dev/null || echo "  (unable to list peers)"

    local health
    health=$(ssm_run "$NODE_0_ID" \
        "curl -sk https://127.0.0.1:8200/v1/sys/health 2>/dev/null || echo '{}'") || health='{}'

    local version
    version=$(echo "$health" | jq -r '.version // "unknown"')

    echo ""
    echo "Vault version: $version"
}

# Main
main() {
    echo "=========================================="
    echo "   Vault Cluster Cold Start Recovery"
    echo "=========================================="
    echo ""

    log_info "Environment: $VAULT_ENV"
    log_info "Cluster:     $CLUSTER_NAME"
    log_info "Region:      $AWS_REGION"
    echo ""

    check_no_running_instances

    echo ""
    log_warn "This will:"
    echo "  1. Launch node 0 in the first AZ"
    echo "  2. Detect the stuck Raft state (no quorum)"
    echo "  3. Write peers.json to force node 0 as sole leader"
    echo "  4. Restart Vault on node 0"
    if [ "$NODE_0_ONLY" != "true" ]; then
        echo "  5. Launch remaining nodes and wait for them to rejoin"
    fi
    echo ""
    log_warn "The Raft log on node 0's EBS volume becomes the source of truth."

    if [ "$AUTO_CONFIRM" != "true" ]; then
        echo ""
        read -p "Continue with cold start recovery? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Aborted"
            exit 0
        fi
    fi

    echo ""
    launch_node_0

    echo ""
    if ! wait_for_vault_process; then
        exit 1
    fi

    echo ""
    assess_vault_state

    if [ "$NEEDS_RECOVERY" == "true" ]; then
        echo ""
        apply_peers_recovery

        echo ""
        if ! wait_for_leader; then
            exit 1
        fi
    fi

    if [ "$NODE_0_ONLY" != "true" ]; then
        echo ""
        launch_remaining_nodes
    fi

    echo ""
    echo "=========================================="
    final_verification
    echo ""
    log_info "Cold start recovery complete"
    echo "=========================================="

    if [ "$NODE_0_ONLY" == "true" ]; then
        echo ""
        log_info "Node 0 is live. Launch remaining nodes when ready:"
        echo "  ./launch-node.sh $VAULT_ENV 1 --yes"
        echo "  ./launch-node.sh $VAULT_ENV 2 --yes"
        echo ""
        log_warn "Remaining nodes may need stale Raft data wiped before they can rejoin."
    fi
}

main "$@"
