# Vault Monitoring

Prometheus metrics, CloudWatch EC2/NLB stats, and Grafana dashboard for the Vault cluster.

## Contents

| File | Description |
|------|-------------|
| `prometheus-scrape-config.yml` | Reference Prometheus scrape config with EC2 service discovery |
| `grafana-vault-dashboard.json` | Importable Grafana dashboard |

## Prerequisites

The Vault telemetry config (in userdata) enables the Prometheus metrics endpoint at `/v1/sys/metrics?format=prometheus`. A **rolling update** is required to apply this to running nodes:

```bash
VAULT_ENV=<env> ./scripts/rolling-update.sh
```

After the rolling update, verify the endpoint is working:

```bash
curl -sk https://<node-ip>:8200/v1/sys/metrics?format=prometheus | head -20
```

You should see `vault_*` metric lines.

## Prometheus Scrape Config

The scrape config uses EC2 service discovery to auto-discover Vault nodes by the `vault-cluster` tag. This handles dynamic IPs — when a node is replaced, Prometheus automatically finds the new instance.

### Placeholder values

Replace these in `prometheus-scrape-config.yml`:

| Placeholder | How to find |
|-------------|-------------|
| `<aws-region>` | `aws ssm get-parameter --name /<cluster>/config/vault-config --query Parameter.Value --output text \| jq -r .aws_region` or check your `terraform/environments/*.tfvars` |
| `<cluster-name>` | `aws ssm get-parameter --name /<cluster>/config/cluster-name --query Parameter.Value --output text` (e.g. `vault-nonprod-test`) |

### Adding to EKS Prometheus

If using the kube-prometheus-stack Helm chart, merge the scrape config into your `additionalScrapeConfigs`:

```yaml
# values.yaml
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: 'vault'
        # ... (paste contents from prometheus-scrape-config.yml)
```

If using Prometheus Operator with `ScrapeConfig` CRDs, adapt the YAML into that format.

### IAM

Prometheus needs `ec2:DescribeInstances` permission to use EC2 service discovery. This is configured on the Prometheus side (EKS IRSA or node role), not in this codebase.

## Grafana Dashboard

The dashboard uses two datasources: **Prometheus** (Vault application metrics) and **CloudWatch** (EC2 instance and NLB metrics).

### Prerequisites

1. A Prometheus datasource configured in Grafana (for Vault metrics)
2. A CloudWatch datasource configured in Grafana (for EC2/NLB metrics)
   - Requires IAM permissions: `ec2:DescribeInstances`, `cloudwatch:GetMetricData`, `cloudwatch:ListMetrics`
   - Typically configured via Grafana's built-in CloudWatch datasource with IRSA or instance role

### Import

1. Go to **Dashboards > Import**
2. Upload `grafana-vault-dashboard.json` or paste its contents
3. Click **Import**

### Template variables to configure after import

| Variable | Type | How to find the value |
|----------|------|-----------------------|
| Prometheus | Datasource | Select your Prometheus datasource |
| CloudWatch | Datasource | Select your CloudWatch datasource |
| AWS Region | Dropdown | Select your region (defaults to us-east-1) |
| NLB ARN Suffix | Query (auto) | Auto-populated from CloudWatch `AWS/NetworkELB` `LoadBalancer` dimensions |
| Target Group ARN Suffix | Query (auto) | Auto-populated from CloudWatch `AWS/NetworkELB` `TargetGroup` dimensions (filtered by selected NLB) |

The `cluster` and `instance` variables auto-populate from Prometheus.

### Dashboard layout

**Always visible — Health at a Glance (top row):**

8 traffic-light panels that go green/yellow/red. If the top row is all green, everything is healthy.

| Panel | Green | Yellow | Red |
|-------|-------|--------|-----|
| Sealed Nodes | 0 | — | >= 1 |
| Has Leader | OK | — | NO LEADER |
| Audit Failures | 0 | — | >= 1 |
| Request p99 | < 250ms | 250ms–1s | > 1s |
| Raft Commit | < 25ms | 25–500ms | > 500ms |
| Leader Changes | 0 | 1–2 | >= 3 |
| EC2 Status | 0 | — | >= 1 |
| NLB Healthy | 3 | 1–2 | 0 |

**Collapsed detail rows (click to expand for investigation):**

| Row | Source | Panels |
|-----|--------|--------|
| Node Status | Prometheus | Seal status per node, Vault version |
| EC2 Instances | CloudWatch | CPU utilization, network in/out, EBS read/write ops, status checks, CPU credit balance |
| NLB | CloudWatch | Healthy/unhealthy hosts, active/new flows, processed bytes, TCP resets, TLS errors |
| Request Performance | Prometheus | Request rate, latency percentiles (p50/p90/p99) |
| Storage (Raft) | Prometheus | Commit time, leadership changes, FSM apply latency |
| Tokens & Leases | Prometheus | Token count, creation rate, lease count, revocation rate |
| Barrier & Audit | Prometheus | Barrier ops rate, audit log duration, audit failures |
| Runtime | Prometheus | Memory usage, GC pause rate, goroutines |
| Auto-Unseal (KMS) | Prometheus | KMS encrypt/decrypt rate, operation latency |

## Alerting Rules

Ready-to-deploy Prometheus alert rules live in
[`alerts/vault-alerts.yml`](alerts/vault-alerts.yml). 16 rules across 6 groups:

| Group | Rules |
|---|---|
| vault-availability | VaultSealed, VaultNoLeader, VaultScrapeTargetDown, VaultQuorumDegraded |
| vault-raft | VaultLeadershipChurn, VaultRaftCommitSlow, VaultRaftApplyLag |
| vault-audit | VaultAuditLogFailures |
| vault-backups | VaultBackupSkipped24h, VaultBackupNoSuccess8h, VaultBackupValidationFailed, VaultBackupSnapshotStale |
| vault-storage | VaultRaftDiskFilling, VaultRaftDiskCritical, VaultAuditDiskFilling |
| vault-tls | VaultCertExpiringSoon (optional — requires blackbox_exporter) |

Load via Prometheus config:

```yaml
rule_files:
  - /etc/prometheus/rules/vault-alerts.yml
```

Validate changes before shipping:

```bash
promtool check rules monitoring/alerts/vault-alerts.yml
```

Thresholds are starting points — tune based on observed baseline after a
week of operation. Runbook links in the `annotations.runbook` field point
at `docs/troubleshooting.md`, `docs/backups.md`, `docs/operations.md`.
