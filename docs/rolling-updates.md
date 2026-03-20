# Rolling Updates Runbook

This document describes the process for performing rolling updates on the Vault cluster (AMI updates, Vault version upgrades, configuration changes).

## Overview

The Vault cluster uses script-based node management with persistent EBS volumes. This enables safe rolling updates without data loss.

### Key Concepts

- **Persistent EBS Volumes**: Each AZ has a dedicated EBS volume that survives instance replacement
- **Stable Node IDs**: Node IDs are AZ-based (`cluster-us-east-1a`), not instance-based
- **No Raft Membership Changes**: When a node is replaced, it rejoins with the same identity
- **One Node at a Time**: Scripts ensure only one node is updated at a time

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Vault Cluster                               │
├─────────────────────┬─────────────────────┬─────────────────────────┤
│      AZ-a           │      AZ-b           │       AZ-c              │
│   ┌─────────┐       │   ┌─────────┐       │   ┌─────────┐           │
│   │ EC2     │       │   │ EC2     │       │   │ EC2     │           │
│   │ Instance│       │   │ Instance│       │   │ Instance│           │
│   └────┬────┘       │   └────┬────┘       │   └────┬────┘           │
│        │            │        │            │        │                │
│   ┌────▼────┐       │   ┌────▼────┐       │   ┌────▼────┐           │
│   │ EBS Vol │       │   │ EBS Vol │       │   │ EBS Vol │           │
│   │ (Raft)  │       │   │ (Raft)  │       │   │ (Raft)  │           │
│   └─────────┘       │   └─────────┘       │   └─────────┘           │
├─────────────────────┼─────────────────────┼─────────────────────────┤
│  1. Update this     │  2. Then this       │  3. Finally this        │
│     first           │     (after AZ-a     │     (after AZ-b         │
│                     │      healthy)       │      healthy)           │
└─────────────────────┴─────────────────────┴─────────────────────────┘
```

## Prerequisites

Before starting:

1. **Verify cluster is healthy**:
   ```bash
   ./scripts/cluster-status.sh
   vault operator raft list-peers
   ```

2. **Ensure you have**:
   - AWS CLI configured
   - `VAULT_ADDR` and `VAULT_TOKEN` set
   - Sufficient IAM permissions for EC2 operations

3. **Schedule maintenance window** (updates take ~15-20 minutes total)

## Update Methods

### Method 1: Automated Script (Recommended)

Use the provided script for fully automated rolling updates:

```bash
export VAULT_ADDR="https://vault.example.com"
export VAULT_TOKEN="<your-token>"

./scripts/rolling-update.sh
```

The script will:
1. Verify cluster health (requires 2+ Raft peers)
2. Run `tofu apply` to update infrastructure/userdata
3. For each node (followers first, leader last):
   - Terminate the instance (EBS preserved)
   - Launch replacement instance
   - Wait for node to rejoin and cluster to stabilize
4. Verify final cluster health

#### Skip Terraform (Config-Only Update)

If you only need to replace instances without Terraform changes:

```bash
./scripts/rolling-update.sh --skip-terraform
```

### Method 2: Manual Node-by-Node

For more control, update nodes manually:

```bash
# List current instances
aws ec2 describe-instances \
  --filters "Name=tag:vault-cluster,Values=<cluster-name>" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`vault-az`].Value|[0]]' \
  --output table

# Update Terraform (if needed)
tofu apply

# For each node (one at a time):
./scripts/terminate-node.sh <instance-id>
./scripts/launch-node.sh <az-index>  # 0, 1, or 2

# Wait and verify before proceeding to next node
./scripts/cluster-status.sh
vault operator raft list-peers
```

## Common Update Scenarios

### Vault Version Upgrade

1. Edit `terraform/environments/<env>.tfvars`:
   ```hcl
   vault_version = "1.19.0"  # New version
   ```

2. Run the rolling update:
   ```bash
   ./scripts/rolling-update.sh
   ```

### AMI Update (OS Patches)

The AMI data source automatically fetches the latest Amazon Linux 2023 AMI. Simply run:

```bash
./scripts/rolling-update.sh
```

If no Terraform changes are detected but you want to refresh instances anyway:
```bash
./scripts/rolling-update.sh --skip-terraform
```

### Configuration Changes

For changes to Vault configuration (in `userdata.sh.tpl`):

1. Make your changes to the template
2. Run `tofu apply` to regenerate userdata
3. Run the rolling update:
   ```bash
   ./scripts/rolling-update.sh --skip-terraform
   ```

## What Happens During Update

### For Each Node:

1. **Instance Termination**
   - Script calls `terminate-node.sh`
   - Instance deregistered from NLB target group
   - EBS volume detached (data preserved)
   - Instance terminated
   - Raft cluster sees node as "down" (not removed)

2. **New Instance Launch**
   - Script calls `launch-node.sh`
   - New EC2 instance launched in same AZ
   - Same EBS volume attached
   - Userdata runs:
     - Installs Vault (new version if upgraded)
     - Mounts EBS volume to `/opt/vault/data`
     - Retrieves CA cert from Secrets Manager
     - Generates node certificate
     - Starts Vault with same node_id

3. **Cluster Rejoin**
   - Vault reads existing Raft data from EBS
   - Node reconnects to cluster with same identity
   - No Raft membership changes needed
   - Data automatically syncs if behind

4. **Health Verification**
   - Instance registered with NLB
   - Health check passes
   - Script verifies Raft peer count

### Timeline per Node:

| Phase | Duration |
|-------|----------|
| Instance termination | ~30 seconds |
| EBS detach | ~10 seconds |
| New instance launch | ~60 seconds |
| EBS attach | ~10 seconds |
| Userdata execution | ~90 seconds |
| Vault startup + Raft rejoin | ~60 seconds |
| Health check passes | ~30 seconds |
| **Total per node** | **~5 minutes** |

## Rollback

### Node Won't Rejoin

If a new node fails to rejoin the cluster:

1. Check instance logs:
   ```bash
   aws ssm start-session --target <new-instance-id>
   sudo cat /var/log/vault-setup.log
   sudo journalctl -u vault
   ```

2. Common issues:
   - EBS volume not attached → check `lsblk`
   - Certificate issues → check `/opt/vault/tls/`
   - Raft data corruption → may need to remove from Raft and start fresh

3. If unfixable, terminate and try again:
   ```bash
   ./scripts/terminate-node.sh <instance-id>
   ./scripts/launch-node.sh <az-index>
   ```

### Cluster Loses Quorum

This should not happen if updating one node at a time. If it does:

1. **Do not terminate any more nodes**
2. Check remaining nodes:
   ```bash
   vault operator raft list-peers
   ```
3. If 2+ nodes are healthy, wait for the updating node to join
4. If only 1 node healthy, recover from snapshot:
   ```bash
   vault operator raft snapshot restore backup.snap
   ```

### Revert to Previous Vault Version

If the new Vault version has issues:

1. Edit `terraform/environments/<env>.tfvars` back to previous version:
   ```hcl
   vault_version = "1.18.3"  # Previous working version
   ```

2. Run `tofu apply`

3. Run rolling update:
   ```bash
   ./scripts/rolling-update.sh --skip-terraform
   ```

### Reset a Corrupted Node

If a node has corrupted Raft data and can't rejoin:

```bash
# Remove from Raft cluster (permanent removal)
./scripts/terminate-node.sh <instance-id> --remove-from-raft

