#!/bin/bash
#
# launch-node.sh - Launch a Vault node in a specific availability zone
#
# This script:
# 1. Gets configuration from SSM Parameter Store and AWS API
# 2. Launches an EC2 instance in the specified AZ with the persistent ENI
# 3. Attaches the persistent EBS volume for that AZ
# 4. Registers the instance with the NLB target group
# 5. Waits for the instance to be healthy
#
# Usage: ./launch-node.sh <env> <az-index> [--yes] [--skip-terraform]
#
# Options:
#   --yes              Skip confirmation prompt (for automation)
#   --skip-terraform   Skip Terraform userdata generation (only if already
#                      generated in this workspace for this environment)
#
# Example:
#   ./launch-node.sh nonprod-test 0              # Launch node in first AZ (interactive)
#   ./launch-node.sh nonprod 1 --yes             # Launch node in second AZ (non-interactive)
#   ./launch-node.sh nonprod 1 --yes --skip-terraform

set -euo pipefail

# Parse arguments
AUTO_CONFIRM=false
SKIP_TERRAFORM=false
ENV=""
AZ_INDEX=""

for arg in "$@"; do
    case $arg in
        --yes|-y)
            AUTO_CONFIRM=true
            ;;
        --skip-terraform)
            SKIP_TERRAFORM=true
            ;;
        -*)
            echo "Unknown option: $arg"
            echo "Usage: $0 <env> <az-index> [--yes] [--skip-terraform]"
            exit 1
            ;;
        *)
            if [ -z "$ENV" ]; then
                ENV="$arg"
            elif [ -z "$AZ_INDEX" ]; then
                AZ_INDEX="$arg"
            fi
            ;;
    esac
done

if [ -z "$ENV" ] || [ -z "$AZ_INDEX" ]; then
    echo "Usage: $0 <env> <az-index> [--yes] [--skip-terraform]"
    echo "Environments: nonprod-test, nonprod, prod"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TOFU_DIR="$PROJECT_DIR/terraform"

# Resolve environment, cluster name, and region
# shellcheck source=scripts/resolve-env.sh
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
}

# Generate the Terraform-rendered userdata file for this environment. Jenkins
# and local runs use clean workspaces, and the generated userdata is gitignored,
# so launch paths generate it on demand when absent.
ensure_userdata() {
    USERDATA_FILE="$TOFU_DIR/modules/vault-nodes/generated/${CLUSTER_NAME}-userdata.sh"

    if [ -f "$USERDATA_FILE" ]; then
        log_info "Using existing userdata: $USERDATA_FILE"
        return 0
    fi

    if [ "$SKIP_TERRAFORM" == "true" ]; then
        log_warn "Skipping Terraform userdata generation (--skip-terraform specified)"
    else
        command -v tofu >/dev/null 2>&1 || { log_error "tofu not found (required to generate userdata)"; exit 1; }
        log_info "Generating Terraform userdata for $VAULT_ENV..."
        "$SCRIPT_DIR/env.sh" "$VAULT_ENV" apply -auto-approve \
            -target=module.vault_nodes.local_file.userdata_template
    fi

    if [ ! -f "$USERDATA_FILE" ]; then
        log_error "Userdata file not found: $USERDATA_FILE"
        log_error "Run './scripts/env.sh $VAULT_ENV apply -auto-approve' or rerun without --skip-terraform."
        exit 1
    fi
}

