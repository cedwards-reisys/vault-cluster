# Migrating an Existing Vault Cluster

This guide covers migrating an existing Vault cluster to the new script-managed infrastructure with persistent EBS volumes.

## Overview

The migration uses Vault's Raft snapshot feature to transfer all data (secrets, policies, auth methods, etc.) from your existing cluster to a new cluster running on this infrastructure.

**Migration Strategy**: Fresh Start with Data Migration
- Deploy new infrastructure alongside existing cluster
- Backup existing cluster data via Raft snapshot
- Initialize new cluster and restore snapshot
- Switch DNS to new cluster
- Decommission old cluster

**Downtime**: Minimal (DNS propagation time only, typically 1-5 minutes)

## Prerequisites

- [ ] Root token or token with `sys/storage/raft/snapshot` capability on existing cluster
- [ ] AWS credentials configured with appropriate permissions
- [ ] OpenTofu >= 1.6.0 installed
- [ ] Vault CLI installed
- [ ] Access to DNS management for your Vault domain
- [ ] ACM certificate for your Vault domain (can reuse existing)

## Pre-Migration Checklist

### 1. Verify Existing Cluster Health

```bash
# Set existing cluster address
export VAULT_ADDR="https://old-vault.example.com"
export VAULT_TOKEN="<your-root-or-admin-token>"

# Check cluster health
vault status

# Check Raft peer status
vault operator raft list-peers

# Verify all nodes are healthy
curl -sk "$VAULT_ADDR/v1/sys/health" | jq
```

All nodes should show as healthy before proceeding.

### 2. Inventory Existing Configuration

Document your current setup for verification after migration:

```bash
# List auth methods
vault auth list

# List secrets engines
vault secrets list

# List policies
vault policy list

# Check audit devices
vault audit list

# List namespaces (Enterprise only)
vault namespace list
```

### 3. Notify Users

- Schedule maintenance window
- Notify application teams of upcoming DNS change
- Ensure no critical operations during migration

## Migration Steps

### Step 1: Create Raft Snapshot

Create a backup of all Vault data:

```bash
export VAULT_ADDR="https://old-vault.example.com"
export VAULT_TOKEN="<root-token>"

# Create snapshot
vault operator raft snapshot save backup-$(date +%Y%m%d-%H%M%S).snap

# Verify snapshot file was created
ls -la backup-*.snap

# Keep multiple copies in different locations
cp backup-*.snap /path/to/secure/backup/location/
```

**Important**: Store the snapshot securely. It contains all secrets and configuration.

### Step 2: Configure New Infrastructure

```bash
cd vault-cluster/terraform

# Copy example configuration
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your values:

```hcl
aws_region          = "us-east-1"
vpc_id              = "vpc-xxxxxxxxx"
private_subnet_ids  = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/xxx"
cluster_name        = "vault-prod"  # Use a NEW name to avoid conflicts
vault_domain        = "vault.example.com"
vault_version       = "1.21.4"      # See "Version Upgrade Research" section below
environment         = "prod"
```

**Critical**: Use a different `cluster_name` than your existing cluster to avoid resource naming conflicts.

### Step 3: Deploy Infrastructure

```bash
# Initialize OpenTofu
tofu init

# Review the plan
tofu plan

# Apply (creates KMS, IAM, security groups, NLB, EBS volumes)
tofu apply
```

This creates:
- KMS key for auto-unseal
- IAM roles and policies
- Security groups
- Network Load Balancer
- Persistent EBS volumes (one per AZ)
- Self-signed CA in Secrets Manager

**Note**: No EC2 instances are created yet.

### Step 4: Note the New NLB DNS Name

```bash
# Get NLB DNS name for later DNS configuration
aws ssm get-parameter --name /${CLUSTER_NAME}/config/vault-config \
  --query Parameter.Value --output text | jq -r .nlb_dns_name
```

Save this value - you'll need it for the DNS cutover.

### Step 5: Launch First Node

```bash
# Launch node in first AZ
./scripts/launch-node.sh --yes 0

