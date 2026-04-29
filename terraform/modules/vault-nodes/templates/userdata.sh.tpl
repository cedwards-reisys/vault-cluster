#!/bin/bash
set -euxo pipefail

# Variables from Terraform
CLUSTER_NAME="${cluster_name}"
VAULT_VERSION="${vault_version}"
VAULT_DOMAIN="${vault_domain}"
AWS_REGION="${aws_region}"
KMS_KEY_ID="${kms_key_id}"
CA_CERT_SECRET_ARN="${ca_cert_secret_arn}"
CA_KEY_SECRET_ARN="${ca_key_secret_arn}"

# EBS data volume device
# NOTE: NVMe-backed instance types may present this as /dev/nvme1n1 instead.
# Current m8g instances use /dev/xvdf. Update if changing to NVMe-native types.
DATA_DEVICE="/dev/xvdf"
DATA_MOUNT="/opt/vault/data"

# Logging
exec > >(tee /var/log/vault-setup.log | logger -t vault-setup -s 2>/dev/console) 2>&1

echo "Starting Vault setup..."

# Get instance metadata (IMDSv2)
# Use 1 hour TTL since userdata can take a while to complete
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 3600")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
AZ=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Node ID must be stable per-AZ for persistent volume reuse
# Using AZ-based ID allows instance replacement without Raft membership changes
NODE_ID="$${CLUSTER_NAME}-$${AZ}"

echo "Instance ID: $INSTANCE_ID"
echo "Private IP: $PRIVATE_IP"
echo "Availability Zone: $AZ"
echo "Node ID: $NODE_ID (stable per-AZ)"

# Disable swap (prevent secrets from being written to disk)
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

# Install dependencies
dnf install -y yum-utils shadow-utils jq awscli

# Create vault user and directories before installing Vault RPM
# (RPM creates its own vault user if one doesn't exist — pin UID/GID first)
groupadd --system --gid 8200 vault || true
useradd --system --uid 8200 --gid 8200 --home /opt/vault --shell /bin/false vault || true
mkdir -p /opt/vault/{tls,config}

# Add HashiCorp repository
dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo

# Install Vault
dnf install -y vault-$${VAULT_VERSION}

