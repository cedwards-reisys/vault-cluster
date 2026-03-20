# Jenkins Pipeline Setup

This document covers setting up Jenkins to manage the Vault cluster across all environments.

## Prerequisites

### Jenkins Plugins Required

- **Job DSL** — for the seed job that creates all pipeline jobs
- **Pipeline** — for Jenkinsfile-based pipelines
- **Credentials Binding** — for injecting secrets
- **AWS Credentials** — for `AmazonWebServicesCredentialsBinding`
- **AnsiColor** — for colored terminal output
- **Timestamps** — for build log timestamps
- **Nested View** — for the top-level "Vault Cluster" view with sub-tabs
- **Dashboard View** — for the single-page dashboard overview (optional but recommended)

### Jenkins Credentials to Configure

Create these credentials in Jenkins before running the seed job:

| Credential ID | Type | Description |
|---------------|------|-------------|
| `aws-nonprod` | AWS Credentials | AWS access key for the nonprod account |
| `aws-prod` | AWS Credentials | AWS access key for the prod account |
| `vault-nonprod-test-token` | Secret text | Vault root token for nonprod-test |
| `vault-nonprod-token` | Secret text | Vault root token for nonprod |
| `vault-prod-token` | Secret text | Vault root token for prod |

### Jenkins Agent Requirements

The agent running these jobs only needs:
- **Docker** — all tools run inside the vault-ops Docker image built from the project `Dockerfile`

The Docker image includes AWS CLI v2, OpenTofu, Vault CLI, jq, curl, and openssl. It is built on the fly at the start of each pipeline (with Docker layer caching for speed).

## Setting Up the Seed Job

### 1. Create a Freestyle Job

In Jenkins, create a new Freestyle job named `vault-cluster-seed`:

1. **Source Code Management**: Point to your vault-cluster Git repository
   - Repository URL: `https://github.com/your-org/vault-cluster.git`
   - Branch: `main`

2. **Build Steps**: Add "Process Job DSLs"
   - Look on Filesystem: `jenkins/seed-job.groovy`
   - Action for removed jobs: Delete
   - Action for removed views: Delete

3. **Build Triggers** (optional):
   - Poll SCM: `H/5 * * * *` (check for changes every 5 minutes)
   - Or trigger manually when pipeline definitions change

### 2. Run the Seed Job

Click "Build Now". This creates the following job structure:

```
vault-cluster/
  nonprod-test/
    plan                    # tofu plan
    apply                   # tofu apply (with approval gate)
    launch-node             # Launch EC2 instance in AZ
    terminate-node          # Terminate EC2 instance
    rolling-update          # Replace all nodes one-by-one
    cluster-status          # Health check
    backup-restore          # Take/restore snapshots
    setup-backup-auth       # One-time: configure Vault IAM auth for backups
  nonprod/
    plan
    apply
    launch-node
    terminate-node
    rolling-update
    cluster-status
    backup-restore
    setup-backup-auth
    sync-to-nonprod-test    # Copy nonprod data to nonprod-test
    store-credentials       # Save root token + keys to Secrets Manager
  prod/
    plan
    apply
    launch-node
    terminate-node
    rolling-update
    cluster-status
    backup-restore
    setup-backup-auth
    store-credentials
  migration/
    migrate-nonprod         # Full migration pipeline for nonprod
    migrate-prod            # Full migration pipeline for prod
  rekey-recovery            # Regenerate lost recovery keys
  Dashboard                 # Single-page overview of all jobs
```

It also creates these **views** (visible from the Jenkins home page):

```
Vault Cluster (nested view)
  nonprod-test      # All nonprod-test jobs in a list
  nonprod           # All nonprod jobs in a list
  prod              # All prod jobs in a list
  Migration         # migrate-nonprod, migrate-prod
  Health Checks     # cluster-status from all 3 environments
  Backups           # backup-restore + sync jobs from all environments
  Infrastructure    # plan + apply from all environments
```

### 3. Update Configuration

Before using the jobs, edit `jenkins/seed-job.groovy` and update:

