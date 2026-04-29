#!/bin/bash
#
# cluster-status.sh - Check Vault cluster health
#
# Usage: ./cluster-status.sh <env>
#
# Gets the Vault address from:
# 1. VAULT_ADDR environment variable (if set)
# 2. SSM Parameter Store

set -euo pipefail

ENV="${1:-}"
if [ -z "$ENV" ]; then
    echo "Usage: $0 <env>"
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

if [ -z "${VAULT_ADDR:-}" ]; then
    VAULT_ADDR=$(ssm_get vault-url)
fi
export VAULT_ADDR

echo "=================================="
echo "Vault Cluster Health Check"
echo "=================================="
echo ""
echo "Environment:   $VAULT_ENV"
echo "Cluster:       $CLUSTER_NAME"
echo "Vault Address: $VAULT_ADDR"
echo ""

# Check basic health endpoint (no auth required)
echo "1. Health Endpoint Check"
echo "------------------------"
health_response=$(curl -sk "$VAULT_ADDR/v1/sys/health" 2>/dev/null || echo '{"error": "unreachable"}')

if echo "$health_response" | jq -e '.error' >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot reach Vault${NC}"
    echo "$health_response" | jq '.'
    exit 1
fi

initialized=$(echo "$health_response" | jq -r '.initialized')
sealed=$(echo "$health_response" | jq -r '.sealed')
standby=$(echo "$health_response" | jq -r '.standby')
cluster_name=$(echo "$health_response" | jq -r '.cluster_name')
version=$(echo "$health_response" | jq -r '.version')

echo "Cluster Name: $cluster_name"
echo "Vault Version: $version"
echo -n "Initialized: "
[ "$initialized" == "true" ] && echo -e "${GREEN}Yes${NC}" || echo -e "${RED}No${NC}"
echo -n "Sealed: "
[ "$sealed" == "false" ] && echo -e "${GREEN}No${NC}" || echo -e "${RED}Yes${NC}"
echo -n "Mode: "
[ "$standby" == "false" ] && echo -e "${GREEN}Active${NC}" || echo -e "${YELLOW}Standby${NC}"

# If we have a token, check Raft status
if [ -n "${VAULT_TOKEN:-}" ]; then
    echo ""
    echo "2. Raft Cluster Status"
    echo "----------------------"

    raft_peers=$(vault operator raft list-peers -format=json 2>/dev/null || echo '{"error": "auth required or not initialized"}')

    if echo "$raft_peers" | jq -e '.error' >/dev/null 2>&1; then
        echo -e "${YELLOW}Cannot get Raft status (token may lack permissions)${NC}"
    else
        peer_count=$(echo "$raft_peers" | jq -r '.data.config.servers | length? // 0')
        echo "Total Peers: $peer_count"
        echo ""
        echo "Peers:"
        echo "$raft_peers" | jq -r '.data.config.servers[]? | "  [\(if .leader then "LEADER" else "FOLLOWER" end)] \(.node_id) - \(.address)"'

        # Check for any non-voter peers
        non_voters=$(echo "$raft_peers" | jq -r '[.data.config.servers[]? | select(.voter == false)] | length')
        if [ "$non_voters" -gt 0 ]; then
            echo -e "${YELLOW}Warning: $non_voters non-voter peer(s) detected${NC}"
        fi
    fi

    echo ""
    echo "3. Seal Status"
    echo "--------------"
    seal_status=$(vault status -format=json 2>/dev/null || echo '{"sealed": "unknown"}')
    seal_type=$(echo "$seal_status" | jq -r '.type // "unknown"')
    echo "Seal Type: $seal_type"

    if [ "$seal_type" == "awskms" ]; then
        echo -e "${GREEN}Auto-unseal enabled (AWS KMS)${NC}"
    fi
else
    echo ""
    echo -e "${YELLOW}Note: Set VAULT_TOKEN for detailed Raft status${NC}"
fi

echo ""
echo "=================================="

# Exit with appropriate code
if [ "$initialized" == "true" ] && [ "$sealed" == "false" ]; then
    echo -e "${GREEN}Cluster is healthy${NC}"
    exit 0
else
    echo -e "${RED}Cluster has issues${NC}"
    exit 1
fi
