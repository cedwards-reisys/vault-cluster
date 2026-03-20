# HashiCorp Vault HA Cluster on AWS

A production-ready 3-node HashiCorp Vault cluster deployed on AWS using OpenTofu.

## Architecture

```
                         ┌─────────────────────────────────────┐
                         │         vault.example.com           │
                         │            (Route 53)               │
                         └─────────────────┬───────────────────┘
                                           │
                         ┌─────────────────▼───────────────────┐
                         │  Network Load Balancer (internal)   │
                         │    - TLS termination (ACM cert)     │
                         │    - Port 443 → TCP 8200            │
                         │    - Preserves client IP            │
                         └─────────────────┬───────────────────┘
                                           │
          ┌────────────────────────────────┼────────────────────────────┐
          │                                │                            │
          ▼                                ▼                            ▼
┌──────────────────┐            ┌──────────────────┐          ┌──────────────────┐
│   Vault Node 1   │◄──────────►│   Vault Node 2   │◄────────►│   Vault Node 3   │
│   (AZ-a)         │    Raft    │   (AZ-b)         │   Raft   │   (AZ-c)         │
│                  │    8201    │                  │   8201   │                  │
│   ┌──────────┐   │            │   ┌──────────┐   │          │   ┌──────────┐   │
│   │ EBS Vol  │   │            │   │ EBS Vol  │   │          │   │ EBS Vol  │   │
│   │ (Raft)   │   │            │   │ (Raft)   │   │          │   │ (Raft)   │   │
│   └──────────┘   │            │   └──────────┘   │          │   └──────────┘   │
└──────────────────┘            └──────────────────┘          └──────────────────┘
          │                                │                            │
          └────────────────────────────────┼────────────────────────────┘
                                           │
                         ┌─────────────────▼───────────────────┐
                         │           AWS KMS Key               │
                         │         (Auto-unseal)               │
                         └─────────────────────────────────────┘
```

## Features

- **High Availability**: 3-node Raft cluster across 3 Availability Zones
- **Auto-unseal**: AWS KMS for automatic unsealing on node restart
- **Auto-join**: New nodes automatically discover and join the cluster via AWS tags
- **Persistent Storage**: 200GB dedicated EBS volumes per AZ survive instance replacement
- **Stable Node Identity**: Node IDs are AZ-based, enabling seamless instance replacement
- **Internal NLB**: Network Load Balancer in private subnets with TLS termination (ACM cert)
- **TLS Everywhere**:
  - Client → NLB: TLS with ACM certificate (port 443)
  - NLB → Nodes: TLS with self-signed certs (port 8200)
  - Node → Node: Mutual TLS with self-signed CA (port 8201)
- **Client IP Preservation**: NLB preserves source IP for audit logs
- **Multi-Environment**: Separate state and configuration for nonprod-test, nonprod, and prod
- **Automated Backups**: Leader-only Raft snapshots to S3 every 6 hours via systemd timer
- **CloudWatch Monitoring**: Alarms for NLB health and EBS performance
- **Credential Management**: Root tokens and recovery keys stored in AWS Secrets Manager
- **SSM Session Manager**: Secure node access with S3 and CloudWatch logging
- **Script-Based Operations**: Node lifecycle managed by scripts (not Terraform) for safe rolling updates
- **ARM64/Graviton**: Cost-effective ARM-based instances

## Prerequisites

- AWS Account with appropriate permissions
- OpenTofu >= 1.6.0
- Existing VPC with 3 private subnets (one per AZ) for Vault nodes and internal NLB
- ACM certificate for your Vault domain
- AWS CLI configured

## Quick Start

### 1. Clone and Configure

```bash
cd vault-cluster
```

Edit the environment file for your target environment:

```bash
# Edit terraform/environments/nonprod-test.tfvars (or nonprod.tfvars, prod.tfvars)
# Set: vpc_id, subnet IDs, ACM cert ARN, etc.

# Edit terraform/backend-configs/nonprod-test.hcl (or nonprod.hcl, prod.hcl)
# Set: S3 bucket name for Terraform state
```

### 2. Deploy Infrastructure

```bash
# Use the environment wrapper
./scripts/env.sh nonprod-test plan
./scripts/env.sh nonprod-test apply
```