```groovy
def repoUrl = 'https://github.com/your-org/vault-cluster.git'  // your repo
def repoBranch = 'main'  // your branch
def terraformDir = 'terraform'  // terraform directory in repo

def environments = [
    'nonprod-test': [
        awsCredential: 'aws-nonprod',           // matches your Jenkins credential ID
        vaultAddr: 'https://vault.nonprod-test.example.io',  // your domain
        vaultTokenCredential: 'vault-nonprod-test-token',    // matches your credential ID
    ],
    // ...
]
```

Also update the Vault addresses in each `jenkins/pipelines/*.Jenkinsfile` if they differ from the defaults.

## Job Descriptions

### Infrastructure Jobs

#### plan

Runs `tofu plan` for the environment. Safe to run anytime.

- **Parameters**: `TARGET` (optional) — e.g., `module.backup`
- **No approval required**

#### apply

Runs `tofu plan` then `tofu apply` with an approval gate between them.

- **Parameters**: `TARGET` (optional), `AUTO_APPROVE` (skip approval)
- **Approval required** unless AUTO_APPROVE is checked

### Node Management Jobs

#### launch-node

Launches a new EC2 instance in the specified AZ. Uses `launch-node.sh` with `--yes` for non-interactive mode.

- **Parameters**: `AZ_INDEX` (0, 1, or 2)

#### terminate-node

Terminates an EC2 instance with approval gate.

- **Parameters**: `INSTANCE_ID` (required), `REMOVE_FROM_RAFT` (default false)
- **Approval required**

#### rolling-update

Replaces all nodes one at a time. Pre-flight health check, approval gate, then automated replacement.

- **Parameters**: `SKIP_TERRAFORM` — skip tofu apply, just replace nodes
- **Approval required**

### Health Jobs

#### cluster-status

Runs `cluster-status.sh`. No parameters, no approval. Quick way to check health.

### Backup Jobs

#### backup-restore

Three modes:
- **list**: Shows available snapshots in S3
- **backup**: Takes a snapshot and uploads to S3 `daily/` prefix
- **restore**: Downloads a snapshot from S3 and restores it (approval required)

Parameters: `ACTION` (list/backup/restore), `S3_KEY` (for restore)

#### setup-backup-auth

One-time job per environment. Configures Vault's AWS IAM auth method and creates the backup policy so the automated systemd timer can authenticate.

Run this **after initial cluster setup** and **before the first automated backup**.

### Data Jobs

#### sync-to-nonprod-test

Copies all data from nonprod to nonprod-test. Double confirmation required (checkbox parameter + approval gate).

#### store-credentials

Stores root token and recovery keys in AWS Secrets Manager. Takes password parameters for sensitive input.

### Migration Jobs

#### migrate-nonprod / migrate-prod

Full end-to-end migration pipeline:
1. Snapshots the legacy cluster
2. Deploys new infrastructure
3. Launches first node
4. Initializes + restores snapshot
5. Launches remaining nodes
6. Verifies health
7. Archives the snapshot as a build artifact

Parameters: `LEGACY_VAULT_ADDR`, `LEGACY_VAULT_TOKEN`, `SKIP_INFRA_DEPLOY`

**The migration snapshot is saved as a Jenkins build artifact** for safety.

#### rekey-recovery

Interactive pipeline for regenerating recovery keys. Note: this is not fully automatable because it requires entering existing recovery keys.

## Common Workflows

### Initial Deployment (new environment)

```
1. vault-cluster/<env>/apply          # Deploy infrastructure
2. vault-cluster/<env>/launch-node    # AZ_INDEX=0
3. (manually initialize Vault)
4. vault-cluster/<env>/store-credentials
5. vault-cluster/<env>/launch-node    # AZ_INDEX=1
6. vault-cluster/<env>/launch-node    # AZ_INDEX=2
7. vault-cluster/<env>/setup-backup-auth
8. vault-cluster/<env>/cluster-status
```

### Vault Version Upgrade

