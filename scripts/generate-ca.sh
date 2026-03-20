#!/bin/bash
#
# generate-ca.sh - Generate a new self-signed CA for Vault cluster TLS
#
# This script is primarily for reference/manual CA generation.
# OpenTofu automatically generates and stores the CA in Secrets Manager.
# Use this script if you need to manually generate a CA or rotate it.
#
# Usage: ./generate-ca.sh <cluster-name> <aws-region>

set -euo pipefail

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <aws-region>}"
AWS_REGION="${2:?Usage: $0 <cluster-name> <aws-region>}"

OUTPUT_DIR="./ca-output"
mkdir -p "$OUTPUT_DIR"

echo "Generating CA for cluster: $CLUSTER_NAME"

# Generate CA private key
openssl genrsa -out "$OUTPUT_DIR/ca.key" 4096

# Generate self-signed CA certificate (10 years validity)
openssl req -new -x509 \
  -days 3650 \
  -key "$OUTPUT_DIR/ca.key" \
  -out "$OUTPUT_DIR/ca.crt" \
  -subj "/CN=${CLUSTER_NAME} CA/O=Vault Cluster/OU=${CLUSTER_NAME}"

echo "CA files generated:"
echo "  - $OUTPUT_DIR/ca.key (KEEP SECURE!)"
echo "  - $OUTPUT_DIR/ca.crt"

# Display certificate info
echo ""
echo "Certificate details:"
openssl x509 -in "$OUTPUT_DIR/ca.crt" -text -noout | grep -A2 "Subject:"

echo ""
echo "To upload to AWS Secrets Manager:"
echo ""
echo "  aws secretsmanager update-secret \\"
echo "    --region $AWS_REGION \\"
echo "    --secret-id ${CLUSTER_NAME}/tls/ca-cert \\"
echo "    --secret-string file://$OUTPUT_DIR/ca.crt"
echo ""
echo "  aws secretsmanager update-secret \\"
echo "    --region $AWS_REGION \\"
echo "    --secret-id ${CLUSTER_NAME}/tls/ca-key \\"
echo "    --secret-string file://$OUTPUT_DIR/ca.key"
echo ""
echo "WARNING: After updating, you must replace all Vault nodes for the new CA to take effect!"
