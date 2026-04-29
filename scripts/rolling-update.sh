#!/bin/bash
#
# rolling-update.sh - Perform rolling update of Vault cluster
#
# This script:
# 1. Runs tofu apply to update infrastructure (userdata, etc.)
# 2. For each node, one at a time:
#    - Terminates the old instance (EBS volume preserved)
#    - Launches a new instance (reattaches EBS volume)
#    - New instance uses same stable node_id and rejoins Raft automatically
#    - Verifies cluster health before proceeding
#
# Because node IDs are stable per-AZ (not per-instance), Raft membership
# doesn't change during updates. The replacement instance simply takes over
# the same identity and resumes with existing Raft data.
#
# Usage: ./rolling-update.sh <env> [--skip-terraform]
#
# Prerequisites:
#   - AWS CLI configured
#   - OpenTofu installed (if not using --skip-terraform)
#   - VAULT_TOKEN environment variable set

set -euo pipefail

# Parse arguments
ENV=""
SKIP_TERRAFORM=false
for arg in "$@"; do
    case $arg in
        --skip-terraform)
            SKIP_TERRAFORM=true
            ;;
        -*)
            echo "Unknown option: $arg"
            echo "Usage: $0 <env> [--skip-terraform]"
            exit 1
            ;;
        *)
            if [ -z "$ENV" ]; then
                ENV="$arg"
            fi
            ;;
    esac
done

if [ -z "$ENV" ]; then
    echo "Usage: $0 <env> [--skip-terraform]"
    echo "Environments: nonprod-test, nonprod, prod"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TOFU_DIR="$PROJECT_DIR/terraform"

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

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    command -v aws >/dev/null 2>&1 || { log_error "aws CLI not found"; exit 1; }
    command -v vault >/dev/null 2>&1 || { log_error "vault CLI not found"; exit 1; }
    command -v jq >/dev/null 2>&1 || { log_error "jq not found"; exit 1; }

    if [ "$SKIP_TERRAFORM" != "true" ]; then
        command -v tofu >/dev/null 2>&1 || { log_error "tofu not found (required unless --skip-terraform)"; exit 1; }
    fi

    if [ -z "${VAULT_TOKEN:-}" ]; then
        log_error "VAULT_TOKEN environment variable not set"
        echo "A token with operator permissions is required for rolling updates"
        exit 1
    fi

    log_info "All prerequisites met"
}

# Get config from SSM and AWS API
get_config() {
    log_info "Getting cluster config for $CLUSTER_NAME..."

    if [ -z "${VAULT_ADDR:-}" ]; then
        VAULT_ADDR=$(ssm_get vault-url)
        export VAULT_ADDR
    fi

    lookup_ebs_volumes
}

# Check cluster health
check_cluster_health() {
    log_info "Checking cluster health..."

    local health
    health=$(curl -sk "$VAULT_ADDR/v1/sys/health" || echo '{"error": "unreachable"}')

    if echo "$health" | jq -e '.error' >/dev/null 2>&1; then
        log_error "Cannot reach Vault at $VAULT_ADDR"
        return 1
    fi

    local sealed
    sealed=$(echo "$health" | jq -r '.sealed')

    if [ "$sealed" == "true" ]; then
        log_error "Vault is sealed!"
        return 1
    fi

    local peer_count
    peer_count=$(vault operator raft list-peers -format=json 2>/dev/null | jq -r '.data.config.servers | length' || echo "0")

    if [ "$peer_count" -lt 2 ]; then
        log_error "Only $peer_count Raft peers - need at least 2 for safe rolling update"
        return 1
    fi

    log_info "Cluster healthy with $peer_count peers"
    return 0
}

# Get running instances for the cluster
get_running_instances() {
    aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:vault-cluster,Values=$CLUSTER_NAME" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`vault-az`].Value|[0]]' \
        --output text
}