# Get config from SSM and AWS API
get_config() {
    log_info "Getting cluster config for $CLUSTER_NAME..."

    TARGET_GROUP_ARN=$(cfg_get target_group_arn)
    INSTANCE_TYPE=$(cfg_get instance_type)
    INSTANCE_TAGS_JSON=$(cfg_get instance_tags)

    # Look up latest AL2023 ARM64 AMI (same filter as terraform)
    log_info "Looking up latest AMI..."
    AMI_ID=$(aws ec2 describe-images \
        --region "$AWS_REGION" \
        --owners amazon \
        --filters \
            "Name=name,Values=al2023-ami-*-arm64" \
            "Name=virtualization-type,Values=hvm" \
            "Name=root-device-type,Values=ebs" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)

    # IAM instance profile follows naming convention
    IAM_INSTANCE_PROFILE="${CLUSTER_NAME}-vault-profile"

    # Look up persistent resources by tag
    lookup_ebs_volumes
    lookup_network_interfaces

    if [ "${#NETWORK_INTERFACE_IDS[@]}" -ne "${#EBS_VOLUME_IDS[@]}" ]; then
        log_error "Persistent ENI count does not match EBS volume count"
        log_error "EBS volumes: ${#EBS_VOLUME_IDS[@]}, ENIs: ${#NETWORK_INTERFACE_IDS[@]}"
        log_error "Expected exactly one tagged raft-network ENI per Vault AZ."
        exit 1
    fi

    # Validate AZ index
    if [ "$AZ_INDEX" -ge "${#EBS_VOLUME_IDS[@]}" ]; then
        log_error "Invalid AZ index: $AZ_INDEX (max: $((${#EBS_VOLUME_IDS[@]} - 1)))"
        exit 1
    fi
    if [ "$AZ_INDEX" -ge "${#NETWORK_INTERFACE_IDS[@]}" ]; then
        log_error "Invalid AZ index for persistent ENIs: $AZ_INDEX (max: $((${#NETWORK_INTERFACE_IDS[@]} - 1)))"
        log_error "Run tofu apply, or import/tag the persistent Vault ENIs with vault-role=raft-network."
        exit 1
    fi

    # Get values for this AZ
    EBS_VOLUME_ID="${EBS_VOLUME_IDS[$AZ_INDEX]}"
    AVAILABILITY_ZONE="${EBS_VOLUME_AZS[$AZ_INDEX]}"
    NETWORK_INTERFACE_ID="${NETWORK_INTERFACE_IDS[$AZ_INDEX]}"
    NETWORK_INTERFACE_AZ="${NETWORK_INTERFACE_AZS[$AZ_INDEX]}"
    NETWORK_INTERFACE_PRIVATE_IP="${NETWORK_INTERFACE_PRIVATE_IPS[$AZ_INDEX]}"
    NETWORK_INTERFACE_SUBNET_ID="${NETWORK_INTERFACE_SUBNET_IDS[$AZ_INDEX]}"

    if [ "$NETWORK_INTERFACE_AZ" != "$AVAILABILITY_ZONE" ]; then
        log_error "Persistent ENI AZ mismatch for index $AZ_INDEX"
        log_error "EBS volume AZ: $AVAILABILITY_ZONE"
        log_error "ENI AZ:        $NETWORK_INTERFACE_AZ"
        exit 1
    fi

    # USERDATA_FILE is generated by ensure_userdata.
}

# Compress userdata with gzip — cloud-init decompresses transparently at boot.
# Saves ~2.6x vs plain bash, keeping us well under the AWS 16 KiB cap. The
# plain file stays on disk under generated/ for debugging/inspection; only
# the wire format is compressed.
prepare_userdata() {
    USERDATA_GZ_FILE="$(mktemp -t vault-userdata.XXXXXX.gz)"
    trap 'rm -f "$USERDATA_GZ_FILE"' EXIT
    gzip -9 -c "$USERDATA_FILE" > "$USERDATA_GZ_FILE"

    local raw gz limit=16384
    raw=$(wc -c < "$USERDATA_FILE" | tr -d ' ')
    gz=$(wc -c < "$USERDATA_GZ_FILE" | tr -d ' ')
    log_info "Userdata: ${raw} bytes raw → ${gz} bytes gzipped ($((gz * 100 / limit))% of ${limit} limit)"

    if [ "$gz" -ge "$limit" ]; then
        log_error "Gzipped userdata (${gz} bytes) still exceeds AWS limit (${limit} bytes)"
        log_error "The template has grown too large even compressed. See ADR-010 for next steps."
        exit 1
    fi
}

