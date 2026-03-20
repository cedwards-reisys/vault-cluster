#!/bin/bash
#
# env.sh - Environment wrapper for tofu commands
#
# Wraps tofu commands with the correct backend-config and var-file
# for a given environment.
#
# Usage: ./scripts/env.sh <environment> <tofu-command...>
#
# Examples:
#   ./scripts/env.sh nonprod-test plan
#   ./scripts/env.sh nonprod apply
#   ./scripts/env.sh prod plan -target=module.backup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <environment> <tofu-command...>"
    echo ""
    echo "Environments: nonprod-test, nonprod, prod"
    echo ""
    echo "Examples:"
    echo "  $0 nonprod-test plan"
    echo "  $0 nonprod apply"
    echo "  $0 prod plan -target=module.backup"
    exit 1
fi

ENV="$1"
shift
TOFU_CMD="$1"
shift

# Validate environment
BACKEND_CONFIG="$TERRAFORM_DIR/backend-configs/$ENV.hcl"
VAR_FILE="$TERRAFORM_DIR/environments/$ENV.tfvars"

if [ ! -f "$BACKEND_CONFIG" ]; then
    echo "ERROR: Backend config not found: $BACKEND_CONFIG"
    exit 1
fi

if [ ! -f "$VAR_FILE" ]; then
    echo "ERROR: Var file not found: $VAR_FILE"
    exit 1
fi

cd "$TERRAFORM_DIR"

echo "Environment: $ENV"
echo "Backend:     $BACKEND_CONFIG"
echo "Vars:        $VAR_FILE"
echo "Command:     tofu $TOFU_CMD $*"
echo ""

# Initialize with the correct backend
tofu init -reconfigure -backend-config="$BACKEND_CONFIG"

# Commands that accept -var-file
case "$TOFU_CMD" in
    plan|apply|destroy|refresh|import)
        tofu "$TOFU_CMD" -var-file="$VAR_FILE" "$@"
        ;;
    output|state|show|console)
        tofu "$TOFU_CMD" "$@"
        ;;
    *)
        tofu "$TOFU_CMD" "$@"
        ;;
esac