# Find AZ index from AZ name
get_az_index() {
    local az_name="$1"
    for i in "${!EBS_VOLUME_AZS[@]}"; do
        if [ "${EBS_VOLUME_AZS[$i]}" == "$az_name" ]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# Per-instance canary: prove this SPECIFIC new instance is truly healthy
# before moving on to the next AZ. Prevents the "bad userdata rolls across
# all 3 nodes" failure — catches the break on node 1 instead of node 2.
#
# Six checks, all must pass within CANARY_TIMEOUT (default 300s):
#   1. SSM reachable on the instance (agent online)
#   2. systemd says vault.service is active
#   3. /v1/sys/health returns 200 (leader) or 429 (unsealed standby)
#   4. node_id appears in Raft peer list (joined consensus)
#   5. node_id has voter=true (not stuck as non-voter)
#   6. peer_count from this node's view >= expected_peers (no split view)
#
# Args: <instance_id> <az> <expected_peers>
# Returns: 0=healthy, 1=unhealthy (logs reason)
canary_check_node() {
    local instance_id="$1"
    local az="$2"
    local expected_peers="$3"
    local my_node_id="${CLUSTER_NAME}-${az}"
    local timeout="${CANARY_TIMEOUT:-300}"
    local interval=15
    local elapsed=0

    log_step "Canary checks on $instance_id ($my_node_id, timeout ${timeout}s)..."

    # Build the remote health probe as a single SSM command. Runs on the new
    # instance and emits tab-separated output: <service_status>\t<http_code>
    local probe_cmd='
        status=$(systemctl is-active vault 2>/dev/null || echo "unknown");
        http=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" https://127.0.0.1:8200/v1/sys/health?standbyok=true 2>/dev/null || echo "000");
        echo -e "${status}\t${http}"
    '

    while [ $elapsed -lt $timeout ]; do
        # --- Remote probe via SSM ---
        local params_file cmd_id
        params_file=$(mktemp)
        jq -n --arg cmd "$probe_cmd" '{"commands":[$cmd]}' > "$params_file"

        cmd_id=$(aws ssm send-command \
            --region "$AWS_REGION" \
            --instance-ids "$instance_id" \
            --document-name "AWS-RunShellScript" \
            --parameters "file://$params_file" \
            --query 'Command.CommandId' \
            --output text 2>/dev/null) || true
        rm -f "$params_file"

        local ssm_status="unreachable" service_status="unknown" http_code="000"
        if [ -n "$cmd_id" ]; then
            aws ssm wait command-executed \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$instance_id" 2>/dev/null || true

            local probe_out
            probe_out=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$instance_id" \
                --query 'StandardOutputContent' \
                --output text 2>/dev/null || echo "")
            if [ -n "$probe_out" ]; then
                ssm_status="ok"
                service_status=$(echo "$probe_out" | awk -F'\t' '{print $1}' | tr -d '[:space:]')
                http_code=$(echo "$probe_out" | awk -F'\t' '{print $2}' | tr -d '[:space:]')
                [ -z "$service_status" ] && service_status="unknown"
                [ -z "$http_code" ] && http_code="000"
            fi
        fi

        # --- Raft peer list from the leader (via local VAULT_ADDR) ---
        local raft
        raft=$(vault operator raft list-peers -format=json 2>/dev/null || echo '{}')
        [ -z "$raft" ] && raft='{}'

        # --- Apply decision logic ---
        # (Checks ordered cheap-to-expensive for clear log messages)
        if [ "$ssm_status" != "ok" ]; then
            log_info "  SSM not reachable yet (waiting, ${elapsed}s/${timeout}s)..."
        elif [ "$service_status" != "active" ]; then
            log_info "  vault service status=$service_status (waiting, ${elapsed}s/${timeout}s)..."
        else
            case "$http_code" in
                200|429)
                    local node_present is_voter peer_count
                    node_present=$(echo "$raft" | jq -r --arg id "$my_node_id" \
                        '[.data.config.servers[]? | select(.node_id == $id)] | length' 2>/dev/null || echo "0")
                    node_present=$(echo "$node_present" | tr -d '[:space:]')
                    [ -z "$node_present" ] && node_present=0

                    is_voter=$(echo "$raft" | jq -r --arg id "$my_node_id" \
                        '.data.config.servers[]? | select(.node_id == $id) | .voter | tostring' 2>/dev/null || echo "false")
                    is_voter=$(echo "$is_voter" | head -1 | tr -d '[:space:]')
                    [ -z "$is_voter" ] && is_voter="false"

                    peer_count=$(echo "$raft" | jq -r '.data.config.servers | length? // 0' 2>/dev/null || echo "0")
                    peer_count=$(echo "$peer_count" | tr -d '[:space:]')
                    [ -z "$peer_count" ] && peer_count=0

                    if [ "$node_present" -eq 0 ] 2>/dev/null; then
                        log_info "  $my_node_id not yet in Raft peer list (${elapsed}s/${timeout}s)..."
                    elif [ "$is_voter" != "true" ]; then
                        log_info "  $my_node_id is non-voter, awaiting promotion (${elapsed}s/${timeout}s)..."
                    elif [ "$peer_count" -lt "$expected_peers" ] 2>/dev/null; then
                        log_info "  $my_node_id peer view=$peer_count/$expected_peers (${elapsed}s/${timeout}s)..."
                    else
                        log_info "Canary PASS: $instance_id healthy (service=active, http=$http_code, voter=true, peers=$peer_count)"
                        return 0
                    fi
                    ;;
                *)
                    log_info "  vault health HTTP=$http_code (waiting for unseal, ${elapsed}s/${timeout}s)..."
                    ;;
            esac
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Canary TIMEOUT: $instance_id did not become healthy within ${timeout}s"
    log_error "  last observed: ssm=$ssm_status service=$service_status http=$http_code"
    log_error "  Inspect the node: aws ssm start-session --target $instance_id --region $AWS_REGION"
    return 1
}

