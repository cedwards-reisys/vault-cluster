#!/bin/bash
#
# docker-run.sh - Run vault-ops container with proper mounts
#
# Usage:
#   ./scripts/docker-run.sh              # Interactive shell
#   ./scripts/docker-run.sh <command>    # Run specific command
#
# Examples:
#   ./scripts/docker-run.sh
#   ./scripts/docker-run.sh ./scripts/cluster-status.sh
#   ./scripts/docker-run.sh tofu plan

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME="vault-cluster-ops:latest"

# Build if image doesn't exist
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "Building Docker image..."
    docker build -t "$IMAGE_NAME" "$PROJECT_DIR"
fi

# Prepare mount arguments
MOUNTS=(
    -v "$PROJECT_DIR:/workspace:rw"
)

# Mount AWS credentials if available
if [ -d "$HOME/.aws" ]; then
    MOUNTS+=(-v "$HOME/.aws:/home/operator/.aws:ro")
fi

# Prepare environment variables
ENV_VARS=(
    -e "AWS_REGION=${AWS_REGION:-}"
    -e "AWS_PROFILE=${AWS_PROFILE:-}"
    -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}"
    -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}"
    -e "AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN:-}"
    -e "VAULT_ADDR=${VAULT_ADDR:-}"
    -e "VAULT_TOKEN=${VAULT_TOKEN:-}"
    -e "VAULT_SKIP_VERIFY=${VAULT_SKIP_VERIFY:-false}"
)

# Run container
if [ $# -eq 0 ]; then
    # Interactive shell
    exec docker run --rm -it \
        "${MOUNTS[@]}" \
        "${ENV_VARS[@]}" \
        -w /workspace \
        "$IMAGE_NAME" \
        /bin/bash
else
    # Run command
    exec docker run --rm -it \
        "${MOUNTS[@]}" \
        "${ENV_VARS[@]}" \
        -w /workspace \
        "$IMAGE_NAME" \
        "$@"
fi