# Check if there's already a running instance for this AZ
check_existing_instance() {
    log_info "Checking for existing instance in $AVAILABILITY_ZONE..."

    local existing
    existing=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:vault-cluster,Values=$CLUSTER_NAME" \
            "Name=tag:vault-az,Values=$AVAILABILITY_ZONE" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)

    if [ -n "$existing" ]; then
        log_error "Instance already exists for $AVAILABILITY_ZONE: $existing"
        log_error "Terminate the existing instance first with: ./terminate-node.sh $VAULT_ENV $existing"
        exit 1
    fi

    log_info "No existing instance in $AVAILABILITY_ZONE"
}

# Check if EBS volume is available
check_ebs_volume() {
    log_info "Checking EBS volume: $EBS_VOLUME_ID..."

    local state
    state=$(aws ec2 describe-volumes \
        --region "$AWS_REGION" \
        --volume-ids "$EBS_VOLUME_ID" \
        --query 'Volumes[0].State' \
        --output text)

    if [ "$state" != "available" ]; then
        log_error "EBS volume is not available (state: $state)"
        log_error "The volume may be attached to another instance"
        exit 1
    fi

    log_info "EBS volume is available"
}

# Check if persistent ENI is available
check_network_interface() {
    log_info "Checking persistent ENI: $NETWORK_INTERFACE_ID..."

    local eni_info state attached_instance
    eni_info=$(aws ec2 describe-network-interfaces \
        --region "$AWS_REGION" \
        --network-interface-ids "$NETWORK_INTERFACE_ID" \
        --query 'NetworkInterfaces[0]' \
        --output json)

    state=$(echo "$eni_info" | jq -r '.Status')
    attached_instance=$(echo "$eni_info" | jq -r '.Attachment.InstanceId // empty')

    if [ "$state" != "available" ]; then
        log_error "Persistent ENI is not available (state: $state, attached: ${attached_instance:-none})"
        log_error "Terminate the existing instance first, then wait for the ENI to detach."
        exit 1
    fi

    log_info "Persistent ENI is available"
}

# Build tag specifications JSON and write to temp file
# Uses a file to safely handle special characters in tag keys/values
# (colons, #, etc.) without shell interpretation issues
build_tag_spec_file() {
    local tag_spec_file
    tag_spec_file=$(mktemp)

    jq -n \
        --arg name "${CLUSTER_NAME}-node-${AVAILABILITY_ZONE}" \
        --arg cluster "$CLUSTER_NAME" \
        --arg az "$AVAILABILITY_ZONE" \
        --argjson extra "$INSTANCE_TAGS_JSON" \
        '[{
            ResourceType: "instance",
            Tags: (
                [
                    {Key: "Name", Value: $name},
                    {Key: "vault-cluster", Value: $cluster},
                    {Key: "vault-az", Value: $az}
                ] + ($extra | to_entries | map({Key: .key, Value: .value}))
            )
        }]' > "$tag_spec_file"

    echo "$tag_spec_file"
}

# Launch the EC2 instance
launch_instance() {
    log_info "Launching instance in $AVAILABILITY_ZONE..."

    local tag_spec_file
    tag_spec_file=$(build_tag_spec_file)
    trap 'rm -f "$tag_spec_file"' RETURN

    local run_args=(
        aws ec2 run-instances
        --region "$AWS_REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --iam-instance-profile "Name=$IAM_INSTANCE_PROFILE" \
        --user-data "fileb://$USERDATA_GZ_FILE" \
        --metadata-options "HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=1,InstanceMetadataTags=enabled" \
        --tag-specifications "file://$tag_spec_file" \
        --network-interfaces "NetworkInterfaceId=$NETWORK_INTERFACE_ID,DeviceIndex=0"
    )

    INSTANCE_ID=$("${run_args[@]}" \
        --query 'Instances[0].InstanceId' \
        --output text)

    log_info "Instance launched: $INSTANCE_ID"
}

# Wait for instance to be running
wait_for_instance() {
    log_info "Waiting for instance to be running..."

    aws ec2 wait instance-running \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID"

    log_info "Instance is running"
}

# Attach EBS volume
attach_ebs_volume() {
    log_info "Attaching EBS volume $EBS_VOLUME_ID to $INSTANCE_ID..."

    aws ec2 attach-volume \
        --region "$AWS_REGION" \
        --volume-id "$EBS_VOLUME_ID" \
        --instance-id "$INSTANCE_ID" \
        --device "/dev/xvdf" \
        --output json | jq '.'

    log_info "Waiting for volume to attach..."
    aws ec2 wait volume-in-use \
        --region "$AWS_REGION" \
        --volume-ids "$EBS_VOLUME_ID"

    log_info "EBS volume attached"
}

