# Vault Backup and Recovery

How automated backups work, how to verify them, and how to restore from them.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  Vault Node (systemd timer, every 6h)                   │
│                                                         │
│  1. Am I the leader? ──no──> exit (standby nodes skip)  │
│              │                                          │
│             yes                                         │
│              │                                          │
│  2. vault login -method=aws role=backup                 │
│              │                                          │
│  3. vault operator raft snapshot save                   │
│              │                                          │
│  4. aws s3 cp → s3://<bucket>/<cluster>/daily/          │
│              │                                          │
│  5. If Sunday → also copy to weekly/                    │
│              │                                          │
│  6. Revoke token, clean up temp file                    │
└─────────────────────────────────────────────────────────┘
```

- **Only the active leader** takes backups. The timer fires on all nodes but standbys exit immediately.
- Authentication uses **AWS IAM auth** — the backup script gets a short-lived token scoped to the `backup` role. No long-lived credentials on disk.
- Snapshots are Raft snapshots — they contain all Vault data: secrets, policies, auth methods, entities, tokens, audit configuration.
- Snapshots do **not** contain: Vault config (`vault.hcl`), TLS certs, KMS auto-unseal config.

## S3 Bucket Structure

Each environment gets its own bucket:

| Environment | Bucket |
|-------------|--------|
| nonprod-test | `vault-nonprod-test-backups` |
| nonprod | `vault-nonprod-backups` |
| prod | `vault-prod-backups` |

```
s3://<bucket>/
  <cluster-name>/
    daily/vault-snapshot-20260429-060000.snap
    daily/vault-snapshot-20260429-120000.snap
    daily/vault-snapshot-20260429-180000.snap
    daily/...
    weekly/vault-snapshot-20260427-060000.snap    (Sundays only)
    weekly/...
    sync/nonprod-sync-20260415-140000.snap        (cross-env syncs)
```

## Lifecycle and Retention

| Prefix | Storage class | Transition | Expiration |
|--------|--------------|------------|------------|
| `daily/` | Standard | Standard-IA at 30 days | Configurable (default 90 days, prod overrides via `backup_retention_days`) |
| `weekly/` | Standard | Glacier at 60 days | 365 days |
| `sync/` | Standard | — | 30 days |

S3 versioning is enabled. Bucket has public access blocked and AES256 server-side encryption.

## Schedule

- **Frequency**: Every 6 hours (`OnCalendar=*-*-* 00/6:00:00`)
- **Jitter**: Up to 15 minutes random delay (`RandomizedDelaySec=900`) to avoid thundering-herd across environments
- **Weekly**: Sunday backups (`date -u +%u == 7`) are copied to both `daily/` and `weekly/` prefixes
- **Timer persistence**: `Persistent=true` — if the node was down when a timer would have fired, systemd catches up on next boot

## Verifying Backups

### On the leader node (via SSM)

```bash
aws ssm start-session --target <instance-id> --region us-east-2

# Timer status
systemctl status vault-backup.timer
systemctl list-timers vault-backup*

# Last run output
journalctl -u vault-backup.service --no-pager -n 50

# Manually trigger a backup
systemctl start vault-backup.service
journalctl -u vault-backup.service -f
```

### From operator machine

```bash
# List recent daily snapshots
aws s3 ls s3://vault-nonprod-backups/vault-nonprod/daily/ --recursive | sort -r | head -10

# List weekly snapshots
aws s3 ls s3://vault-nonprod-backups/vault-nonprod/weekly/ --recursive | sort -r | head -5

# Check snapshot file size (should be non-trivial, not 0 bytes)
aws s3 ls s3://vault-prod-backups/vault-prod/daily/ --recursive | sort -r | head -1
```

## Daily Validation

`scripts/validate-backup.sh` downloads the newest daily snapshot from S3 and
runs `vault operator raft snapshot inspect` locally. It does NOT talk to a
running Vault and does NOT require a token.

What it catches:
- Corrupted / truncated / HTML-error-page-masquerading-as-snapshot
- Missing snapshots (backup timer broken)
- Stale snapshots (older than `MAX_AGE_HOURS`, default 8)
- Suspiciously small snapshots (smaller than `MIN_SIZE_BYTES`, default 10KB)
- Empty snapshots (Raft Index == 0)

What it does NOT catch:
- Vault version incompatibility on restore
- KMS / seal-type mismatch
- Logical data corruption (valid bytes, wrong contents)

For those, a full restore drill remains the only authoritative check. See
"Cross-cluster restore" below for the closest thing we have today.

### Running manually

```bash
./scripts/validate-backup.sh nonprod-test

