#!/bin/bash
#
# resolve-env.sh — shared helper sourced by operational scripts
#
# Sets: VAULT_ENV, CLUSTER_NAME, AWS_REGION
# Provides: ssm_get, cfg_get, lookup_ebs_volumes, lookup_network_interfaces
#
# Usage (from calling script):
#   source "$(dirname "${BASH_SOURCE[0]}")/resolve-env.sh" "$env"

_env="${1:-}"
if [ -z "$_env" ]; then
    echo "ERROR: Environment is required." >&2
    echo "Valid environments: nonprod-test, nonprod, prod" >&2
    exit 1
fi

case "$_env" in
    nonprod-test|nonprod|prod) ;;
    *)
        echo "ERROR: Invalid environment: $_env" >&2
        echo "Valid environments: nonprod-test, nonprod, prod" >&2
        exit 1
        ;;
esac

VAULT_ENV="$_env"
CLUSTER_NAME="vault-${VAULT_ENV}"

# Resolve AWS region
if [ -n "${AWS_REGION:-}" ]; then
    : # already set
elif [ -n "${AWS_DEFAULT_REGION:-}" ]; then
    AWS_REGION="$AWS_DEFAULT_REGION"
else
    AWS_REGION=$(aws configure get region 2>/dev/null || true)
    if [ -z "$AWS_REGION" ]; then
        echo "ERROR: Cannot determine AWS region. Set AWS_REGION." >&2
        exit 1
    fi
fi
export AWS_REGION

# Fetch a single SSM parameter by short name (e.g. "vault-url")
ssm_get() {
    aws ssm get-parameter \
        --region "$AWS_REGION" \
        --name "/${CLUSTER_NAME}/config/${1}" \
        --query 'Parameter.Value' \
        --output text
}

# Cached vault-config JSON (fetched on first cfg_get call)
_VAULT_CONFIG_JSON=""

# Extract a field from the consolidated vault-config SSM parameter.
# Returns raw jq output: strings unquoted, arrays/objects as JSON.
cfg_get() {
    if [ -z "$_VAULT_CONFIG_JSON" ]; then
        _VAULT_CONFIG_JSON=$(ssm_get vault-config)
    fi
    echo "$_VAULT_CONFIG_JSON" | jq -r ".${1}"
}

# Look up EBS volumes by cluster tag
# Sets: EBS_VOLUME_IDS array, EBS_VOLUME_AZS array (sorted by AZ)
lookup_ebs_volumes() {
    local volumes_json
    volumes_json=$(aws ec2 describe-volumes \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:vault-cluster,Values=$CLUSTER_NAME" \
            "Name=tag:vault-role,Values=raft-data" \
        --query 'Volumes[*].[VolumeId,AvailabilityZone]' \
        --output json)

    EBS_VOLUME_IDS=()
    EBS_VOLUME_AZS=()
    while IFS=$'\t' read -r vol_id az; do
        EBS_VOLUME_IDS+=("$vol_id")
        EBS_VOLUME_AZS+=("$az")
    done < <(echo "$volumes_json" | jq -r 'sort_by(.[1]) | .[] | "\(.[0])\t\(.[1])"')
}

# Look up persistent Vault ENIs by cluster tag.
# Sets: NETWORK_INTERFACE_IDS, NETWORK_INTERFACE_AZS,
# NETWORK_INTERFACE_PRIVATE_IPS, NETWORK_INTERFACE_SUBNET_IDS arrays
# (sorted by AZ)
lookup_network_interfaces() {
    local enis_json
    enis_json=$(aws ec2 describe-network-interfaces \
        --region "$AWS_REGION" \
        --filters \
            "Name=tag:vault-cluster,Values=$CLUSTER_NAME" \
            "Name=tag:vault-role,Values=raft-network" \
        --query 'NetworkInterfaces[*].[NetworkInterfaceId,AvailabilityZone,PrivateIpAddress,SubnetId]' \
        --output json)

    NETWORK_INTERFACE_IDS=()
    NETWORK_INTERFACE_AZS=()
    NETWORK_INTERFACE_PRIVATE_IPS=()
    NETWORK_INTERFACE_SUBNET_IDS=()
    while IFS=$'\t' read -r eni_id az private_ip subnet_id; do
        NETWORK_INTERFACE_IDS+=("$eni_id")
        NETWORK_INTERFACE_AZS+=("$az")
        NETWORK_INTERFACE_PRIVATE_IPS+=("$private_ip")
        NETWORK_INTERFACE_SUBNET_IDS+=("$subnet_id")
    done < <(echo "$enis_json" | jq -r 'sort_by(.[1]) | .[] | "\(.[0])\t\(.[1])\t\(.[2])\t\(.[3])"')
}