This creates:
- KMS key for auto-unseal
- IAM roles and policies
- Security groups
- Network Load Balancer
- Persistent EBS volumes (one per AZ)
- Generated userdata script

**Note**: This does NOT create EC2 instances. Nodes are managed by scripts.

### 3. Configure DNS

Point your domain to the NLB:

```bash
aws ssm get-parameter --name /<cluster-name>/config/vault-config \
  --query Parameter.Value --output text | jq -r .nlb_dns_name
```

Create a CNAME record or Route53 alias.

### 4. Launch Vault Nodes

```bash
# Launch first node
VAULT_ENV=nonprod-test ./scripts/launch-node.sh 0

# Wait for it to be healthy, then initialize Vault
export VAULT_ADDR="https://vault.nonprod-test.example.io"
vault operator init -recovery-shares=5 -recovery-threshold=3

# Store credentials in Secrets Manager
./scripts/store-vault-credentials.sh nonprod-test

# Launch remaining nodes
VAULT_ENV=nonprod-test ./scripts/launch-node.sh 1
VAULT_ENV=nonprod-test ./scripts/launch-node.sh 2
```

### 5. Verify Cluster

```bash
# Check health
export VAULT_TOKEN="<root-token>"
./scripts/cluster-status.sh

# Check Raft peers
vault operator raft list-peers
```

### Migrating from Existing Cluster

If you have an existing Vault cluster and want to migrate to this infrastructure:

```bash
# 1. Backup existing cluster
export VAULT_ADDR="https://old-vault.example.com"
vault operator raft snapshot save backup.snap

# 2. Deploy new infrastructure (steps 1-3 above)
# 3. Initialize new cluster and restore snapshot
vault operator raft snapshot restore -force backup.snap

# 4. Launch remaining nodes and update DNS
```

See [docs/operations.md](docs/operations.md) for the full operations guide including multi-environment management, backup/restore, data sync, and migration procedures. For migrating from an existing cluster (including version upgrades from 1.9.x), see [docs/migration.md](docs/migration.md).

## Module Structure

```
vault-cluster/
├── terraform/                   # Terraform code
│   ├── main.tf                  # Root module
│   ├── variables.tf             # Input variables
│   ├── outputs.tf               # Outputs
│   ├── versions.tf              # Provider versions
│   ├── terraform.tfvars.example # Example configuration
│   ├── environments/            # Per-environment variable files
│   │   ├── nonprod-test.tfvars
│   │   ├── nonprod.tfvars
│   │   └── prod.tfvars
│   ├── backend-configs/         # Per-environment S3 backend configs
│   │   ├── nonprod-test.hcl
│   │   ├── nonprod.hcl
│   │   └── prod.hcl
│   └── modules/
│       ├── kms/                 # KMS key + CA cert + Secrets Manager secrets
│       ├── iam/                 # IAM roles and policies
│       ├── security-groups/     # Security groups
│       ├── nlb/                 # Network Load Balancer
│       ├── backup/              # S3 backup bucket + lifecycle + IAM
│       ├── monitoring/          # CloudWatch alarms (NLB, EBS)
│       └── vault-nodes/         # Persistent EBS volumes + userdata generation
│           ├── templates/
│           │   └── userdata.sh.tpl  # Node bootstrap script (includes backup timer)
│           └── generated/
│               └── userdata.sh  # Generated userdata (gitignored)
├── scripts/
│   ├── env.sh                   # Environment wrapper for tofu commands
│   ├── launch-node.sh           # Launch a node in specific AZ
│   ├── terminate-node.sh        # Gracefully terminate a node
│   ├── rolling-update.sh        # Rolling update all nodes
│   ├── cluster-status.sh        # Health check script
│   ├── backup-snapshot.sh       # On-node automated backup (reference copy)
│   ├── restore-snapshot.sh      # Restore from S3 backup
│   ├── sync-to-nonprod-test.sh  # Copy nonprod data to nonprod-test
│   ├── store-vault-credentials.sh # Store root token/keys in Secrets Manager
│   ├── rekey-recovery.sh        # Regenerate lost recovery keys
│   └── generate-ca.sh           # Manual CA generation (reference)
├── jenkins/
│   ├── seed-job.groovy          # Job DSL seed job (creates all pipelines)
│   └── pipelines/               # Jenkinsfile for each job
│       ├── plan.Jenkinsfile
│       ├── apply.Jenkinsfile
│       ├── launch-node.Jenkinsfile
│       ├── terminate-node.Jenkinsfile
│       ├── rolling-update.Jenkinsfile
│       ├── cluster-status.Jenkinsfile
│       ├── backup-restore.Jenkinsfile
│       ├── setup-backup-auth.Jenkinsfile
│       ├── sync-to-nonprod-test.Jenkinsfile
│       ├── store-credentials.Jenkinsfile
│       ├── migrate.Jenkinsfile
│       └── rekey-recovery.Jenkinsfile
└── docs/
    ├── operations.md            # Full operations guide
    ├── jenkins.md               # Jenkins pipeline setup guide
    ├── migration.md             # Migrating from existing cluster
    └── rolling-updates.md       # Update runbook
```