# Wait for instance to be running
# The script will output the instance ID
```

Wait for the node to fully boot (1-2 minutes).

### Step 6: Initialize New Cluster

```bash
# Point to new cluster via NLB
export VAULT_ADDR="https://<nlb-dns-name>"
export VAULT_SKIP_VERIFY=true  # Until DNS is configured

# Check status (should show uninitialized)
vault status

# Initialize (creates NEW recovery keys)
vault operator init -recovery-shares=5 -recovery-threshold=3
```

**Critical**: Save the new recovery keys and root token securely! These are different from your old cluster's keys.

```bash
# Verify initialization
vault status
# Should show: Initialized: true, Sealed: false
```

### Step 7: Restore Snapshot

```bash
# Use the new root token
export VAULT_TOKEN="<new-root-token>"

# Restore the snapshot from your existing cluster
vault operator raft snapshot restore -force backup-*.snap
```

The `-force` flag is required because the new cluster has a different cluster ID.

**What gets restored**:
- All secrets and secret engines
- All policies
- All auth methods and configurations
- All entities and groups
- Audit device configurations
- Namespaces (Enterprise)

**What does NOT get restored**:
- Unseal/recovery keys (you keep the new ones)
- Root token (you keep the new one)
- Raft cluster membership (managed by new infrastructure)

### Step 8: Verify Restoration

```bash
# Login with new root token
vault login "$VAULT_TOKEN"

# Verify auth methods restored
vault auth list

# Verify secrets engines restored
vault secrets list

# Verify policies restored
vault policy list

# Spot-check a secret (if you know a path)
vault kv get secret/test
```

Compare against the inventory from pre-migration checklist.

### Step 9: Launch Remaining Nodes

```bash
# Launch node in second AZ
./scripts/launch-node.sh --yes 1

# Wait for it to join (check cluster status)
./scripts/cluster-status.sh

# Launch node in third AZ
./scripts/launch-node.sh --yes 2

# Verify all nodes joined
./scripts/cluster-status.sh
```

Verify Raft cluster has all 3 peers:

```bash
vault operator raft list-peers
```

Expected output:
```
Node                   Address              State       Voter
----                   -------              -----       -----
vault-prod-us-east-1a  10.0.1.x:8201        leader      true
vault-prod-us-east-1b  10.0.2.x:8201        follower    true
vault-prod-us-east-1c  10.0.3.x:8201        follower    true
```

### Step 10: Test New Cluster

Before DNS cutover, thoroughly test the new cluster:

```bash
# Test authentication (if using userpass, LDAP, etc.)
vault login -method=userpass username=testuser

# Test secret access
vault kv get secret/myapp/config

# Test policy enforcement
# (login as non-root user and verify permissions)
```

### Step 11: Update DNS

Switch your Vault domain to point to the new NLB:

**Option A: Route 53 Alias Record (Recommended)**

```bash
# Get the NLB DNS name from SSM (zone ID from AWS API)
VAULT_CONFIG=$(aws ssm get-parameter --name /${CLUSTER_NAME}/config/vault-config \
  --query Parameter.Value --output text)
NLB_DNS=$(echo "$VAULT_CONFIG" | jq -r .nlb_dns_name)
NLB_ZONE=$(aws elbv2 describe-load-balancers \
  --names "${CLUSTER_NAME}" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)

echo "NLB DNS: $NLB_DNS"
echo "NLB Zone ID: $NLB_ZONE"
```

Create/update Route 53 alias record pointing to the NLB.

**Option B: CNAME Record**

Update your DNS provider with a CNAME record:
```
vault.example.com  CNAME  <nlb-dns-name>
```

### Step 12: Verify DNS and Final Testing

```bash
# Wait for DNS propagation (check with dig)
dig vault.example.com

# Test with proper domain
unset VAULT_SKIP_VERIFY
export VAULT_ADDR="https://vault.example.com"

# Verify health
curl -sk "$VAULT_ADDR/v1/sys/health" | jq