# The EBS volume still has corrupted data, so we need to clear it
# Option 1: Delete and recreate the EBS volume via Terraform
# Option 2: Launch instance, SSH in, and wipe /opt/vault/data

# Launch fresh node (will join as new peer)
./scripts/launch-node.sh <az-index>
```

## Automation with CI/CD

### GitHub Actions Example

```yaml
name: Vault Rolling Update

on:
  schedule:
    - cron: '0 6 1 * *'  # First day of month at 6 AM UTC
  workflow_dispatch:      # Allow manual trigger

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup OpenTofu
        uses: opentofu/setup-opentofu@v1

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-actions-vault
          aws-region: us-east-1

      - name: Rolling Update
        working-directory: vault-cluster
        env:
          VAULT_ADDR: ${{ secrets.VAULT_ADDR }}
          VAULT_TOKEN: ${{ secrets.VAULT_TOKEN }}
        run: |
          cd terraform
          tofu init
          cd ..
          ./scripts/rolling-update.sh
```

### Jenkins Pipeline Example

```groovy
pipeline {
    agent any

    triggers {
        cron('0 6 1 * *')  // First day of month
    }

    environment {
        AWS_REGION = 'us-east-1'
        VAULT_ADDR = credentials('vault-addr')
    }

    stages {
        stage('Rolling Update') {
            steps {
                withCredentials([string(credentialsId: 'vault-token', variable: 'VAULT_TOKEN')]) {
                    dir('vault-cluster') {
                        dir('terraform') {
                            sh 'tofu init'
                        }
                        sh './scripts/rolling-update.sh'
                    }
                }
            }
        }
    }

    post {
        failure {
            slackSend channel: '#platform-alerts',
                      message: "Vault rolling update failed: ${env.BUILD_URL}"
        }
    }
}
```

## Monitoring During Updates

### CloudWatch Metrics to Watch

- `HealthyHostCount` on target group (should stay ≥2)
- `UnHealthyHostCount` on target group
- Custom Vault metrics if configured

### Alerts to Temporarily Silence

Consider silencing these during maintenance window:
- Vault node count alerts
- Health check failure alerts

## Checklist

```
Pre-Update:
[ ] Verify cluster health (./scripts/cluster-status.sh)
[ ] Verify all 3 Raft peers are voters
[ ] Create Raft snapshot backup
[ ] Notify stakeholders of maintenance window
[ ] Ensure VAULT_TOKEN with operator permissions

Update:
[ ] Run ./scripts/rolling-update.sh
[ ] Monitor progress in terminal output
[ ] Verify 3 Raft peers after completion

Post-Update:
[ ] Final health check
[ ] Verify Vault UI accessible
[ ] Test a secret read/write
[ ] Check Vault version: vault status
[ ] Document completion
```

## Script Reference

### launch-node.sh

```bash
# Interactive
./scripts/launch-node.sh <az-index>

# Non-interactive (for automation)
./scripts/launch-node.sh <az-index> --yes
```

### terminate-node.sh

```bash
# Interactive (preserves Raft membership for replacement)
./scripts/terminate-node.sh <instance-id>

# Non-interactive
./scripts/terminate-node.sh <instance-id> --yes

# Permanent removal (removes from Raft)
./scripts/terminate-node.sh <instance-id> --remove-from-raft --yes
```

### rolling-update.sh

```bash
# Full update (Terraform + node replacement)
./scripts/rolling-update.sh

# Skip Terraform (node replacement only)
./scripts/rolling-update.sh --skip-terraform
```

### cluster-status.sh

```bash
# Auto-detect Vault address from Terraform
./scripts/cluster-status.sh

# Explicit address
./scripts/cluster-status.sh https://vault.example.com

# With Raft details (requires VAULT_TOKEN)
export VAULT_TOKEN="..."
./scripts/cluster-status.sh
```