## Configuration Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region | - |
| `vpc_id` | Existing VPC ID | - |
| `private_subnet_ids` | 3 private subnet IDs (one per AZ) | - |
| `acm_certificate_arn` | ACM certificate ARN | - |
| `cluster_name` | Cluster name (used in resource names) | - |
| `vault_domain` | Domain for Vault access | - |
| `vault_version` | Vault version to install | `1.21.4` |
| `instance_type` | EC2 instance type | `m8g.medium` |
| `environment` | Environment name | `nonprod` |
| `allowed_cidr_blocks` | CIDRs allowed to access Vault | `["0.0.0.0/0"]` |
| `backup_enabled` | Enable backup infrastructure + automation | `false` |
| `backup_s3_bucket` | S3 bucket name for backups | `""` |
| `backup_retention_days` | Days to retain daily backups | `90` |
| `ssm_logs_s3_bucket` | S3 bucket for SSM Session Manager logs | - |
| `ssm_logs_log_group` | CloudWatch log group for SSM logs | - |
| `instance_tags` | Additional tags for EC2 instances | `{}` |
| `tags` | Tags applied to all Terraform-managed resources | `{}` |

## Operations

### Health Checks

```bash
# Quick health check (no auth required)
curl -sk https://vault.example.com/v1/sys/health | jq

# Detailed health check
./scripts/cluster-status.sh

# Check Raft cluster status (requires auth)
vault operator raft list-peers
```

### Node Replacement

Replace a specific node (e.g., for troubleshooting):

```bash
# List current instances
aws ec2 describe-instances \
  --filters "Name=tag:vault-cluster,Values=<cluster-name>" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`vault-az`].Value|[0]]' \
  --output table

# Terminate the node (data preserved on EBS)
./scripts/terminate-node.sh <instance-id>

# Launch replacement (will rejoin with same node_id)
./scripts/launch-node.sh <az-index>  # 0, 1, or 2
```

### Rolling Updates (AMI or Vault Version)

See [docs/rolling-updates.md](docs/rolling-updates.md) for the full runbook.

```bash
# Update vault_version in terraform/environments/nonprod-test.tfvars, then:
VAULT_ENV=nonprod-test VAULT_ADDR=https://vault.nonprod-test.example.io VAULT_TOKEN=<token> \
  ./scripts/rolling-update.sh
```

### Backup and Restore

Automated backups run every 6 hours on the leader node when `backup_enabled = true`. See [docs/operations.md](docs/operations.md) for full details.

```bash
# Manual snapshot
vault operator raft snapshot save backup.snap

# Restore from S3 backup (interactive)
./scripts/restore-snapshot.sh nonprod-test

# Sync nonprod data to nonprod-test
./scripts/sync-to-nonprod-test.sh
```

## Why Scripts Instead of ASG?

This cluster uses scripts for node management instead of Auto Scaling Groups because:

1. **Data Safety**: ASGs with instance refresh can replace all nodes simultaneously, causing data loss with Raft storage
2. **Stable Node Identity**: Script-managed nodes use AZ-based node IDs that persist across instance replacement
3. **Controlled Updates**: Rolling updates happen one node at a time with health verification
4. **Persistent Storage**: EBS volumes are managed by Terraform but attached/detached by scripts

### How Node Replacement Works