# Wait for the data EBS volume to be attached
echo "Waiting for data volume at $DATA_DEVICE..."
MAX_WAIT=300
ELAPSED=0
while [ ! -b "$DATA_DEVICE" ] && [ $ELAPSED -lt $MAX_WAIT ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "Waiting for $DATA_DEVICE... ($ELAPSED/$MAX_WAIT seconds)"
done

if [ ! -b "$DATA_DEVICE" ]; then
    echo "ERROR: Data volume $DATA_DEVICE not found after $MAX_WAIT seconds"
    exit 1
fi

echo "Data volume found at $DATA_DEVICE"

# Check if the volume needs formatting (new volume)
if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
    echo "Formatting new data volume..."
    mkfs.xfs "$DATA_DEVICE"
fi

# Create mount point and mount the volume
mkdir -p "$DATA_MOUNT"
mount "$DATA_DEVICE" "$DATA_MOUNT"

# Add to fstab for persistence across reboots
if ! grep -q "$DATA_DEVICE" /etc/fstab; then
    echo "$DATA_DEVICE $DATA_MOUNT xfs defaults,nofail 0 2" >> /etc/fstab
fi

# -----------------------------------------------------------------------------
# EBS identity sentinel — defends against cross-cluster / cross-AZ volume
# misattribution. Writes /opt/vault/data/.vault-node-id on first mount;
# aborts if a later mount finds a mismatching sentinel (e.g., restored
# EBS snapshot from a different cluster, or mis-tagged volume).
# -----------------------------------------------------------------------------
SENTINEL="$DATA_MOUNT/.vault-node-id"
if [ -f "$SENTINEL" ]; then
    EXISTING_ID=$(tr -d '[:space:]' < "$SENTINEL")
    if [ "$EXISTING_ID" != "$NODE_ID" ]; then
        echo "ERROR: EBS volume identity mismatch" >&2
        echo "  expected: $NODE_ID" >&2
        echo "  found:    $EXISTING_ID" >&2
        echo "" >&2
        echo "This volume appears to belong to a different cluster or AZ." >&2
        echo "Refusing to proceed — would cause Raft node-id collision." >&2
        echo "" >&2
        echo "If this is intentional (e.g., DR reassignment of this volume)," >&2
        echo "the operator must BOTH:" >&2
        echo "  1. rm $SENTINEL                # drop identity claim" >&2
        echo "  2. rm -rf $DATA_MOUNT/raft     # drop stale Raft log" >&2
        echo "Without (2), Vault will start with peer/term entries from the" >&2
        echo "wrong cluster and either refuse to join or corrupt replication." >&2
        exit 1
    fi
    echo "Sentinel match: $EXISTING_ID"
else
    echo "Writing new sentinel: $NODE_ID"
    umask 077
    echo "$NODE_ID" > "$SENTINEL"
    chmod 0600 "$SENTINEL"
fi

# Set ownership
chown -R vault:vault /opt/vault

# Retrieve CA certificate and key from Secrets Manager
echo "Retrieving CA certificate and key from Secrets Manager..."

CA_CERT=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$CA_CERT_SECRET_ARN" \
  --query 'SecretString' \
  --output text)

if [ -z "$CA_CERT" ] || [ "$CA_CERT" = "None" ]; then
  echo "ERROR: Failed to retrieve CA certificate from Secrets Manager"
  exit 1
fi
echo "$CA_CERT" > /opt/vault/tls/ca.crt

CA_KEY=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$CA_KEY_SECRET_ARN" \
  --query 'SecretString' \
  --output text)

if [ -z "$CA_KEY" ] || [ "$CA_KEY" = "None" ]; then
  echo "ERROR: Failed to retrieve CA key from Secrets Manager"
  exit 1
fi
echo "$CA_KEY" > /opt/vault/tls/ca.key
unset CA_KEY  # Clear from memory

# Generate node-specific certificate signed by CA
echo "Generating node certificate..."
cat > /tmp/node-csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = $${PRIVATE_IP}
O = Vault Cluster
OU = $${CLUSTER_NAME}

[req_ext]
subjectAltName = @alt_names

[alt_names]
IP.1 = $${PRIVATE_IP}
IP.2 = 127.0.0.1
DNS.1 = localhost
DNS.2 = $${VAULT_DOMAIN}

[v3_ext]
authorityKeyIdentifier=keyid,issuer:always
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=@alt_names
EOF

# Generate node private key
openssl genrsa -out /opt/vault/tls/node.key 2048

# Generate CSR
openssl req -new \
  -key /opt/vault/tls/node.key \
  -out /tmp/node.csr \
  -config /tmp/node-csr.conf

# Sign the certificate with CA
openssl x509 -req \
  -in /tmp/node.csr \
  -CA /opt/vault/tls/ca.crt \
  -CAkey /opt/vault/tls/ca.key \
  -CAcreateserial \
  -out /opt/vault/tls/node.crt \
  -days 365 \
  -extensions v3_ext \
  -extfile /tmp/node-csr.conf

# Securely remove sensitive files (security best practice)
secure_delete() {
  local file="$1"
  if [ -f "$file" ]; then
    if command -v shred &> /dev/null; then
      shred -u "$file"
    else
      rm -f "$file"
    fi
  fi
}

# Remove CA private key (should never persist on disk)
secure_delete /opt/vault/tls/ca.key

# Clean up temporary files (CSR contains private IP, config contains internal details)
secure_delete /tmp/node-csr.conf
secure_delete /tmp/node.csr
rm -f /opt/vault/tls/ca.srl

# Set permissions
chown -R vault:vault /opt/vault/tls
chmod 600 /opt/vault/tls/node.key
chmod 644 /opt/vault/tls/node.crt /opt/vault/tls/ca.crt

# Create Vault configuration
echo "Creating Vault configuration..."
cat > /opt/vault/config/vault.hcl <<EOF
ui = true
disable_mlock = true
cluster_name = "$${CLUSTER_NAME}"
log_level = "warn"

# API/UI listener - HTTPS with self-signed cert
listener "tcp" {
  address                            = "0.0.0.0:8200"
  tls_cert_file                      = "/opt/vault/tls/node.crt"
  tls_key_file                       = "/opt/vault/tls/node.key"
  tls_client_ca_file                 = "/opt/vault/tls/ca.crt"
  unauthenticated_metrics_access     = true
}

# Raft storage with auto-join
storage "raft" {
  path            = "/opt/vault/data"
  node_id         = "$${NODE_ID}"
  max_entry_size  = 10485760

  retry_join {
    auto_join               = "provider=aws region=$${AWS_REGION} tag_key=vault-cluster tag_value=$${CLUSTER_NAME}"
    auto_join_scheme        = "https"
    leader_ca_cert_file     = "/opt/vault/tls/ca.crt"
    leader_client_cert_file = "/opt/vault/tls/node.crt"
    leader_client_key_file  = "/opt/vault/tls/node.key"
  }
}

# AWS KMS auto-unseal
seal "awskms" {
  region     = "$${AWS_REGION}"
  kms_key_id = "$${KMS_KEY_ID}"
}

# API address (node's own private IP for direct node-to-node forwarding)
api_addr      = "https://$${VAULT_DOMAIN}"
cluster_addr  = "https://$${PRIVATE_IP}:8201"

# Telemetry — exposes /v1/sys/metrics?format=prometheus
telemetry {
  disable_hostname           = true
  prometheus_retention_time  = "6h"
}
EOF

chown vault:vault /opt/vault/config/vault.hcl
chmod 640 /opt/vault/config/vault.hcl

# Create systemd service override for custom config path
mkdir -p /etc/systemd/system/vault.service.d
cat > /etc/systemd/system/vault.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/vault server -config=/opt/vault/config/vault.hcl
EOF

# Enable and start Vault
systemctl daemon-reload
systemctl enable vault
systemctl start vault

# Wait for Vault to be ready
echo "Waiting for Vault to start..."
sleep 10

# Check Vault status (may show sealed initially until initialized)
vault status -address=https://127.0.0.1:8200 -ca-cert=/opt/vault/tls/ca.crt || true

%{ if backup_enabled ~}
# ============================================================
# Backup automation - systemd timer for Raft snapshots
# ============================================================
echo "Setting up backup automation..."

mkdir -p /opt/vault/scripts
touch /opt/vault/scripts/backup-snapshot.sh
chmod 755 /opt/vault/scripts/backup-snapshot.sh
chown vault:vault /opt/vault/scripts/backup-snapshot.sh

# Install backup script
cat > /opt/vault/scripts/backup-snapshot.sh <<'BACKUP_EOF'
#!/bin/bash
set -euo pipefail

VAULT_ADDR="https://127.0.0.1:8200"
VAULT_CACERT="/opt/vault/tls/ca.crt"
BACKUP_S3_BUCKET="${backup_s3_bucket}"
CLUSTER_NAME="${cluster_name}"

export VAULT_ADDR VAULT_CACERT

log() { logger -t vault-backup "$1"; echo "$1"; }

# Check if this node is the active leader
HEALTH=$(curl -sk "$VAULT_ADDR/v1/sys/health" 2>/dev/null || echo '{}')
INITIALIZED=$(echo "$HEALTH" | jq -r '.initialized')
SEALED=$(echo "$HEALTH" | jq -r '.sealed')
STANDBY=$(echo "$HEALTH" | jq -r '.standby')

if [ "$INITIALIZED" != "true" ] || [ "$SEALED" != "false" ]; then
    log "Node is not initialized or is sealed. Skipping backup."
    exit 0
fi

if [ "$STANDBY" != "false" ]; then
    log "Node is a standby. Only the leader performs backups. Skipping."
    exit 0
fi

log "This node is the active leader. Proceeding with backup."

# Authenticate via AWS IAM auth method
log "Authenticating via AWS IAM auth..."
VAULT_TOKEN=$(vault login -method=aws role=backup -token-only 2>/dev/null) || {
    log "ERROR: Failed to authenticate via AWS IAM auth."
    exit 1
}
export VAULT_TOKEN

# Take the snapshot
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
SNAP_FILE="/tmp/vault-snapshot-$${TIMESTAMP}.snap"

log "Taking Raft snapshot..."
vault operator raft snapshot save "$SNAP_FILE"

SNAP_SIZE=$(stat -c%s "$SNAP_FILE" 2>/dev/null || echo "unknown")
log "Snapshot saved: $SNAP_FILE ($${SNAP_SIZE} bytes)"

# Upload to S3 - daily prefix
DAILY_KEY="$${CLUSTER_NAME}/daily/vault-snapshot-$${TIMESTAMP}.snap"
log "Uploading to s3://$${BACKUP_S3_BUCKET}/$${DAILY_KEY}..."
aws s3 cp "$SNAP_FILE" "s3://$${BACKUP_S3_BUCKET}/$${DAILY_KEY}" --quiet

# If Sunday, also upload to weekly prefix
DAY_OF_WEEK=$(date -u +"%u")
if [ "$DAY_OF_WEEK" = "7" ]; then
    WEEKLY_KEY="$${CLUSTER_NAME}/weekly/vault-snapshot-$${TIMESTAMP}.snap"
    log "Sunday - also uploading to weekly: s3://$${BACKUP_S3_BUCKET}/$${WEEKLY_KEY}"
    aws s3 cp "$SNAP_FILE" "s3://$${BACKUP_S3_BUCKET}/$${WEEKLY_KEY}" --quiet
fi

# Clean up
rm -f "$SNAP_FILE"
vault token revoke -self 2>/dev/null || true

log "Backup completed successfully."
BACKUP_EOF

# Create systemd service for backup
cat > /etc/systemd/system/vault-backup.service <<'SVCEOF'
[Unit]
Description=Vault Raft Snapshot Backup
After=vault.service
Requires=vault.service

[Service]
Type=oneshot
User=vault
ExecStart=/opt/vault/scripts/backup-snapshot.sh
SVCEOF

# Create systemd timer for backup (every 6 hours with random delay)
cat > /etc/systemd/system/vault-backup.timer <<'TMREOF'
[Unit]
Description=Vault Raft Snapshot Backup Timer

[Timer]
OnCalendar=*-*-* 00/6:00:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
TMREOF

# Enable and start the timer
systemctl daemon-reload
systemctl enable vault-backup.timer
systemctl start vault-backup.timer

echo "Backup timer enabled (every 6 hours)."
%{ endif ~}

echo "Vault setup complete!"
