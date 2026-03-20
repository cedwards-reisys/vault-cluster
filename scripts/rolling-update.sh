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
        sealed=$(echo "$health" | jq -r '.sealed // true')

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

    # Wait a bit for the instance to fully terminate and volume to detach
    log_info "Waiting for instance termination..."
    sleep 15

    # Launch new node (will use same node_id and rejoin Raft automatically)
    log_info "Launching new node..."
    if ! "$SCRIPT_DIR/launch-node.sh" "$VAULT_ENV" "$az_index" --yes; then
        log_error "Failed to launch new node in $az"
        exit 1
    fi

    # Wait for cluster to be stable (node rejoins with same identity)
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

        # Check if this is the leader
        local is_leader
        is_leader=$(vault operator raft list-peers -format=json | jq -r --arg iid "$instance_id" \
            '.data.config.servers[] | select(.node_id | contains($iid)) | .leader // false')

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

    # Update leader last
    if [ -n "$leader_instance" ]; then
        node_count=$((node_count + 1))
        echo ""
        log_step "Node $node_count/$total_nodes (LEADER)"
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
