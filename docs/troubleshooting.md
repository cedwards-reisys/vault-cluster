# Vault Cluster Troubleshooting with SSM

Guide to debugging Vault cluster issues using AWS Systems Manager Session Manager. No SSH keys or bastion hosts required.

## Prerequisites

- AWS CLI with SSM plugin installed
- IAM permissions for `ssm:StartSession`, `ssm:SendCommand`, `ssm:GetCommandInvocation`
- Instance must have SSM agent running (default on Amazon Linux 2023)

## Connecting to a Node

### Interactive Session

```bash
aws ssm start-session --target <instance-id> --region us-east-2
```

### Run a Single Command (non-interactive)

```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["<your-command>"]}' \
  --instance-ids <instance-id> \
  --region us-east-2

# Get the output (use CommandId from above)
aws ssm get-command-invocation \
  --command-id <command-id> \
  --instance-id <instance-id> \
  --region us-east-2
```

### Run a Command on Multiple Nodes

```bash
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["<your-command>"]}' \
  --instance-ids <id-1> <id-2> <id-3> \
  --region us-east-2
```

## Finding Instance IDs

```bash
# All running Vault instances for a cluster
aws ec2 describe-instances \
  --region us-east-2 \
  --filters \
    "Name=tag:vault-cluster,Values=vault-nonprod-test" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,Placement.AvailabilityZone]' \
  --output table
```

## Vault Service Status

```bash
# Is Vault running?
systemctl status vault

# Recent Vault logs
journalctl -u vault --no-pager -n 100

# Follow logs in real time
journalctl -u vault -f

# Logs since last boot
journalctl -u vault -b --no-pager
```

## Vault Health (from the node itself)

```bash
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/ca.crt"

# Health check (no auth required)
# 200 = active leader, 429 = standby, 472 = DR standby, 473 = perf standby
# 501 = not initialized, 503 = sealed
curl -sk https://127.0.0.1:8200/v1/sys/health
curl -sk -o /dev/null -w "%{http_code}" https://127.0.0.1:8200/v1/sys/health

# Seal status
vault status

# Raft peers (requires VAULT_TOKEN)
vault operator raft list-peers
```

## Raft Debugging

### Check Raft Data Directory

```bash
# What's on disk?
ls -la /opt/vault/data/

# Raft subdirectory
ls -la /opt/vault/data/raft/ 2>/dev/null

# Check for peers.json override file
cat /opt/vault/data/raft/peers.json 2>/dev/null

# Disk usage
du -sh /opt/vault/data/
```

### Raft Peer Issues

```bash
# View current peers
vault operator raft list-peers -format=json | jq '.data.config.servers[]'

# Check which node is leader
vault operator raft list-peers -format=json | \
  jq -r '.data.config.servers[] | select(.leader == true) | .node_id'
```

### Stale Raft State

If a node is trying to contact old IPs (visible in logs as "failed to make requestVote"):

```bash
# Check what Vault thinks its identity is
journalctl -u vault --no-pager | grep -i "node_id\|raft\|join\|leader\|vote" | tail -30

# Nuclear option: wipe Raft data so node rejoins fresh
# ONLY do this on followers, NEVER on the recovery/leader node
systemctl stop vault && rm -rf /opt/vault/data/* && systemctl start vault
```

## Vault Configuration

```bash
# View the running config
cat /opt/vault/config/vault.hcl

# Check node_id, cluster_addr, api_addr
grep -E "node_id|cluster_addr|api_addr" /opt/vault/config/vault.hcl

# Verify auto_join tag settings
grep -A5 "retry_join" /opt/vault/config/vault.hcl
```

## TLS Certificate Debugging

```bash
# Check cert details
openssl x509 -in /opt/vault/tls/node.crt -text -noout | head -20

# Check SANs (should include node's private IP and vault domain)
openssl x509 -in /opt/vault/tls/node.crt -text -noout | grep -A1 "Subject Alternative"

# Check cert expiry
openssl x509 -in /opt/vault/tls/node.crt -enddate -noout

# Verify cert chain
openssl verify -CAfile /opt/vault/tls/ca.crt /opt/vault/tls/node.crt

# Test TLS connection locally
openssl s_client -connect 127.0.0.1:8200 -CAfile /opt/vault/tls/ca.crt </dev/null 2>/dev/null | head -10
```

## EBS Volume

```bash
# Check data mount
df -h /opt/vault/data
mount | grep vault

# Check if volume is attached
lsblk

# Verify fstab entry
grep vault /etc/fstab
```

## Backup Timer

```bash
# Timer status
systemctl status vault-backup.timer
systemctl list-timers vault-backup*

# Last backup run
journalctl -u vault-backup.service --no-pager -n 30

# Manually trigger backup
systemctl start vault-backup.service
journalctl -u vault-backup.service -f
```

## Auto-Join Discovery

If a node can't find peers via auto_join:

```bash
# Check if EC2 tags are present (auto_join uses these)
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/vault-cluster

# Check if this node can see other cluster members
aws ec2 describe-instances \
  --region us-east-2 \
  --filters "Name=tag:vault-cluster,Values=$(cat /opt/vault/config/vault.hcl | grep tag_value | awk -F'"' '{print $2}')" \
  --query 'Reservations[].Instances[].PrivateIpAddress' \
  --output text

# Check connectivity to other nodes on port 8200/8201
for ip in <peer-ip-1> <peer-ip-2>; do
  echo -n "$ip:8200 → "; timeout 2 bash -c "echo | openssl s_client -connect $ip:8200 2>/dev/null | head -1" || echo "UNREACHABLE"
  echo -n "$ip:8201 → "; timeout 2 bash -c "echo | openssl s_client -connect $ip:8201 2>/dev/null | head -1" || echo "UNREACHABLE"
done
```

## Userdata / Boot Issues

```bash
# Userdata execution log
cat /var/log/vault-setup.log

# Cloud-init logs (if userdata didn't run at all)
cat /var/log/cloud-init-output.log | tail -100
```

## KMS Auto-Unseal

```bash
# Check if Vault can reach KMS
aws kms describe-key --key-id $(grep kms_key_id /opt/vault/config/vault.hcl | awk -F'"' '{print $2}') --region us-east-2

# Check seal status and type
vault status -format=json | jq '{type: .type, sealed: .sealed, initialized: .initialized}'
```

## NLB Target Group Health

From your local machine (not the node):

```bash
# Check which nodes the NLB considers healthy
aws elbv2 describe-target-health \
  --target-group-arn <target-group-arn> \
  --region us-east-2 \
  --output table
```

With leader-only health checks (`/v1/sys/health`, matcher `200`), only the active leader shows as healthy. Standby nodes show unhealthy — this is expected.

## Multi-AZ Loss (regional degradation)

Two of three AZs become unreachable simultaneously (regional outage, VPC /
subnet misconfiguration, transit gateway failure). One node survives but
has no quorum — Raft goes read-only / leaderless.

**Persistent EBS implication:** the data in the lost AZs is still on disk
(EBS volumes survive AZ outages as long as the AZ comes back). But until the
other AZs return, the surviving node can't form quorum with itself.

Triage:

1. Confirm it's AZ-level, not instance-level:
   ```bash
   aws ec2 describe-availability-zones --region <region> \
     --query 'AvailabilityZones[].[ZoneName,State]' --output table
   ```

2. Check the surviving node:
   ```bash
   ./scripts/cluster-status.sh <env>
   # Expect: 1 running instance, 3 peers in Raft config (two unreachable)
   ```

3. **DO NOT** run `cold-start-cluster.sh` while the AZs are merely
   unreachable — that wipes stale Raft on the two "recovered" nodes when
   they return and converts the cluster to single-node-bootstrap mode.
   Destructive.

Recovery paths:

- **If AZs are expected to return within RPO/RTO window:** wait. The
  surviving node holds Raft state. When the other two AZs come back, their
  instances will auto-start (or can be launched via `launch-node.sh`), and
  Raft will re-form quorum automatically.

- **If AZs are declared lost (weeks+, or permanent):** treat as cluster
  rebuild. Take a snapshot from the surviving node if possible (works
  without quorum — `vault operator raft snapshot save`), then follow the
  break-glass rebuild procedure in `docs/dr-lost-recovery-keys.md`.

- **If the surviving node is ALSO lost:** worst case. Fall back to the
  latest S3 snapshot and rebuild from scratch.

## Common Failure Patterns

| Symptom | Likely Cause | Debug Command |
|---------|-------------|---------------|
| All nodes standby, no leader | Stale Raft peer data | `journalctl -u vault` — look for "requestVote" failures |
| Node sealed after replacement | KMS permissions or key issue | `vault status` + check IAM role |
| Node can't join cluster | TLS cert mismatch or SG blocking 8201 | Check certs + test connectivity |
| Backup timer never fires | Backup not enabled in tfvars or node not replaced after enabling | `systemctl list-timers vault-backup*` |
| Node healthy locally but NLB says unhealthy | Node is standby (expected with leader-only health check) | `curl -sk https://127.0.0.1:8200/v1/sys/health` — check for 429 |
| "unsupported field" in Vault logs | Config field moved between Vault versions | Check `journalctl -u vault` for the specific field |
| All nodes deleted, node 0 stuck (no leader, unsealed) | Single node can't achieve quorum against old 3-node Raft membership | `./cold-start-cluster.sh <env> --yes` |
| Userdata aborts with "EBS volume identity mismatch" | Volume's `.vault-node-id` sentinel doesn't match current cluster/AZ (often: restored snapshot, mis-tagged volume) | See the error message — lists exact wipe steps for intentional reassignment |
| Rolling update halted "canary check failed" | The new instance launched but failed 1 of 6 health checks before the canary timeout | Check `aws ssm start-session` + `journalctl -u vault` on the instance — diagnose BEFORE retrying to avoid cascading failure |
| Rolling update interrupted (Jenkins killed, Ctrl+C) | Partial state — one AZ missing its instance | See "Resume After Interrupted Rolling Update" in `docs/rolling-updates.md` |
| Only one AZ surviving, cluster leaderless | Multi-AZ loss (regional outage) | See "Multi-AZ Loss" section above — do NOT run cold-start |