# Test authentication and operations
vault login -method=<your-auth-method>
vault kv get secret/test
```

### Step 13: Decommission Old Cluster

Once you've verified the new cluster is working:

1. **Wait Period**: Keep old cluster running for 24-48 hours as fallback
2. **Remove from any automation**: Update CI/CD pipelines, scripts, etc.
3. **Terminate old nodes**: Shut down old Vault instances
4. **Clean up old resources**: Remove old infrastructure (ASG, EBS volumes, etc.)

```bash
# Final snapshot of old cluster before decommissioning (extra backup)
export VAULT_ADDR="https://old-vault.example.com"
vault operator raft snapshot save final-backup-$(date +%Y%m%d).snap
```

## Rollback Procedure

If issues are discovered after DNS cutover:

### Quick Rollback (DNS)

1. Point DNS back to old cluster
2. Verify old cluster is operational
3. Investigate issues with new cluster

### Data Rollback

If data was modified on new cluster that needs to be reverted:

```bash
# On new cluster - take snapshot of current state (for analysis)
vault operator raft snapshot save new-cluster-state.snap

# Restore original backup
vault operator raft snapshot restore -force backup-*.snap
```

## Post-Migration Tasks

### Update Applications

Applications using Vault should automatically reconnect. Verify:
- Token renewal is working
- Dynamic secret generation works
- Auth methods functioning

### Update Monitoring

- Point monitoring to new cluster
- Verify Vault logs are flowing to Splunk
- Update alerting thresholds if needed

### Document New Recovery Keys

- Store new recovery keys in secure location
- Update runbooks with new root token location
- Document new infrastructure details

### Schedule Regular Backups

```bash
# Add to cron or automation
vault operator raft snapshot save /backup/vault-$(date +%Y%m%d-%H%M%S).snap
```

## Troubleshooting

### Snapshot Restore Fails

```
Error: failed to restore snapshot: X
```

- Verify you're using `-force` flag
- Ensure new cluster is initialized and unsealed
- Check available disk space on new nodes

### Nodes Won't Join After Restore

The restored data contains the original cluster's Raft configuration. New nodes should still join via auto-join discovery:

```bash
# SSH to node and check logs
aws ssm start-session --target <instance-id>
sudo journalctl -u vault -f
```

### Auth Methods Not Working

If LDAP, OIDC, or other auth methods fail:
- Verify network connectivity from new VPC to auth backends
- Check security groups allow outbound connections
- Verify auth method configurations in Vault

### Performance Issues After Migration

- New instances may need warm-up time
- Check instance sizes match workload
- Monitor CloudWatch metrics for CPU/memory/disk

## Version Upgrade Research (1.9.0 → 1.21.4)

Our existing nonprod and prod clusters run Vault OSS 1.9.0. This section documents the
research done to validate a direct snapshot restore from 1.9.0 to 1.21.4 (a 12 minor
version jump).

### Approach: Direct Restore vs. Stepped Upgrade

Two strategies were evaluated:

- **Strategy A (chosen)**: Deploy new cluster at 1.21.4, restore 1.9.0 snapshot directly
- **Strategy B (fallback)**: Deploy at 1.9.0, restore snapshot, then rolling-update through
  intermediate versions (1.13 → 1.16 → 1.19)

Strategy A was chosen after researching every version's upgrade guide and Vault's internal
storage architecture. Strategy B remains as a fallback if Strategy A fails during
nonprod-test validation.

### Why Direct Restore Is Safe

**Vault's internal data store uses lazy, defensive migrations — not sequential numbered
migrations.** When Vault starts up (or restores a snapshot), each subsystem reads its
storage entries and upgrades them in-place if the format is older than expected. There is
no migration chain where migration N depends on the output of migration N-1.

From the official upgrade docs:
> "Vault does not make backward-compatibility guarantees for the Vault data store and the
> upgrade process may make changes to the data store."
>
> Vault "automatically handles most tasks when you unseal Vault after the upgrade."

Source: https://developer.hashicorp.com/vault/docs/upgrading

Key technical details:
- **BoltDB format**: Unchanged across all versions (same bbolt library)
- **Raft protocol version**: Unchanged
- **Snapshot format**: Raw FSM state dump — version-independent
- **Identity store**: Uses lazy migration on read (e.g., removes legacy `caseSensitivityKey`
  during initialization, not as a versioned migration step)
- **`-force` flag on restore**: Required because cluster IDs differ, not because of version
  differences

### Version-by-Version Breaking Changes Reviewed

Each version's upgrade guide was reviewed for anything that could affect a snapshot restore.
Sources: `https://developer.hashicorp.com/vault/docs/upgrading/upgrade-to-1.{10-19}.x`,
`https://developer.hashicorp.com/vault/docs/v1.20.x/updates/important-changes`,
`https://developer.hashicorp.com/vault/docs/updates/important-changes`

