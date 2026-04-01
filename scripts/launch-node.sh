#!/bin/bash
#
# launch-node.sh - Launch a Vault node in a specific availability zone
#
# This script:
# 1. Gets configuration from SSM Parameter Store and AWS API
# 2. Launches an EC2 instance in the specified AZ
# 3. Attaches the persistent EBS volume for that AZ
# 4. Registers the instance with the NLB target group
# 5. Waits for the instance to be healthy
#
# Usage: ./launch-node.sh <env> <az-index> [--yes]
#
# Options:
#   --yes    Skip confirmation prompt (for automation)
#
# Example:
#   ./launch-node.sh nonprod-test 0        # Launch node in first AZ (interactive)
#   ./launch-node.sh nonprod 1 --yes       # Launch node in second AZ (non-interactive)

set -euo pipefail

# Parse arguments
AUTO_CONFIRM=false
ENV=""
AZ_INDEX=""

for arg in "$@"; do
    case $arg in
        --yes|-y)
            AUTO_CONFIRM=true
            ;;
        -*)
            echo "Unknown option: $arg"
            echo "Usage: $0 <env> <az-index> [--yes]"
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
    echo "Usage: $0 <env> <az-index> [--yes]"
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

# Get config from SSM and AWS API
get_config() {
    log_info "Getting cluster config for $CLUSTER_NAME..."

    TARGET_GROUP_ARN=$(cfg_get target_group_arn)
    INSTANCE_TYPE=$(cfg_get instance_type)
    INSTANCE_TAGS_JSON=$(cfg_get instance_tags)

    # Subnets (JSON array in vault-config)
    SUBNET_IDS=($(cfg_get private_subnet_ids | jq -r '.[]'))

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

    # Look up security group by name convention
    SECURITY_GROUP_IDS=($(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=${CLUSTER_NAME}-vault-sg" \
        --query 'SecurityGroups[].GroupId' \
        --output text))

    # Merge additional security group IDs from config (if any)
    ADDITIONAL_SGS=$(cfg_get additional_security_group_ids | jq -r '.[]' 2>/dev/null)
    if [ -n "$ADDITIONAL_SGS" ]; then
        while read -r sg; do
            SECURITY_GROUP_IDS+=("$sg")
        done <<< "$ADDITIONAL_SGS"
    fi

    # IAM instance profile follows naming convention
    IAM_INSTANCE_PROFILE="${CLUSTER_NAME}-vault-profile"

    # Look up EBS volumes by tag
    lookup_ebs_volumes

    # Validate AZ index
    if [ "$AZ_INDEX" -ge "${#EBS_VOLUME_IDS[@]}" ]; then
        log_error "Invalid AZ index: $AZ_INDEX (max: $((${#EBS_VOLUME_IDS[@]} - 1)))"
        exit 1
    fi

    # Get values for this AZ
    EBS_VOLUME_ID="${EBS_VOLUME_IDS[$AZ_INDEX]}"
    AVAILABILITY_ZONE="${EBS_VOLUME_AZS[$AZ_INDEX]}"
    SUBNET_ID="${SUBNET_IDS[$AZ_INDEX]}"

    # Read userdata from generated file
    USERDATA_FILE="$TOFU_DIR/modules/vault-nodes/generated/userdata.sh"
    if [ ! -f "$USERDATA_FILE" ]; then
        log_error "Userdata file not found. Run 'tofu apply' first."
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

# Build tag specifications JSON and write to temp file
# Uses a file to safely handle special characters in tag keys/values
# (colons, #, etc.) without shell interpretation issues
build_tag_spec_file() {
    local tag_spec_file
    tag_spec_file=$(mktemp)

    jq -n \
        --arg name "${CLUSTER_NAME}-vault-${AVAILABILITY_ZONE}" \
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
    trap "rm -f '$tag_spec_file'" RETURN

    INSTANCE_ID=$(aws ec2 run-instances \
        --region "$AWS_REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "${SECURITY_GROUP_IDS[@]}" \
        --iam-instance-profile "Name=$IAM_INSTANCE_PROFILE" \
        --user-data "file://$USERDATA_FILE" \
        --metadata-options "HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=1,InstanceMetadataTags=enabled" \
        --tag-specifications "file://$tag_spec_file" \
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

# Wait for target to be healthy
wait_for_healthy() {
    local max_wait=300
    local wait_interval=15
    local elapsed=0

    log_info "Waiting for instance to be healthy in target group (timeout: ${max_wait}s)..."

    while [ $elapsed -lt $max_wait ]; do
        local health
        health=$(aws elbv2 describe-target-health \
            --region "$AWS_REGION" \
            --target-group-arn "$TARGET_GROUP_ARN" \
            --targets "Id=$INSTANCE_ID" \
            --query 'TargetHealthDescriptions[0].TargetHealth.State' \
            --output text 2>/dev/null || echo "unknown")

        if [ "$health" == "healthy" ]; then
            log_info "Instance is healthy!"
            return 0
        fi

        log_info "Health status: $health (waiting...)"
        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))
    done

    log_warn "Instance did not become healthy within timeout"
    log_warn "Check instance logs: aws ec2 get-console-output --instance-id $INSTANCE_ID"
    return 1
}

# Main execution
main() {
    echo "=================================="
    echo "   Launch Vault Node"
    echo "=================================="
    echo ""

    check_prerequisites
    get_config

    echo ""
    echo "Configuration:"
    echo "  Cluster:      $CLUSTER_NAME"
    echo "  Region:       $AWS_REGION"
    echo "  AZ Index:     $AZ_INDEX"
    echo "  AZ:           $AVAILABILITY_ZONE"
    echo "  Subnet:       $SUBNET_ID"
    echo "  EBS Volume:   $EBS_VOLUME_ID"
    echo "  AMI:          $AMI_ID"
    echo "  Instance Type: $INSTANCE_TYPE"
    echo ""

    check_existing_instance
    check_ebs_volume

    if [ "$AUTO_CONFIRM" != "true" ]; then
        echo ""
        read -p "Launch instance? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Aborted"
            exit 0
        fi
    fi

    echo ""
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
    else
        echo ""
        log_warn "Node launched but health check timed out"
        echo "Instance ID: $INSTANCE_ID"
    fi
}

main "$@"
