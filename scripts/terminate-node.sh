#!/bin/bash
#
# terminate-node.sh - Gracefully terminate a Vault node
#
# This script:
# 1. Deregisters from the NLB target group
# 2. Optionally removes the node from Raft (--remove-from-raft flag)
# 3. Detaches the EBS data volume (preserving data)
# 4. Terminates the EC2 instance
#
# Usage: ./terminate-node.sh <env> <instance-id> [--remove-from-raft] [--yes]
#
# Options:
#   --remove-from-raft  Remove node from Raft cluster (for permanent removal)
#   --yes               Skip confirmation prompt (for automation)
#
# By default, the node is NOT removed from Raft because:
# - Node IDs are stable per-AZ (not per-instance)
# - The replacement instance will use the same node_id and rejoin automatically
# - This enables seamless instance replacement without Raft membership changes
#
# Use --remove-from-raft when:
# - Permanently removing a node (scaling down)
# - Resetting a node with corrupted Raft data
# - Changing the AZ layout
#
# Prerequisites:
#   - AWS CLI configured
#   - VAULT_TOKEN set (required if using --remove-from-raft)

set -euo pipefail

# Parse arguments
REMOVE_FROM_RAFT=false
AUTO_CONFIRM=false
ENV=""
INSTANCE_ID=""

for arg in "$@"; do
    case $arg in
        --remove-from-raft)
            REMOVE_FROM_RAFT=true
            ;;
        --yes|-y)
            AUTO_CONFIRM=true
            ;;
        -*)
            echo "Unknown option: $arg"
            echo "Usage: $0 <env> <instance-id> [--remove-from-raft] [--yes]"
            exit 1
            ;;
        *)
            if [ -z "$ENV" ]; then
                ENV="$arg"
            elif [ -z "$INSTANCE_ID" ]; then
                INSTANCE_ID="$arg"
            fi
            ;;
    esac
done

if [ -z "$ENV" ] || [ -z "$INSTANCE_ID" ]; then
    echo "Usage: $0 <env> <instance-id> [--remove-from-raft] [--yes]"
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
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    command -v aws >/dev/null 2>&1 || { log_error "aws CLI not found"; exit 1; }
    command -v jq >/dev/null 2>&1 || { log_error "jq not found"; exit 1; }

    if [ -z "${VAULT_TOKEN:-}" ]; then
        log_warn "VAULT_TOKEN not set - will skip Raft peer removal"
        log_warn "The node will be removed from Raft automatically after timeout"
    fi
}

# Get config from SSM
get_config() {
    log_info "Getting cluster config for $CLUSTER_NAME..."

    TARGET_GROUP_ARN=$(cfg_get target_group_arn)

    if [ -z "${VAULT_ADDR:-}" ]; then
        VAULT_ADDR=$(ssm_get vault-url)
    fi
    export VAULT_ADDR
}

# Get instance details
get_instance_details() {
    log_info "Getting instance details for $INSTANCE_ID..."

    local instance_info
    instance_info=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0]' \
        --output json 2>/dev/null || echo '{}')

    if [ "$instance_info" == "{}" ] || [ -z "$instance_info" ]; then
        log_error "Instance not found: $INSTANCE_ID"
        exit 1
    fi

    INSTANCE_STATE=$(echo "$instance_info" | jq -r '.State.Name')
    INSTANCE_AZ=$(echo "$instance_info" | jq -r '.Placement.AvailabilityZone')
    INSTANCE_NAME=$(echo "$instance_info" | jq -r '.Tags[] | select(.Key=="Name") | .Value // "unknown"')

    # Get attached data volume (not the root volume)
    DATA_VOLUME_ID=$(echo "$instance_info" | jq -r '.BlockDeviceMappings[] | select(.DeviceName=="/dev/xvdf") | .Ebs.VolumeId // empty')

    log_info "Instance: $INSTANCE_NAME"
    log_info "State: $INSTANCE_STATE"
    log_info "AZ: $INSTANCE_AZ"
    if [ -n "$DATA_VOLUME_ID" ]; then
        log_info "Data Volume: $DATA_VOLUME_ID"
    else
        log_warn "No data volume found at /dev/xvdf"
    fi
}