| Version | Breaking Change | Impact on Our Stack |
|---------|----------------|---------------------|
| **1.10** | Token prefix change: `s.` → `hvs.`, `b.` → `hvb.` | **None** — existing tokens remain valid, new tokens use new prefix |
| **1.10** | Default OIDC provider + `allow_all` assignment created | **None** — only affects Vault-as-OIDC-provider, not OIDC auth method (our Keycloak setup) |
| **1.10** | SSH CA default algorithm changed to `rsa-sha2-256` | **None** — we don't use SSH secrets engine |
| **1.10** | Etcd v2 API removed | **None** — we use Raft, not Etcd |
| **1.11** | PostgreSQL driver changed from `lib/pq` to `pgx` | **Low** — only affects `connection_url` params; verify database engine configs post-restore |
| **1.12** | Enterprise storage backend check at startup | **None** — we run OSS |
| **1.12** | Auto mutual TLS for plugins, no more lazy loading | **None** — transparent for builtin plugins |
| **1.13** | **Removed builtin plugins**: standalone DB engines (`mysql`, `postgresql`, `mssql`) and AppId auth | **None** — we use the unified `database` engine, not standalone. We don't use AppId. |
| **1.13** | Undo logs auto-enabled for Raft | **None** — transparent enhancement |
| **1.13** | User lockout enabled by default (5 attempts, 15min) | **Low** — new behavior, not a data issue |
| **1.14** | Raft storage metric type correction (summary → counter) | **None** — monitoring only |
| **1.15** | Consul service registration tags now case-sensitive | **None** — we don't use Consul |
| **1.15** | Mount-point-specific rollback metrics disabled by default | **None** — monitoring only |
| **1.16** | LDAP entity alias naming changed to use `userattr` | **None** — we don't use LDAP auth |
| **1.17** | Rekey operations require nonce within 10 minutes | **None** — behavioral, not data format |
| **1.18** | `request_limiter` config stanza removed | **None** — we don't use it |
| **1.18** | Docker image no longer includes `curl` | **None** — we install Vault binary directly, not via Docker |
| **1.19** | File audit devices cannot use executable permissions | **Check** — verify audit device file modes post-restore |
| **1.20** | `disable_mlock` must be explicitly set in config (no longer auto-defaulted) | **None** — already set `disable_mlock = true` in our userdata template |
| **1.20** | AWS auto-join dual-stack bug in 1.19.5–1.20.2, fixed in 1.20.3+ | **None** — not an issue for 1.21.4 |
| **1.20** | Upgrade guides moved to `/docs/v1.20.x/updates/important-changes` URL | **None** — informational |
| **1.21** | `allowed_parameters`/`denied_parameters` policy matching changed from whole-list to item-by-item | **Check** — audit ACL policies with list-valued parameters post-restore. Revert available via `VAULT_LEGACY_EXACT_MATCHING_ON_LIST` env var |

### Our Stack Compatibility

The existing clusters use the following, all confirmed safe across the version range:

| Component | Type | Compatibility |
|-----------|------|---------------|
| **Secrets engines** | `database` (unified), `kv`, `aws` | No breaking changes |
| **Auth methods** | `approle`, `aws`, `kubernetes`, `oidc` (Keycloak), `token` | No breaking changes |
| **Policies** | ACL policies | Check `allowed_parameters`/`denied_parameters` with list values (1.21 matching change) |
| **Storage** | Raft integrated storage | Format unchanged |
| **Seal** | KMS auto-unseal | Unchanged (seal config not in snapshot) |