# With tuned thresholds:
MAX_AGE_HOURS=12 MIN_SIZE_BYTES=50000 ./scripts/validate-backup.sh nonprod-test
```

Exit codes: `0` = pass, `1` = validation failed (reasons logged), `2` = preflight error.

### Jenkins pipeline

`jenkins/pipelines/validate-backup.Jenkinsfile` runs the script daily at
**07:15 UTC** (one hour after the 06:00 UTC backup window — gives the 15-minute
systemd timer jitter plenty of slack).

Today: **nonprod-test only** (day-one scope per C5 decision). Extend to
nonprod / prod by adding equivalent jobs in those folders.

### CloudWatch metrics

Emitted under namespace `Vault/BackupValidation`, dimensions `Cluster=<name>`,
`Environment=<env>`:

| Metric | Unit | Meaning |
|---|---|---|
| `Success` | Count | 1 on pass, 0 on fail |
| `Failure` | Count | 1 on fail, 0 on pass |
| `AgeHours` | None | Snapshot age at time of check |
| `SizeBytes` | Bytes | Snapshot byte size |
| `NoSnapshotsFound` | Count | Emitted when bucket is empty |
| `DownloadFailure` | Count | Emitted when `s3 cp` fails |

No paging configured on day-one (per C5 decision). Add an alarm on
`Sum(Failure) > 0 over 24h` once enough baseline data is available.

## Manual Backup

Take a snapshot anytime from an operator machine — no dependency on the systemd timer:

```bash
export VAULT_ADDR="https://vault.nonprod.example.io"
export VAULT_TOKEN="<root-or-operator-token>"

vault operator raft snapshot save vault-backup-$(date +%Y%m%d-%H%M%S).snap

# Optionally upload to S3
aws s3 cp vault-backup-*.snap s3://vault-nonprod-backups/vault-nonprod/daily/
```

## Restore Procedures

### Same-cluster restore (e.g., undo a bad change)

Restores a snapshot to the same cluster it came from.

```bash
export VAULT_ADDR="https://vault.nonprod.example.io"
export VAULT_TOKEN="<root-token>"

# Interactive — lists available snapshots and prompts for selection
./scripts/restore-snapshot.sh nonprod

# Direct — if you already know the S3 key
./scripts/restore-snapshot.sh nonprod \
  vault-nonprod/daily/vault-snapshot-20260429-060000.snap
```

The script will:
1. Read the backup bucket from `terraform/environments/<env>.tfvars`
2. Download the snapshot from S3
3. Require you to type `RESTORE` to confirm
4. Run `vault operator raft snapshot restore -force`
5. Verify Vault status

### Cross-cluster restore (e.g., sync nonprod to nonprod-test)

Use the dedicated sync script for nonprod → nonprod-test:

```bash
export VAULT_NONPROD_ADDR="https://vault.nonprod.example.io"
export VAULT_NONPROD_TOKEN="<nonprod-root-token>"
export VAULT_TEST_ADDR="https://vault.nonprod-test.example.io"
export VAULT_TEST_TOKEN="<nonprod-test-root-token>"

./scripts/sync-to-nonprod-test.sh

# Non-interactive (CI/CD)
./scripts/sync-to-nonprod-test.sh --yes
```

For arbitrary cross-cluster restores (e.g., restoring a prod backup to nonprod):

```bash
# 1. Download from the source bucket
aws s3 cp s3://vault-prod-backups/vault-prod/daily/vault-snapshot-20260429-060000.snap /tmp/restore.snap

# 2. Restore to the target cluster
export VAULT_ADDR="https://vault.nonprod.example.io"
export VAULT_TOKEN="<nonprod-root-token>"
vault operator raft snapshot restore -force /tmp/restore.snap

