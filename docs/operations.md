# Vault Cluster Operations Guide

Complete guide to operating the Vault cluster across all environments: multi-environment management, backups, restores, data sync, credential management, and migration from legacy clusters.

## Table of Contents

- [Multi-Environment Management](#multi-environment-management)
- [Automated Backups](#automated-backups)
- [Restore from Backup](#restore-from-backup)
- [Data Sync (nonprod to nonprod-test)](#data-sync-nonprod-to-nonprod-test)
- [Credential Management](#credential-management)
- [Audit Logging](#audit-logging)
- [Recovery Key Regeneration](#recovery-key-regeneration)
- [Migration from Legacy Clusters](#migration-from-legacy-clusters)
- [Vault Version Upgrade Path](#vault-version-upgrade-path)
- [Backup IAM Auth Setup](#backup-iam-auth-setup)

---

## Multi-Environment Management

### Environments

| Environment | AWS Account | Cluster Name | Domain |
|-------------|-------------|--------------|--------|
| nonprod-test | shared-nonprod | vault-nonprod-test | vault.nonprod-test.example.io |
| nonprod | shared-nonprod | vault-nonprod | vault.nonprod.example.io |
| prod | prod | vault-prod | vault.prod.example.io |

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
VAULT_ENV=prod VAULT_ADDR=https://vault.prod.example.io VAULT_TOKEN=<token> \
  ./scripts/rolling-update.sh

# cluster-status.sh doesn't need VAULT_ENV (no tofu dependency)
VAULT_ADDR=https://vault.nonprod.example.io VAULT_TOKEN=<token> \
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
VAULT_ENV=nonprod-test VAULT_ADDR=https://vault.nonprod-test.example.io VAULT_TOKEN=<token> \
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
export VAULT_ADDR="https://vault.nonprod.example.io"
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
export VAULT_ADDR="https://vault.nonprod-test.example.io"
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
export VAULT_ADDR="https://vault.nonprod-test.example.io"
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
export VAULT_NONPROD_ADDR="https://vault.nonprod.example.io"
export VAULT_NONPROD_TOKEN="<nonprod-root-token>"
export VAULT_TEST_ADDR="https://vault.nonprod-test.example.io"
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

## Audit Logging

Vault's audit device writes an append-only log of every request and response
to the API. This is the forensic/compliance backbone: the only way to answer
"who read secret X at time Y?" after the fact. Sensitive values are HMAC'd
before writing — the log shows *that* a secret was accessed, not its contents.

### Where logs live

File: `/var/log/vault/audit.log` on each node, rotated daily (or on 100M size
threshold, whichever hits first) via `/etc/logrotate.d/vault-audit`. Rotated
files are gzip-compressed after the next rotation (`delaycompress`) and 14
rotated files are retained on disk.

Because the log lives under `/var/log`, the existing Splunk forwarder picks
it up automatically — no additional agent config needed.

### One-time enable (per cluster)

```bash
# Via Jenkins:
vault-cluster/<env>/setup-audit

# Or manually:
export VAULT_ADDR=https://vault.<env>.reisys.io
export VAULT_TOKEN=<root-token>
vault audit enable file file_path=/var/log/vault/audit.log log_raw=false
```

The `setup-audit.Jenkinsfile` pipeline is idempotent — re-running is safe.

### Verification

```bash
# List enabled audit devices
vault audit list

# Tail the log on a specific node
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/vault/audit.log

# Inspect rotation state
sudo ls -la /var/log/vault/
sudo cat /var/lib/logrotate/logrotate.status | grep vault
```

### IMPORTANT operational caveats

- **Audit-device failure = Vault unavailability.** If `/var/log/vault/audit.log`
  becomes unwritable (permissions drift, root disk full, deleted by mistake),
  Vault will refuse all requests. This is a security property, not a bug —
  Vault must not silently drop audit entries. Monitor disk free on the node
  root volume.
- **No in-band rotation restart needed.** `copytruncate` keeps Vault's open
  file descriptor valid across logrotate runs — no SIGHUP required.
- **`log_raw=false`** — the default. HMACs sensitive fields. Set to `true`
  only in short-lived debugging sessions with an isolated log destination;
  `log_raw=true` writes plaintext secrets to the log.

### Why file + logrotate (not syslog or socket)

Splunk already tails `/var/log`. Adding a file device gives Splunk the audit
log for free with no new moving parts. The `syslog` / `socket` devices would
require additional forwarding config and add failure modes we don't need.

## Recovery Key Rotation

`scripts/rekey-recovery.sh` **rotates** existing recovery keys. It is NOT a
mechanism to recover a cluster whose recovery keys have been lost.

> **If recovery keys are LOST**, see
> [dr-lost-recovery-keys.md](dr-lost-recovery-keys.md) for the break-glass
> rebuild procedure. No script can help you rotate keys you no longer hold —
> Vault requires the current keys to authorize any rekey, by design.

### When to Use This Script

Use `rekey-recovery.sh` when all of the following are true:

- You have the CURRENT recovery keys (typically in AWS Secrets Manager at
  `<cluster>/vault/recovery-keys`)
- You have the root token
- The cluster uses KMS auto-unseal (`seal_type=awskms`)
- Cluster is unsealed and reachable

Typical reasons: scheduled rotation, key-exposure incident, team-transition handoff.

### Usage

```bash
export VAULT_ADDR="https://vault.nonprod.example.io"
export VAULT_TOKEN="<root-token>"

./scripts/rekey-recovery.sh
# Enter current recovery keys when prompted.
```

### What It Does

1. Verifies cluster is unsealed and using KMS auto-unseal.
2. Calls `POST /v1/sys/rekey-recovery-key/init` to start the rekey.
3. Prompts for the required number of current recovery keys (threshold, usually 3 of 5).
4. Emits the new recovery keys on completion.

### After Rotation

```bash
# Store the new keys in Secrets Manager
./scripts/store-vault-credentials.sh <env>
# (skip root token prompt, enter the new recovery keys)
```

### Why "just rebuild" isn't automated

The rekey API's requirement for current keys is a Vault security property —
the recovery keys are the strongest DR credential. A cluster that cannot prove
possession of the current keys cannot rotate them, full stop. There is no API
flag, token, or IAM-based bypass. That's why lost-keys recovery is a
documented runbook ([dr-lost-recovery-keys.md](dr-lost-recovery-keys.md)),
not a script: it involves standing up a fresh cluster, restoring from
snapshot, initializing with new keys, and cutting traffic. It is operator-driven,
multi-hour, and needs stakeholder awareness.

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
export VAULT_ADDR="https://old-vault.nonprod.example.io"
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
export VAULT_ADDR="https://vault.nonprod.example.io"

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
export VAULT_ADDR="https://vault.nonprod-test.example.io"
export VAULT_TOKEN="<root-token>"

# 1. Enable AWS auth method
vault auth enable aws

# 2. Create backup policy
vault policy write backup - <<EOF
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# Required by backup-snapshot.sh Raft-consensus leader check
# (see C4 in review-findings.md). backup-snapshot.sh calls
# 'vault operator raft list-peers' to confirm Raft consensus
# before taking a snapshot, preventing corrupt backups during
# network partitions.
path "sys/storage/raft/configuration" {
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