### Vault Agent Compatibility

Current Kubernetes setup uses `vault-k8s:1.2.1` injector with `vault:1.14.0` agent sidecar
on nonprod and prod.

- Agent (1.14.0) is newer than the old server (1.9.0) — already working fine
- After migration, server (1.21.4) will be significantly newer than agent (1.14.0) — 7
  minor versions of skew. This is supported but not ideal.
- Per HashiCorp docs: "In most cases, Vault server upgrades are backwards compatible with
  older versions of Vault Agent." Agent logs informational messages on version mismatch.
- **Recommended**: After migration is stable, upgrade the Vault agent sidecar image to
  1.21.x to reduce version skew and pick up bug fixes.
- No Kubernetes-side changes are *required* for the migration to succeed — the older agent
  will continue to function against the newer server.
- Source: https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/versions

### Pre-Migration Version Audit

Before restoring, verify the existing cluster doesn't use any removed plugins:

```bash
export VAULT_ADDR="https://vault.nonprod.example.io"
export VAULT_TOKEN="<root-token>"

# Check secrets engine mount types — look for 'database' (good) vs 'mysql'/'postgresql' (bad)
vault secrets list -detailed -format=json | jq 'to_entries[] | {path: .key, type: .value.type}'

# Check auth method types — look for 'approle' (good) vs 'app-id' (bad)
vault auth list -detailed -format=json | jq 'to_entries[] | {path: .key, type: .value.type}'

# Check audit devices — note file modes
vault audit list -detailed
```

### Post-Restore Verification Checklist

After restoring a 1.9.0 snapshot to a 1.21.4 cluster:

```bash
# 1. Basic health
vault status

# 2. All secrets engines present
vault secrets list

# 3. All auth methods present
vault auth list

# 4. Policies intact
vault policy list

# 5. Database engine connections healthy
vault read database/config/<connection-name>

# 6. KV secrets accessible
vault kv get <path>

# 7. AppRole login works
vault write auth/approle/login role_id=<role-id> secret_id=<secret-id>

# 8. OIDC config present (Keycloak)
vault read auth/oidc/config

# 9. Kubernetes auth config present
vault read auth/kubernetes/config

# 10. AWS auth/secrets configs present
vault read auth/aws/config/client
vault read aws/config/root

# 11. Audit devices (check file modes - must not be executable on 1.19.7+)
vault audit list -detailed

# 12. ACL policies with allowed_parameters/denied_parameters (1.21 matching change)
# Review any policies that use list values in parameter constraints
vault policy list | xargs -I{} vault policy read {}
```

### Validation Plan

1. **nonprod-test first** — take snapshot from existing nonprod (1.9.0), restore to
   nonprod-test running 1.21.4. Run full verification checklist above.
2. If any issues, fall back to Strategy B (stepped upgrade through 1.13 → 1.16 → 1.19).
3. Once validated on nonprod-test, proceed with nonprod, then prod.

## Version Compatibility

Vault snapshots are forward-compatible but not backward-compatible. You can restore a
snapshot from an older version to a newer version, but not vice versa.

| Old Vault Version | New Vault Version | Snapshot Compatible | Notes |
|-------------------|-------------------|---------------------|-------|
| 1.9.x             | 1.21.x            | Yes                 | Validated for our stack (see research above) |
| 1.10.x - 1.20.x   | 1.21.x            | Yes                 | Smaller jump, lower risk |
| 1.21.x            | 1.21.x            | Yes                 | Same version, routine restore |

## Support

If you encounter issues during migration:

1. **Don't panic** — old cluster is still running until you decommission it
2. Check Vault logs on new nodes: `sudo journalctl -u vault -f`
3. Review security group rules
4. Verify IAM permissions
5. Check KMS key accessibility
6. For version-specific issues, consult the upgrade guide for the relevant version:
   `https://developer.hashicorp.com/vault/docs/upgrading/upgrade-to-1.XX.x`