# Wait for cluster to be stable with expected peer count
wait_for_cluster_stable() {
    local expected_peers="$1"
    local max_wait=300
    local wait_interval=15
    local elapsed=0

    log_info "Waiting for cluster to stabilize with $expected_peers peers..."

    while [ $elapsed -lt $max_wait ]; do
        local health
        health=$(curl -sk "$VAULT_ADDR/v1/sys/health" 2>/dev/null || echo '{"sealed": true}')
        local sealed
        sealed=$(echo "$health" | jq -r '.sealed')

        if [ "$sealed" == "false" ]; then
            local peer_count
            peer_count=$(vault operator raft list-peers -format=json 2>/dev/null | jq -r '.data.config.servers | length' || echo "0")

            if [ "$peer_count" -ge "$expected_peers" ]; then
                log_info "Cluster stable with $peer_count peers"
                return 0
            fi

            log_info "Peers: $peer_count/$expected_peers (waiting...)"
        else
            log_info "Cluster sealed or unreachable (waiting...)"
        fi

        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))
    done

    log_warn "Timeout waiting for cluster to stabilize"
    return 1
}

# Step down the leader and wait for a new leader to be elected
step_down_leader() {
    log_info "Requesting leader step-down..."
    vault operator step-down

    local max_wait=60
    local wait_interval=5
    local elapsed=0

    log_info "Waiting for new leader election..."
    while [ $elapsed -lt $max_wait ]; do
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))

        local new_leader
        new_leader=$(vault operator raft list-peers -format=json 2>/dev/null \
            | jq -r '.data.config.servers[] | select(.leader == true) | .node_id' || true)

        if [ -n "$new_leader" ]; then
            log_info "New leader elected: $new_leader"
            return 0
        fi

        log_info "No leader yet (${elapsed}s/${max_wait}s)..."
    done

    log_error "Timed out waiting for new leader election"
    return 1
}

# Update one node
update_node() {
    local instance_id="$1"
    local az="$2"
    local az_index="$3"

    echo ""
    echo "----------------------------------------"
    log_step "Updating node: $instance_id ($az)"
    echo "----------------------------------------"

    # Get current peer count
    local initial_peers
    initial_peers=$(vault operator raft list-peers -format=json | jq -r '.data.config.servers | length')

    # Terminate the old node (don't remove from Raft - new instance will rejoin with same node_id)
    log_info "Terminating old node..."
    if ! "$SCRIPT_DIR/terminate-node.sh" "$VAULT_ENV" "$instance_id" --yes; then
        log_error "Failed to terminate node $instance_id"
        exit 1
    fi

    # Wait for old instance to fully terminate so auto_join won't discover it
    log_info "Waiting for instance termination..."
    aws ec2 wait instance-terminated \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" 2>/dev/null || true

    # Launch new node (will use same node_id and rejoin Raft automatically)
    log_info "Launching new node..."
    if ! "$SCRIPT_DIR/launch-node.sh" "$VAULT_ENV" "$az_index" --yes; then
        log_error "Failed to launch new node in $az"
        exit 1
    fi

    # Discover the new instance_id so the canary can probe it specifically.
    # launch-node.sh tags instances with vault-az; pick the running one for this AZ.
    local new_instance_id
    new_instance_id=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:vault-cluster,Values=$CLUSTER_NAME" \
            "Name=tag:vault-az,Values=$az" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null | awk '{print $1}')

    if [ -z "$new_instance_id" ] || [ "$new_instance_id" = "None" ]; then
        log_error "Could not discover new instance in $az after launch"
        exit 1
    fi

    # Per-instance canary: prove THIS instance is truly healthy before moving on.
    # Fails loudly at node 1 if userdata/AMI/KMS is broken, preventing cascading
    # failures across all three AZs.
    if ! canary_check_node "$new_instance_id" "$az" "$initial_peers"; then
        log_error "Canary check failed for $new_instance_id ($az)"
        log_error "Halting rolling update — cluster is at N-0-failed state"
        log_error "(2 old nodes still healthy + 1 new-broken node = quorum retained)"
        log_error "Diagnose before re-running to avoid cascading failure to next AZ"
        exit 1
    fi

    # Cluster-wide stability check (catches view from the leader)
    if ! wait_for_cluster_stable "$initial_peers"; then
        log_error "Cluster did not stabilize after updating node in $az"
        log_error "Manual intervention may be required"
        exit 1
    fi

    log_info "Node updated successfully"
}