# Register with target group
register_with_target_group() {
    log_info "Registering with target group..."

    aws elbv2 register-targets \
        --region "$AWS_REGION" \
        --target-group-arn "$TARGET_GROUP_ARN" \
        --targets "Id=$INSTANCE_ID"

    log_info "Registered with target group"
}

# Wait for Vault to be running and unsealed on the new node
# NLB health check only marks the active leader as healthy, so standby nodes
# would never pass a target group health check. Instead, check the node directly.
wait_for_healthy() {
    local max_wait=300
    local wait_interval=15
    local elapsed=0

    log_info "Waiting for Vault to be unsealed on $INSTANCE_ID (timeout: ${max_wait}s)..."

    while [ $elapsed -lt $max_wait ]; do
        local params_file
        params_file=$(mktemp)
        jq -n '{"commands":["curl -sk https://127.0.0.1:8200/v1/sys/health?standbyok=true -o /dev/null -w %{http_code} 2>/dev/null || echo 000"]}' > "$params_file"

        local cmd_id
        cmd_id=$(aws ssm send-command \
            --region "$AWS_REGION" \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters "file://$params_file" \
            --query 'Command.CommandId' \
            --output text 2>/dev/null) || true

        rm -f "$params_file"

        if [ -n "$cmd_id" ]; then
            aws ssm wait command-executed \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$INSTANCE_ID" 2>/dev/null || true

            local http_code
            http_code=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardOutputContent' \
                --output text 2>/dev/null | tr -d '[:space:]') || true

            if [ "$http_code" == "200" ]; then
                log_info "Vault is unsealed and running"
                return 0
            fi

            log_info "Vault HTTP status: $http_code (waiting...)"
        else
            log_info "SSM not ready yet (waiting...)"
        fi

        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))
    done

    log_warn "Vault did not become ready within timeout"
    log_warn "Check instance logs: aws ssm start-session --target $INSTANCE_ID"
    return 1
}

# Main execution
main() {
    echo "=================================="
    echo "   Launch Vault Node"
    echo "=================================="
    echo ""

    check_prerequisites
    ensure_userdata
    get_config

    echo ""
    echo "Configuration:"
    echo "  Cluster:      $CLUSTER_NAME"
    echo "  Region:       $AWS_REGION"
    echo "  AZ Index:     $AZ_INDEX"
    echo "  AZ:           $AVAILABILITY_ZONE"
    echo "  ENI:          $NETWORK_INTERFACE_ID"
    echo "  Subnet:       $NETWORK_INTERFACE_SUBNET_ID"
    echo "  Private IP:   $NETWORK_INTERFACE_PRIVATE_IP (ENI-owned)"
    echo "  EBS Volume:   $EBS_VOLUME_ID"
    echo "  AMI:          $AMI_ID"
    echo "  Instance Type: $INSTANCE_TYPE"
    echo ""

    check_existing_instance
    check_ebs_volume
    check_network_interface

    if [ "$AUTO_CONFIRM" != "true" ]; then
        echo ""
        read -r -p "Launch instance? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Aborted"
            exit 0
        fi
    fi

    echo ""
    prepare_userdata
    launch_instance
    wait_for_instance
    attach_ebs_volume
    register_with_target_group

    echo ""
    if wait_for_healthy; then
        echo ""
        echo "=================================="
        log_info "Node launched successfully!"
        echo "=================================="
        echo ""
        echo "Instance ID: $INSTANCE_ID"
        echo "AZ:          $AVAILABILITY_ZONE"
        echo ""
        echo "Check cluster status: ./cluster-status.sh $VAULT_ENV"
        return 0
    else
        echo ""
        log_warn "Node launched but health check timed out"
        echo "Instance ID: $INSTANCE_ID"
        log_warn "Inspect the node: aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION"
        return 1
    fi
}

main "$@"