```
1. Update vault_version in terraform/environments/<env>.tfvars, push to Git
2. vault-cluster/<env>/rolling-update
3. vault-cluster/<env>/cluster-status
```

### Disaster Recovery

```
1. vault-cluster/<env>/backup-restore  (ACTION=list, find the snapshot)
2. vault-cluster/<env>/backup-restore  (ACTION=restore, S3_KEY=<key>)
3. vault-cluster/<env>/cluster-status
```

### Refresh nonprod-test from nonprod

```
1. vault-cluster/nonprod/sync-to-nonprod-test
```

### Migrate Legacy Cluster

```
1. vault-cluster/migration/migrate-nonprod   (or migrate-prod)
2. vault-cluster/<env>/store-credentials     (enter the new credentials from step 1 output)
3. vault-cluster/<env>/setup-backup-auth
4. (update DNS manually)
5. vault-cluster/<env>/cluster-status
```

## Docker Build Strategy

All pipelines build the `vault-ops` Docker image on the fly from the project `Dockerfile`. The Jenkins agent only needs Docker installed — no other tools required.

Each pipeline contains a `buildVaultOpsImage()` function:

```groovy
def buildVaultOpsImage() {
    stage('Build Docker Image') {
        def imageTag = "vault-ops:${env.BUILD_TAG}"
        return docker.build(imageTag, ".")
    }
}
```

This builds the image (with layer caching from previous builds) and returns it. All subsequent stages run commands inside that image using `img.inside(...)`:

```groovy
def img = buildVaultOpsImage()

stage('Plan') {
    withCredentials([...]) {
        img.inside("-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN") {
            dir('terraform') {
                sh "../scripts/env.sh nonprod plan"
            }
        }
    }
}
```

The Docker image includes: AWS CLI v2, OpenTofu, Vault CLI, jq, curl, openssl.

### Docker Caching

Docker layer caching keeps subsequent builds fast. The first build for a given agent takes ~60 seconds; subsequent builds reuse cached layers and complete in seconds unless the Dockerfile or tool versions changed.

### Jenkins Agent Requirements

The agent only needs:
- **Docker** (to build and run the vault-ops image)
- **Docker Pipeline plugin** (for `docker.build()` and `img.inside()`)

No AWS CLI, tofu, vault, or jq needed on the agent itself.

## Views

The seed job creates the following views on the Jenkins home page:

### Vault Cluster (nested view)

A top-level nested view with sub-tabs:

| Tab | Contents |
|-----|----------|
| **nonprod-test** | All nonprod-test jobs |
| **nonprod** | All nonprod jobs |
| **prod** | All prod jobs |
| **Migration** | migrate-nonprod, migrate-prod |
| **Health Checks** | cluster-status from all 3 environments |
| **Backups** | backup-restore + sync jobs from all environments |
| **Infrastructure** | plan + apply from all environments |

### Dashboard

A single-page dashboard view inside the `vault-cluster/` folder showing all jobs grouped by environment.

**Required plugins**: Nested View Plugin, Dashboard View Plugin.

## Troubleshooting

### "Backend config changed" errors

The `env.sh` wrapper always runs `tofu init -reconfigure`, which handles backend config changes. If you see this error in a pipeline, ensure the workspace is clean (`cleanWs()` in post block).

### Credential injection failures

Verify the credential IDs in `jenkins/seed-job.groovy` match exactly what's configured in Jenkins. Credential IDs are case-sensitive.

### Timeout on rolling-update

The default timeout is 45 minutes. A 3-node rolling update typically takes 15-20 minutes. If it times out, check if a node failed to rejoin — the script waits up to 5 minutes per node before failing.

### Seed job fails with "script not approved"

If your Jenkins has script approval enabled, you may need to approve the Job DSL script in Manage Jenkins > In-process Script Approval.

### Docker build fails

Ensure the Jenkins agent has Docker installed and the Jenkins user is in the `docker` group (or Docker socket permissions allow access). If behind a corporate proxy, add proxy build args to the Dockerfile.
