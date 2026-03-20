# Vault Cluster Operations Guide

Complete guide to operating the Vault cluster across all environments: multi-environment management, backups, restores, data sync, credential management, and migration from legacy clusters.

## Table of Contents

- [Multi-Environment Management](#multi-environment-management)
- [Automated Backups](#automated-backups)
- [Restore from Backup](#restore-from-backup)
- [Data Sync (nonprod to nonprod-test)](#data-sync-nonprod-to-nonprod-test)
- [Credential Management](#credential-management)
- [Recovery Key Regeneration](#recovery-key-regeneration)
- [Migration from Legacy Clusters](#migration-from-legacy-clusters)
- [Vault Version Upgrade Path](#vault-version-upgrade-path)
- [Backup IAM Auth Setup](#backup-iam-auth-setup)

---

## Multi-Environment Management

### Environments

| Environment | AWS Account | Cluster Name | Domain |
|-------------|-------------|--------------|--------|
| nonprod-test | shared-nonprod | vault-nonprod-test | vault.nonprod-test.reisys.io |
| nonprod | shared-nonprod | vault-nonprod | vault.nonprod.reisys.io |
| prod | prod | vault-prod | vault.prod.reisys.io |

### Directory Structure

```
terraform/
  environments/
    nonprod-test.tfvars  # All variables for nonprod-test
    nonprod.tfvars       # All variables for nonprod
    prod.tfvars          # All variables for prod

  backend-configs/
    nonprod-test.hcl     # S3 state backend for nonprod-test
    nonprod.hcl          # S3 state backend for nonprod
    prod.hcl             # S3 state backend for prod (different account bucket)
```

### Setup

Before first use, edit the placeholder values in each file:

1. **`terraform/backend-configs/*.hcl`** — Set your actual S3 bucket names and regions for state storage
2. **`terraform/environments/*.tfvars`** — Set your actual VPC IDs, subnet IDs, ACM certificate ARNs, and any other environment-specific values

### Using the Environment Wrapper

The `scripts/env.sh` wrapper handles backend initialization and var-file selection:

```bash
# Plan for nonprod-test
./scripts/env.sh nonprod-test plan

# Apply to nonprod
./scripts/env.sh nonprod apply

# Plan with a specific target
./scripts/env.sh prod plan -target=module.backup

# Destroy a specific resource
./scripts/env.sh nonprod-test destroy -target=module.backup

# View outputs
./scripts/env.sh nonprod output
```

What it does internally:
1. `tofu init -reconfigure -backend-config=terraform/backend-configs/$ENV.hcl`
2. `tofu $CMD -var-file=terraform/environments/$ENV.tfvars` (for commands that accept var-file)

### Using Operational Scripts with Environments

The node management scripts (`launch-node.sh`, `terminate-node.sh`, `rolling-update.sh`) support the `VAULT_ENV` environment variable:

```bash
# Launch a node in nonprod-test
VAULT_ENV=nonprod-test ./scripts/launch-node.sh 0

# Terminate a node in nonprod
VAULT_ENV=nonprod ./scripts/terminate-node.sh i-0abc123

# Rolling update in prod
VAULT_ENV=prod VAULT_ADDR=https://vault.prod.reisys.io VAULT_TOKEN=<token> \
  ./scripts/rolling-update.sh

# cluster-status.sh doesn't need VAULT_ENV (no tofu dependency)
VAULT_ADDR=https://vault.nonprod.reisys.io VAULT_TOKEN=<token> \
  ./scripts/cluster-status.sh
```

When `VAULT_ENV` is set, scripts automatically run `tofu init -reconfigure` with the correct backend config before reading outputs. When unset, behavior is unchanged (uses whatever backend is currently initialized).

### State Isolation

Each environment has completely separate Terraform state:

```
# nonprod-test state
s3://your-terraform-state-bucket/vault-nonprod-test/terraform.tfstate

# nonprod state
s3://your-terraform-state-bucket/vault-nonprod/terraform.tfstate

# prod state (different bucket in prod account)
s3://your-terraform-state-bucket-prod/vault-prod/terraform.tfstate
```

Switching between environments always uses `-reconfigure` so there is no risk of applying the wrong state.

---

## Automated Backups

### How It Works

When `backup_enabled = true` in the environment tfvars:

1. **Terraform creates** an S3 bucket with versioning, encryption, and lifecycle rules
2. **Each node** gets a systemd timer that fires every 6 hours (with up to 15 minutes of random jitter)
3. **Only the leader** takes backups — standby nodes detect they're not the leader and skip
4. The backup script **authenticates via AWS IAM auth** to get a short-lived Vault token
5. Snapshots are uploaded to S3 with `daily/` and `weekly/` prefixes

### S3 Lifecycle Rules

| Prefix | Transition | Expiration |
|--------|-----------|------------|
| `daily/` | Standard-IA at 30 days | Configurable (default 90 days) |
| `weekly/` | Glacier at 60 days | 365 days |
| `sync/` | — | 30 days |

### Prerequisites

Backup automation requires a **one-time Vault configuration** to set up IAM auth. See [Backup IAM Auth Setup](#backup-iam-auth-setup) below.

### Deploying Backups to an Environment

```bash
# 1. Ensure backup variables are set in terraform/environments/nonprod-test.tfvars
#    backup_enabled   = true
#    backup_s3_bucket = "vault-nonprod-test-backups"

# 2. Deploy
./scripts/env.sh nonprod-test apply

# 3. Roll nodes to pick up the systemd timer
VAULT_ENV=nonprod-test VAULT_ADDR=https://vault.nonprod-test.reisys.io VAULT_TOKEN=<token> \
  ./scripts/rolling-update.sh
```

### Verifying Backups

SSH to the leader node and check:

```bash
# Check timer status
systemctl status vault-backup.timer

# Check most recent run
systemctl status vault-backup.service
journalctl -u vault-backup.service --no-pager -n 50

# Manually trigger a backup
systemctl start vault-backup.service

# Check S3 for snapshots
aws s3 ls s3://vault-nonprod-test-backups/vault-nonprod-test/daily/ --recursive
```

### Manual Backup (from operator machine)

You don't have to rely on the automated backups. Take a snapshot anytime:

```bash
export VAULT_ADDR="https://vault.nonprod.reisys.io"
export VAULT_TOKEN="<root-or-operator-token>"

vault operator raft snapshot save vault-backup-$(date +%Y%m%d-%H%M%S).snap

# Optionally upload to S3
aws s3 cp vault-backup-*.snap s3://vault-nonprod-backups/vault-nonprod/daily/
```

---

## Restore from Backup

### Interactive Restore

The restore script lists available snapshots and guides you through the process:

```bash
export VAULT_ADDR="https://vault.nonprod-test.reisys.io"
export VAULT_TOKEN="<root-token>"

./scripts/restore-snapshot.sh nonprod-test
```

This will:
1. Read the backup bucket name from `terraform/environments/nonprod-test.tfvars`
2. List recent daily, weekly, and sync snapshots
3. Prompt you to select one
4. Download it from S3
5. Require you to type `RESTORE` to confirm
6. Restore using `vault operator raft snapshot restore -force`
7. Verify Vault status

### Direct Restore (with known S3 key)

```bash
export VAULT_ADDR="https://vault.nonprod-test.reisys.io"
export VAULT_TOKEN="<root-token>"

./scripts/restore-snapshot.sh nonprod-test \
  vault-nonprod-test/daily/vault-snapshot-20260317-060000.snap
```

### Important Notes

- The `-force` flag is always used because the snapshot may come from a different cluster (different cluster ID)
- After a cross-cluster restore, the **source cluster's root token becomes valid** on the target
- **KMS auto-unseal is not affected** — it's configured in Vault's config file, not in the snapshot data
- After restore, you may need to wait a few seconds for all nodes to sync

---

## Data Sync (nonprod to nonprod-test)

Copy all Vault data from nonprod to nonprod-test for testing and development.

### Usage

```bash
export VAULT_NONPROD_ADDR="https://vault.nonprod.reisys.io"
export VAULT_NONPROD_TOKEN="<nonprod-root-token>"
export VAULT_TEST_ADDR="https://vault.nonprod-test.reisys.io"
export VAULT_TEST_TOKEN="<nonprod-test-root-token>"

./scripts/sync-to-nonprod-test.sh
```

For non-interactive use (CI/CD):

```bash
./scripts/sync-to-nonprod-test.sh --yes
```

### What Happens

1. Takes a Raft snapshot from nonprod
2. Uploads an audit copy to the nonprod-test backup bucket (`sync/` prefix)
3. Restores the snapshot to nonprod-test with `-force`
4. Verifies nonprod-test is running

### Post-Sync Effects

After sync, nonprod-test is an exact copy of nonprod:

- **All secrets, policies, auth methods, entities** — identical to nonprod
- **The nonprod root token is now valid** on nonprod-test
- **All application tokens from nonprod work** on nonprod-test
- **KMS auto-unseal still uses nonprod-test's KMS key** (not affected by snapshot)
- **Sync snapshots auto-expire** after 30 days in S3

### Recommended Post-Sync Actions

- Rotate the nonprod-test root token if desired
- Notify teams that nonprod-test data has been refreshed
- If any auth backends point to environment-specific endpoints (e.g., LDAP servers), verify they still work

---

## Credential Management

Root tokens and recovery keys are stored in AWS Secrets Manager for each cluster.

### Secrets Manager Structure

```
<cluster-name>/vault/root-token       → {"token": "hvs.xxxxx"}
<cluster-name>/vault/recovery-keys    → {"keys_base64": ["key1", "key2", ...]}
```

These secrets are created as empty placeholders by Terraform. The scripts populate them with actual values.

### Storing Credentials

After initializing a cluster or generating new keys:

```bash
./scripts/store-vault-credentials.sh nonprod-test
```

The script will:
1. Read cluster name and region from `terraform/environments/nonprod-test.tfvars`
2. Prompt for the root token (hidden input)
3. Prompt for recovery keys one at a time (hidden input)
4. Store each in Secrets Manager

### Retrieving Credentials

```bash
# Get root token
aws secretsmanager get-secret-value \
  --secret-id vault-nonprod-test/vault/root-token \
  --query SecretString --output text | jq -r '.token'

# Get recovery keys
aws secretsmanager get-secret-value \
  --secret-id vault-nonprod-test/vault/recovery-keys \
  --query SecretString --output text | jq -r '.keys_base64[]'
```

### IAM Permissions

Vault nodes have both `GetSecretValue` and `PutSecretValue` on these secrets, so automation scripts running on the nodes can update them. Operator access is via your normal AWS IAM credentials.

---

## Recovery Key Regeneration

For clusters where recovery keys have been lost but a root token is still available.

### When to Use

- Recovery keys are lost/unavailable
- You have the root token
- The cluster uses KMS auto-unseal

### Usage

```bash
export VAULT_ADDR="https://vault.nonprod.reisys.io"
export VAULT_TOKEN="<root-token>"

./scripts/rekey-recovery.sh
```

### How It Works

1. Verifies the cluster is unsealed and using KMS auto-unseal
2. Initiates a recovery key rekey via the `/v1/sys/rekey-recovery-key/init` API
3. Prompts for existing recovery keys to authorize the operation
4. Outputs the new recovery keys

### Important Caveat

Even with KMS auto-unseal, Vault requires **existing recovery keys** to authorize a recovery key rekey. If recovery keys are completely lost:

- The rekey script will inform you of this requirement
- **Workaround for fresh deployments**: Deploy a new cluster, restore a snapshot, and initialize with new recovery keys (the init process generates new keys)
- Store the new recovery keys immediately using `./scripts/store-vault-credentials.sh`

### After Rekeying

```bash
# Store the new keys
./scripts/store-vault-credentials.sh nonprod
# (skip root token, enter the new recovery keys)
```

---

## Migration from Legacy Clusters

Migrate existing Vault 1.9.0 clusters to this new infrastructure.

### Migration Strategy

Fresh deploy + snapshot restore. The old cluster stays running until the new one is verified.

### Prerequisites

- Root token for the existing cluster
- New infrastructure deployed via `./scripts/env.sh <env> apply`
- DNS access for the Vault domain

### Step-by-Step Migration

#### 1. Take Snapshot of Existing Cluster

```bash
export VAULT_ADDR="https://old-vault.nonprod.reisys.io"
export VAULT_TOKEN="<existing-root-token>"

# Create snapshot
vault operator raft snapshot save vault-nonprod-migration-$(date +%Y%m%d).snap

# Keep a copy in S3
aws s3 cp vault-nonprod-migration-*.snap s3://vault-nonprod-backups/migration/
```

#### 2. Deploy New Infrastructure

```bash
# Edit terraform/environments/nonprod.tfvars with real values first
./scripts/env.sh nonprod apply
```

#### 3. Launch First Node and Initialize

```bash
VAULT_ENV=nonprod ./scripts/launch-node.sh 0

# Wait for the node to boot (~2 minutes)
# Point to the new NLB
export VAULT_ADDR="https://<nlb-dns-name>"
export VAULT_SKIP_VERIFY=true

# Initialize - this creates NEW recovery keys
vault operator init -recovery-shares=5 -recovery-threshold=3
```

**Save the recovery keys and root token immediately:**

```bash
./scripts/store-vault-credentials.sh nonprod
```

#### 4. Restore Snapshot

```bash
export VAULT_TOKEN="<new-root-token>"

vault operator raft snapshot restore -force vault-nonprod-migration-*.snap
```

#### 5. Launch Remaining Nodes

```bash
VAULT_ENV=nonprod ./scripts/launch-node.sh 1
VAULT_ENV=nonprod ./scripts/launch-node.sh 2

# Verify
VAULT_ADDR="https://<nlb-dns-name>" VAULT_TOKEN="<token>" ./scripts/cluster-status.sh
vault operator raft list-peers
```

#### 6. Verify Data

```bash
vault auth list
vault secrets list
vault policy list
# Spot-check known secrets
vault kv get secret/some-known-path
```

#### 7. Update DNS

Point the Vault domain to the new NLB:

```bash
# Get NLB details
./scripts/env.sh nonprod output nlb_dns_name
./scripts/env.sh nonprod output nlb_zone_id
```

Create Route 53 alias record or CNAME pointing to the NLB.

#### 8. Final Verification

```bash
unset VAULT_SKIP_VERIFY
export VAULT_ADDR="https://vault.nonprod.reisys.io"

vault status
./scripts/cluster-status.sh
```

#### 9. Decommission Old Cluster

Keep the old cluster running for 24-48 hours as a fallback, then decommission.

---

## Vault Version Upgrade Path

When migrating from Vault 1.9.0, there are two approaches:

### Option A: Direct Upgrade (simpler, riskier)

Deploy the new cluster at the latest version (1.21.x), restore the 1.9.0 snapshot. The data format gets upgraded on restore.

```bash
# In terraform/environments/nonprod-test.tfvars
vault_version = "1.21.4"
```

Test this on nonprod-test first since it's expendable.

### Option B: Stepped Upgrade (safer)

Deploy at 1.9.0, restore snapshot, then do rolling upgrades through intermediate versions:

```bash
# 1. Deploy at 1.9.0
#    vault_version = "1.9.0" in tfvars

# 2. Restore snapshot, verify

# 3. Upgrade through versions (edit tfvars, then rolling-update each time):
#    1.9.0 → 1.12.x → 1.15.x → 1.17.x → 1.19.x
VAULT_ENV=nonprod-test ./scripts/rolling-update.sh

# 4. After each upgrade, verify:
vault status
vault secrets list
```

### Recommendation

Test Option A on nonprod-test first. If it works cleanly, use it for nonprod and prod. If there are issues, fall back to Option B.

---

## Backup IAM Auth Setup

The automated backup system uses Vault's AWS IAM auth method so each node can authenticate and take snapshots without storing static tokens.

### One-Time Setup (per cluster)

Run these commands against the Vault cluster after it's initialized:

```bash
export VAULT_ADDR="https://vault.nonprod-test.reisys.io"
export VAULT_TOKEN="<root-token>"

# 1. Enable AWS auth method
vault auth enable aws

# 2. Create backup policy
vault policy write backup - <<EOF
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF

# 3. Get the Vault IAM role ARN from Terraform outputs
ROLE_ARN=$(./scripts/env.sh nonprod-test output -raw iam_role_arn)

# 4. Create AWS auth role mapping the instance profile to the backup policy
vault write auth/aws/role/backup \
  auth_type=iam \
  bound_iam_principal_arn="$ROLE_ARN" \
  policies=backup \
  token_ttl=5m \
  token_max_ttl=10m

# 5. Verify (from a Vault node via SSM)
# vault login -method=aws role=backup
```

### Verifying the Setup

SSH to a Vault node and test:

```bash
aws ssm start-session --target <instance-id>

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/ca.crt"

# Test authentication
vault login -method=aws role=backup

# Test snapshot (should succeed)
vault operator raft snapshot save /tmp/test.snap
rm /tmp/test.snap

# Revoke the test token
vault token revoke -self
```

---

## Quick Reference

### Common Commands

```bash
# Deploy/update an environment
./scripts/env.sh <env> plan
./scripts/env.sh <env> apply

# Launch/terminate nodes
VAULT_ENV=<env> ./scripts/launch-node.sh <az-index>
VAULT_ENV=<env> ./scripts/terminate-node.sh <instance-id>

# Rolling update
VAULT_ENV=<env> VAULT_ADDR=<url> VAULT_TOKEN=<token> ./scripts/rolling-update.sh

# Cluster health
VAULT_ADDR=<url> VAULT_TOKEN=<token> ./scripts/cluster-status.sh

# Backup/restore
./scripts/restore-snapshot.sh <env> [s3-key]

# Data sync
VAULT_NONPROD_ADDR=<url> VAULT_NONPROD_TOKEN=<token> \
VAULT_TEST_ADDR=<url> VAULT_TEST_TOKEN=<token> \
./scripts/sync-to-nonprod-test.sh

# Credential management
./scripts/store-vault-credentials.sh <env>
./scripts/rekey-recovery.sh

# Manual snapshot
vault operator raft snapshot save backup.snap
```

### Environment Variables

| Variable | Used By | Description |
|----------|---------|-------------|
| `VAULT_ENV` | launch-node, terminate-node, rolling-update | Selects backend config for tofu |
| `VAULT_ADDR` | All vault CLI operations | Vault API address |
| `VAULT_TOKEN` | All vault CLI operations | Authentication token |
| `VAULT_CACERT` | Vault CLI (optional) | Path to CA cert for TLS verification |
| `VAULT_SKIP_VERIFY` | Vault CLI (optional) | Skip TLS verification |
| `VAULT_NONPROD_ADDR` | sync-to-nonprod-test | Source Vault address |
| `VAULT_NONPROD_TOKEN` | sync-to-nonprod-test | Source root/operator token |
| `VAULT_TEST_ADDR` | sync-to-nonprod-test | Target Vault address |
| `VAULT_TEST_TOKEN` | sync-to-nonprod-test | Target root/operator token |

### Files at a Glance

```
scripts/
  env.sh                      # tofu wrapper: ./scripts/env.sh <env> <cmd>
  launch-node.sh              # Launch EC2 instance in AZ
  terminate-node.sh           # Gracefully terminate instance
  rolling-update.sh           # Rolling replace all nodes
  cluster-status.sh           # Health check
  backup-snapshot.sh          # On-node backup (runs via systemd)
  restore-snapshot.sh         # Restore from S3 backup
  sync-to-nonprod-test.sh     # Copy nonprod data to nonprod-test
  store-vault-credentials.sh  # Save root token + recovery keys to Secrets Manager
  rekey-recovery.sh           # Regenerate lost recovery keys
```