```
1. terminate-node.sh terminates instance
   └─► EBS volume detached (data preserved)
   └─► Node appears "down" in Raft (not removed)

2. launch-node.sh launches new instance
   └─► Same EBS volume reattached
   └─► Same node_id (cluster-az format)
   └─► Vault reads existing Raft data
   └─► Node reconnects to cluster automatically
```

## Security

### TLS Configuration

- **Client → NLB**: TLS terminated at NLB using ACM certificate (port 443)
- **NLB → Nodes**: TLS with self-signed certs (port 8200)
- **Node → Node**: Mutual TLS with self-signed CA (port 8201)
- **`api_addr`**: Private IP:8200 (direct node-to-node request forwarding, no NLB hop)

The self-signed CA is generated by OpenTofu and stored in AWS Secrets Manager. Each node generates its own certificate at boot time, signed by this CA.

### IAM Permissions

Vault nodes have minimal IAM permissions:
- `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` - Auto-unseal
- `ec2:DescribeInstances` - Raft auto-join discovery
- `secretsmanager:GetSecretValue`, `secretsmanager:PutSecretValue` - CA cert/key, root token, recovery keys
- `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` - Backup bucket (when backup enabled)
- SSM Session Manager access (for troubleshooting)

### Security Groups

- **Vault SG**:
  - Inbound 8200 from `allowed_cidr_blocks` (via NLB)
  - Inbound 8200, 8201 from self (cluster communication)
  - Outbound all

## Troubleshooting

### Node Won't Join Cluster

1. Check the node logs:
   ```bash
   # Via SSM Session Manager
   aws ssm start-session --target <instance-id>
   sudo journalctl -u vault -f
   sudo cat /var/log/vault-setup.log
   ```

2. Verify tags are correct:
   ```bash
   aws ec2 describe-instances --instance-id <id> --query 'Reservations[].Instances[].Tags'
   ```

3. Check security group allows 8200/8201 between nodes

### Sealed Vault

With KMS auto-unseal, this shouldn't happen. If it does:

1. Check KMS key permissions
2. Check instance IAM role
3. Check Vault logs: `journalctl -u vault` (via SSM session)

### Health Check Failures

NLB health checks use HTTPS on `/v1/sys/health?standby=true&perfstandbyok=true`. With these query params, all healthy nodes (active and standby) return 200.

If failing:
1. SSH to node and check `vault status`
2. Check `/var/log/vault-setup.log` for bootstrap issues
3. Verify certificates are valid: `openssl x509 -in /opt/vault/tls/node.crt -text`

### EBS Volume Issues

```bash
# Check volume state
aws ec2 describe-volumes --volume-ids <vol-id>

# If stuck "in-use" after instance termination, force detach
aws ec2 detach-volume --volume-id <vol-id> --force
```

## Cost Optimization

- Uses ARM64 Graviton instances (m8g.medium) - ~20% cheaper than x86
- NLB is cheaper than ALB for equivalent throughput
- Consider Reserved Instances for production workloads

## Docker

An Amazon Linux 2023 container is provided with all required tools (AWS CLI, OpenTofu, Vault CLI, jq).

### Quick Start

```bash
# Build and run interactive shell
./scripts/docker-run.sh

# Or use docker-compose
docker-compose run --rm vault-ops
```

### Run Commands

```bash
# Check cluster status
./scripts/docker-run.sh ./scripts/cluster-status.sh

# Run Terraform plan
./scripts/docker-run.sh tofu plan

# Rolling update
export VAULT_ADDR="https://vault.example.com"
export VAULT_TOKEN="<token>"
./scripts/docker-run.sh ./scripts/rolling-update.sh
```

### Build Manually

```bash
# Build with default versions
docker build -t vault-cluster-ops .

# Build with specific versions
docker build \
  --build-arg TOFU_VERSION=1.6.2 \
  --build-arg VAULT_VERSION=1.21.4 \
  -t vault-cluster-ops .
```

### AWS Authentication

The container supports multiple authentication methods:

```bash
# Environment variables
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
./scripts/docker-run.sh

# AWS profiles (mounts ~/.aws automatically)
export AWS_PROFILE="my-profile"
./scripts/docker-run.sh

# IAM roles (when running on EC2/ECS)
# No additional config needed
```

## License

MIT