# 3. Clean up
rm /tmp/restore.snap
```

### Disaster recovery — cluster rebuilt from scratch

If all nodes are destroyed and new infrastructure is provisioned:

1. **Launch the cluster** using `cold-start-cluster.sh` or `launch-node.sh` for each node
2. **Initialize Vault** if the EBS volumes are fresh: `vault operator init`
3. **Restore the snapshot** once a leader is active:

```bash
export VAULT_ADDR="https://vault.nonprod.example.io"
export VAULT_TOKEN="<root-token>"

./scripts/restore-snapshot.sh nonprod \
  vault-nonprod/daily/vault-snapshot-20260429-060000.snap
```

4. **Verify** cluster health:

```bash
./scripts/cluster-status.sh nonprod
```

### Disaster recovery — nodes deleted but EBS volumes preserved

This is the most common recovery scenario. Persistent EBS volumes still have Raft data, but the single node can't achieve quorum against the old 3-node membership.

```bash
# Automated: launches node 0, fixes quorum, launches remaining nodes
./scripts/cold-start-cluster.sh nonprod --yes

# If the Raft data on the EBS is corrupted or you want to restore from S3 instead:
# 1. Launch node 0 and let cold-start-cluster.sh get it to leader state
# 2. Restore from backup over the existing data:
./scripts/restore-snapshot.sh nonprod \
  vault-nonprod/daily/vault-snapshot-20260429-060000.snap
```

## Post-Restore Effects

| What | Effect |
|------|--------|
| Secrets, policies, auth methods, entities | Replaced with snapshot contents |
| Active tokens from before restore | Revoked (snapshot has its own token state) |
| Root token | Source cluster's root token is now valid |
| KMS auto-unseal | Not affected (lives in `vault.hcl`, not snapshot data) |
| TLS certificates | Not affected (lives on disk, not snapshot data) |
| Raft peer membership | Overwritten — other nodes rejoin automatically via `auto_join` |
| Audit devices | Restored from snapshot — verify log paths exist on new nodes |
| Backup systemd timer | Not affected (configured by userdata, not snapshot) |

## IAM Auth Setup for Backups

Backup automation requires a one-time Vault-side configuration per cluster. This is documented in [operations.md](operations.md#backup-iam-auth-setup).

In summary:
1. Enable the AWS auth method: `vault auth enable aws`
2. Create a `backup` policy granting `["read"]` on `sys/storage/raft/snapshot`
3. Create a `backup` role bound to the Vault node IAM role ARN
4. The backup script calls `vault login -method=aws role=backup` to authenticate

## Infrastructure (Terraform)

Backup resources are conditionally created when `backup_enabled = true`:

```hcl
# terraform/environments/<env>.tfvars
backup_enabled       = true
backup_s3_bucket     = "vault-nonprod-backups"
backup_retention_days = 90    # optional, defaults to 90
```

This creates:
- S3 bucket with versioning, encryption, public access block, and lifecycle rules
- IAM policy attached to the Vault node role granting `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`

The systemd timer and backup script are baked into the node userdata template and deployed when nodes are launched or rolled.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Timer exists but backup never runs | Node is standby (expected — only leader backs up) | Verify on the leader node instead |
| `Failed to authenticate via AWS IAM auth` | IAM auth method not configured in Vault | Run the one-time IAM auth setup in [operations.md](operations.md#backup-iam-auth-setup) |
| Backup succeeds but S3 is empty | Wrong bucket name in userdata | Check `backup_s3_bucket` in tfvars, re-roll nodes |
| `systemctl status vault-backup.timer` shows no timer | `backup_enabled = false` when node was launched | Set to `true`, run `tofu apply`, then roll the node |
| Snapshot file is 0 bytes | Vault token lacks snapshot permissions | Verify the `backup` policy grants `sys/storage/raft/snapshot` |
| Restore fails with "snapshot has no data" | Corrupted download or empty file | Re-download from S3, check file size before restoring |
| After restore, can't authenticate | Old tokens are invalidated by restore | Use the root token from the source cluster |