# Find and remove node from Raft (only if --remove-from-raft flag is set)
remove_from_raft() {
    if [ "$REMOVE_FROM_RAFT" != "true" ]; then
        log_info "Skipping Raft removal (node will rejoin with same identity)"
        return 0
    fi

    if [ -z "${VAULT_TOKEN:-}" ]; then
        log_error "VAULT_TOKEN required for --remove-from-raft"
        exit 1
    fi

    log_info "Looking for Raft node ID..."

    # Get Raft peers and find the one matching our AZ
    local raft_peers
    raft_peers=$(vault operator raft list-peers -format=json 2>/dev/null || echo '{}')

    if echo "$raft_peers" | jq -e '.data.config.servers' >/dev/null 2>&1; then
        # Find node ID matching the AZ (stable node_id format: cluster-az)
        local node_id
        node_id=$(echo "$raft_peers" | jq -r --arg az "$INSTANCE_AZ" \
            '.data.config.servers[] | select(.node_id | endswith($az)) | .node_id' || true)

        if [ -n "$node_id" ]; then
            log_info "Found Raft node: $node_id"

            # Check if this is the leader
            local is_leader
            is_leader=$(echo "$raft_peers" | jq -r --arg nid "$node_id" \
                '.data.config.servers[] | select(.node_id == $nid) | .leader')

            if [ "$is_leader" == "true" ]; then
                log_warn "This node is the LEADER - leadership will transfer automatically"
            fi

            log_info "Removing node from Raft..."
            if vault operator raft remove-peer "$node_id"; then
                log_info "Node removed from Raft"
            else
                log_warn "Failed to remove from Raft (may already be removed)"
            fi
        else
            log_warn "Node not found in Raft cluster (may already be removed)"
        fi
    else
        log_warn "Could not get Raft peers (cluster may not be initialized)"
    fi
}

# Remove vault-cluster tag so auto_join never discovers this instance
remove_cluster_tag() {
    log_info "Removing vault-cluster tag (prevent auto_join discovery)..."

    aws ec2 delete-tags \
        --region "$AWS_REGION" \
        --resources "$INSTANCE_ID" \
        --tags "Key=vault-cluster" 2>/dev/null || true

    log_info "Cluster tag removed"
}

# Deregister from target group
deregister_from_target_group() {
    log_info "Deregistering from target group..."

    aws elbv2 deregister-targets \
        --region "$AWS_REGION" \
        --target-group-arn "$TARGET_GROUP_ARN" \
        --targets "Id=$INSTANCE_ID" 2>/dev/null || true

    log_info "Deregistered from target group"
}

# Detach EBS volume
detach_ebs_volume() {
    if [ -z "$DATA_VOLUME_ID" ]; then
        log_warn "No data volume to detach"
        return 0
    fi

    log_info "Detaching EBS volume $DATA_VOLUME_ID..."

    aws ec2 detach-volume \
        --region "$AWS_REGION" \
        --volume-id "$DATA_VOLUME_ID" \
        --force \
        --output json | jq '.' || true

    log_info "Waiting for volume to detach..."
    local max_wait=120
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        local state
        state=$(aws ec2 describe-volumes \
            --region "$AWS_REGION" \
            --volume-ids "$DATA_VOLUME_ID" \
            --query 'Volumes[0].State' \
            --output text 2>/dev/null || echo "unknown")

        if [ "$state" == "available" ]; then
            log_info "Volume detached"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_warn "Volume detach timed out - will be detached when instance terminates"
}

# Terminate instance
terminate_instance() {
    log_info "Terminating instance $INSTANCE_ID..."

    aws ec2 terminate-instances \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --output json | jq '.'

    log_info "Instance termination initiated"
}

# Main execution
main() {
    echo "=================================="
    echo "   Terminate Vault Node"
    echo "=================================="
    echo ""

    check_prerequisites
    get_config
    get_instance_details

    if [ "$INSTANCE_STATE" == "terminated" ]; then
        log_error "Instance is already terminated"
        exit 1
    fi

    echo ""
    echo "Summary:"
    echo "  Cluster:   $CLUSTER_NAME"
    echo "  Instance:  $INSTANCE_ID ($INSTANCE_NAME)"
    echo "  AZ:        $INSTANCE_AZ"
    echo "  State:     $INSTANCE_STATE"
    if [ -n "$DATA_VOLUME_ID" ]; then
        echo "  Data Vol:  $DATA_VOLUME_ID (will be preserved)"
    fi
    echo ""

    log_warn "This will:"
    echo "  1. Deregister from target group"
    if [ "$REMOVE_FROM_RAFT" == "true" ]; then
        echo "  2. Remove node from Raft cluster (--remove-from-raft)"
    else
        echo "  2. NOT remove from Raft (replacement will rejoin automatically)"
    fi
    echo "  3. Detach data volume (preserving data)"
    echo "  4. Terminate the EC2 instance"

    if [ "$AUTO_CONFIRM" != "true" ]; then
        echo ""
        read -p "Continue? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Aborted"
            exit 0
        fi
    fi

    echo ""
    remove_from_raft
    deregister_from_target_group
    remove_cluster_tag
    detach_ebs_volume
    terminate_instance

    echo ""
    echo "=================================="
    log_info "Node terminated successfully"
    echo "=================================="
    echo ""
    echo "The EBS volume $DATA_VOLUME_ID has been preserved."
    echo "To launch a replacement node: ./launch-node.sh $VAULT_ENV <az-index>"
    echo ""
    echo "Current Raft peers:"
    if [ -n "${VAULT_TOKEN:-}" ]; then
        vault operator raft list-peers 2>/dev/null || echo "  (unable to list peers)"
    else
        echo "  (set VAULT_TOKEN to view)"
    fi
}

main "$@"