# Run Terraform apply
run_terraform() {
    log_step "Running Terraform apply..."
    cd "$TOFU_DIR"

    local backend_config="$TOFU_DIR/backend-configs/$VAULT_ENV.hcl"
    local var_file="$TOFU_DIR/environments/$VAULT_ENV.tfvars"

    log_info "Initializing Terraform for $VAULT_ENV..."
    tofu init -reconfigure -backend-config="$backend_config" -input=false >/dev/null

    log_info "Planning changes..."
    local plan_exit_code=0
    tofu plan -detailed-exitcode -var-file="$var_file" -out=tfplan 2>&1 || plan_exit_code=$?

    # Exit codes: 0=no changes, 1=error, 2=changes present
    if [ "$plan_exit_code" -eq 0 ]; then
        log_info "No infrastructure changes detected"
        rm -f tfplan
        return 0
    elif [ "$plan_exit_code" -eq 1 ]; then
        log_error "Terraform plan failed"
        rm -f tfplan
        exit 1
    fi

    log_info "Applying changes..."
    tofu apply -auto-approve tfplan
    rm -f tfplan

    log_info "Terraform apply complete"
}

# Main execution
main() {
    echo "=========================================="
    echo "   Vault Cluster Rolling Update"
    echo "=========================================="
    echo ""

    check_prerequisites
    get_config

    echo ""
    echo "Configuration:"
    echo "  Cluster:    $CLUSTER_NAME"
    echo "  Region:     $AWS_REGION"
    echo "  Vault URL:  $VAULT_ADDR"
    echo "  Skip TF:    $SKIP_TERRAFORM"
    echo ""

    # Pre-flight health check
    log_step "Step 1: Pre-flight checks"
    if ! check_cluster_health; then
        log_error "Cluster is not healthy - aborting"
        exit 1
    fi

    echo ""
    log_info "Current Raft peers:"
    vault operator raft list-peers -format=json | jq -r '.data.config.servers[] | "  - \(.node_id) [\(if .leader then "LEADER" else "FOLLOWER" end)]"'

    # Get running instances
    echo ""
    log_step "Step 2: Identify nodes to update"
    local instances
    instances=$(get_running_instances)

    if [ -z "$instances" ]; then
        log_error "No running instances found for cluster: $CLUSTER_NAME"
        exit 1
    fi

    echo "Instances to update:"
    echo "$instances" | while read -r instance_id az; do
        echo "  - $instance_id ($az)"
    done

    # Terraform apply
    echo ""
    log_step "Step 3: Update infrastructure"
    if [ "$SKIP_TERRAFORM" == "true" ]; then
        log_info "Skipping Terraform (--skip-terraform specified)"
    else
        run_terraform
    fi

    # Confirmation
    echo ""
    log_warn "This will perform a rolling update of all Vault nodes."
    log_warn "Each node will be terminated and replaced one at a time."
    echo ""
    read -p "Continue with rolling update? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Aborted"
        exit 0
    fi

    # Rolling update
    echo ""
    log_step "Step 4: Rolling node replacement"

    local node_count=0
    local total_nodes
    total_nodes=$(echo "$instances" | wc -l | tr -d ' ')

    # Process non-leader nodes first, then leader
    local leader_instance=""
    local leader_az=""
    local leader_az_index=""

    while read -r instance_id az; do
        [ -z "$instance_id" ] && continue

        local az_index
        az_index=$(get_az_index "$az")

        # Check if this is the leader (match by AZ suffix since node_id = cluster-az)
        local is_leader
        is_leader=$(vault operator raft list-peers -format=json 2>/dev/null | jq -r --arg az "$az" \
            '.data.config.servers[]? | select(.node_id | endswith($az)) | .leader' 2>/dev/null || echo "false")
        [ -z "$is_leader" ] && is_leader="false"

        if [ "$is_leader" == "true" ]; then
            leader_instance="$instance_id"
            leader_az="$az"
            leader_az_index="$az_index"
            log_info "Deferring leader node: $instance_id ($az)"
            continue
        fi

        node_count=$((node_count + 1))
        echo ""
        log_step "Node $node_count/$total_nodes"
        update_node "$instance_id" "$az" "$az_index"

    done <<< "$instances"

    # Update leader last — step down first so a follower takes over
    if [ -n "$leader_instance" ]; then
        node_count=$((node_count + 1))
        echo ""
        log_step "Node $node_count/$total_nodes (LEADER - stepping down first)"
        if ! step_down_leader; then
            log_error "Leader step-down failed - aborting to avoid quorum loss"
            exit 1
        fi
        update_node "$leader_instance" "$leader_az" "$leader_az_index"
    fi

    # Final verification
    echo ""
    echo "=========================================="
    log_step "Step 5: Final verification"
    echo "=========================================="

    sleep 10

    if check_cluster_health; then
        echo ""
        log_info "Rolling update completed successfully!"
        echo ""
        log_info "Final Raft peer status:"
        vault operator raft list-peers
    else
        log_error "Final health check failed - please investigate"
        exit 1
    fi
}

main "$@"
