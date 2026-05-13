# Review Findings & Discussion Notes

Tracking doc for the multi-agent review performed on 2026-04-29.
Each finding has a **Status**, **Decision/Notes**, and **Action** section — fill in as discussions happen.

Status legend: `open` | `discussing` | `accepted` | `rejected` | `in-progress` | `done` | `wont-fix` | `false-positive`

> **Before debating any finding**, check [architecture-decisions.md](architecture-decisions.md).
> Signed-off design choices (ADR-001 through ADR-009) cover most of the
> "wontfix" dispositions below. If a finding conflicts with an accepted ADR,
> default to wontfix with a link to the ADR.

---

## Critical

### C1. Vault API ingress allows `0.0.0.0/0` on 8200
- **Source:** security
- **Location:** `terraform/environments/{nonprod-test,nonprod,prod}.tfvars:29`, `terraform/terraform.tfvars.example:30`
- **Detail:** `allowed_cidr_blocks` was `["0.0.0.0/0"]` in all env tfvars.
- **Status:** done
- **Notes:** Env tfvars in this repo are placeholders — real values are overridden at deploy time per the operator. Still, the in-repo defaults shouldn't look open-to-the-world if someone runs them without override. Swapped to `["10.0.0.0/8"]` across all four files with a `# placeholder — override per-env` comment so the intent is obvious and fails closed (RFC1918) rather than open.
- **Action:** Applied 2026-04-29 — nonprod-test.tfvars, nonprod.tfvars, prod.tfvars, terraform.tfvars.example.

### C2. AWS provider pinned exactly (`6.35.0`)
- **Source:** devops
- **Location:** `terraform/versions.tf:9`
- **Detail:** Exact pin blocked patch releases for security/bug fixes.
- **Status:** done
- **Notes:** Switched to `~> 6.35` — allows 6.35.x patch releases, blocks 7.x breaking changes. No `.terraform.lock.hcl` in repo, so any `tofu init` picks up the latest compatible version on first run.
- **Action:** Applied 2026-04-29 — terraform/versions.tf:9. Modules don't pin AWS provider (verified), only the root.

### C3. Backend config placeholder will fail `tofu init`
- **Source:** devops
- **Location:** `terraform/backend-configs/nonprod-test.hcl:1`
- **Detail:** Contains `your-terraform-state-bucket` placeholder.
- **Status:** wontfix
- **Notes:** Intentional — backend-configs/*.hcl in this repo are placeholder values only. Real bucket names are provided at deploy time, not committed here. Same model as env tfvars.
- **Action:** None. Leaving placeholder in place.

### C4. Backup leader detection is incomplete
- **Source:** sre
- **Location:** `scripts/backup-snapshot.sh:42-57`
- **Detail:** Old check relied only on `/v1/sys/health`'s `standby:false` (local self-perception). A partitioned-but-unsealed node could believe itself the leader and take a corrupt backup.
- **Status:** done
- **Notes:** Implemented 2-stage check:
  - **Stage 1** — local health (initialized, unsealed, not-standby)
  - **Stage 2** — Raft consensus: `vault operator raft list-peers` must confirm my node_id is `leader:true`, peer_count equals `EXPECTED_PEERS` (default 3), and zero non-voters (catches mid-promotion state).
  Skips with WARN log + CloudWatch `Vault/Backup.BackupSkipped` metric if any check fails. Emits `BackupSuccess` on completion. node_id is derived from `${CLUSTER_NAME}-<IMDS AZ>` (matches userdata). Backup role needs additional policy grant: `sys/storage/raft/configuration ["read"]` (already documented in updated script header).
- **Action:** Applied 2026-04-29 — scripts/backup-snapshot.sh completely reworked. Harness `/tmp/verify_backup_leader_check.sh` proves 9 scenarios (healthy/sealed/standby/garbage/2-peers/wrong-leader/non-voter/empty-raft/malformed-raft) all classify correctly.

**Follow-up action required at Vault-level** (operator, not in this repo):
1. Update the `backup` policy to add `path "sys/storage/raft/configuration" { capabilities = ["read"] }`.
2. Verify CloudWatch metrics are flowing after next backup window.
3. Consider adding an alert on `BackupSkipped > 0 for 24h` — backups being skipped for a full day should page on-call.

### C5. No backup restore testing / undefined RTO/RPO
- **Source:** sre
- **Location:** `docs/backups.md`, `docs/operations.md`
- **Detail:** Backups run every 6h but nothing verifies they restore cleanly. `restore-snapshot.sh` exists but no evidence of periodic validation.
- **Status:** done (partial — see "deferred" below)
- **Notes:** Chose **option B** (daily `vault operator raft snapshot inspect` — no restore). Zero-infrastructure, runs purely locally on the Jenkins host. Catches: corrupted files, truncation, HTML-error-page-as-snapshot, stale snapshots, empty snapshots. Does NOT catch: version incompatibility, KMS mismatch, logical corruption — a full restore drill is still the only authoritative check, deferred.
  - `scripts/validate-backup.sh` — parametrized via `MAX_AGE_HOURS` (default 8), `MIN_SIZE_BYTES` (default 10240), `VALIDATE_CW_NAMESPACE` (default `Vault/BackupValidation`).
  - `jenkins/pipelines/validate-backup.Jenkinsfile` — cron `15 7 * * *` (daily 07:15 UTC, one hour after the 06:00 UTC backup window).
  - CloudWatch metrics: `Success`, `Failure`, `AgeHours`, `SizeBytes`, `NoSnapshotsFound`, `DownloadFailure` per env.
  - No paging day-one — CloudWatch log-only per C5 decision. Alarm on `Sum(Failure) > 0 over 24h` once baseline established.
  - Day-one scope: **nonprod-test only**. Extend to nonprod/prod by replicating the Jenkins job.
- **Action:** Applied 2026-04-29. Harnesses `/tmp/verify_validate_backup.sh` (classifier, 11 cases) and `/tmp/verify_validate_backup_integration.sh` (end-to-end with mocked aws+vault CLIs, 8 cases) all pass.

**Deferred for later:**
- **Option A — automated weekly restore drill.** Needs an ephemeral target (single-node Docker Vault on vault-ops host was suggested — aspirational). Would catch version / KMS / logical-corruption failure modes this daily check can't reach.
- **RTO/RPO target numbers.** Current posture without commitment: RPO ~6h15m (backup cadence + jitter), RTO unknown (probably 20-60 min for operator-driven rebuild). Needs a business decision before we can engineer to it.
- **Extend validation to nonprod and prod.** Copy the Jenkinsfile into those env folders once nonprod-test has run clean for a week.

### C6. Recovery key rekey deadlock — no fast path if keys lost
- **Source:** sre
- **Location:** `scripts/rekey-recovery.sh`, `docs/operations.md:325-366`
- **Detail:** Vault's rekey API requires current recovery keys to authorize generation of new ones — this is a deliberate Vault security property, not a bug. If keys are lost, only path is cluster rebuild + snapshot restore (multi-hour RTO). The script header and docs previously implied "this recovers from lost keys" — a false promise.
- **Status:** done
- **Notes:** Applied both sub-parts per discussion:
  - **A (clarify):** Rewrote `scripts/rekey-recovery.sh` header and in-script prompts to make unambiguously clear this is a **rotation** tool requiring current keys — not a recovery-from-loss tool. In-script warning now points operators at `docs/dr-lost-recovery-keys.md` instead of repeating the false "workaround" language. `docs/operations.md §Recovery Key Rotation` rewritten with matching scope, "Why 'just rebuild' isn't automated" section explaining the API property.
  - **B (break-glass runbook):** New `docs/dr-lost-recovery-keys.md` covers three scenarios:
    1. Recovery keys lost, root token held → rebuild (references `migration.md` for mechanics)
    2. Root token lost, recovery keys held → `vault operator generate-root` procedure (corrected via docs lookup — involves `-generate-otp`, `-init -otp`, threshold of recovery keys, `-decode`)
    3. Both lost → same as #1 but no fresh pre-rebuild snapshot possible; fall back to latest S3
  - Includes RTO estimates (Scenario 2: ~10min; Scenarios 1 & 3: ~1-2 hours operator-driven), before-you-start checklist, Prevention section (init-time storage, IAM hygiene, quarterly rotation drill), cross-references to backups.md / migration.md / operations.md.
- **Action:** Applied 2026-04-29 — scripts/rekey-recovery.sh (header + prompt rewritten), docs/operations.md (section renamed to "Recovery Key Rotation", scope clarified), docs/dr-lost-recovery-keys.md (new runbook, ~200 lines).

**Follow-up deferred:**
- Establish quarterly recovery-key rotation drill as an ops calendar item (not repo work).
- Add H1 audit-device finding reference to the "After any of these" section once H1 is closed (noted in runbook with a link).

### C7. Backup role authentication not auto-provisioned
- **Source:** devops
- **Location:** `terraform/modules/vault-nodes/templates/userdata.sh.tpl:316`
- **Detail:** Backup script authenticates with hardcoded AWS auth role named `backup`, but that role isn't set up automatically — silent fail on fresh deployments.
- **Status:** wontfix (original framing), with two small cleanups applied
- **Notes:** Audit misread the architecture. The setup **is** automated, via `jenkins/pipelines/setup-backup-auth.Jenkinsfile` — a one-time post-init job that enables `auth/aws` and creates the backup policy + role. Documented at `docs/operations.md:538 §Backup IAM Auth Setup` and `docs/jenkins.md:190`. Doing this in userdata would be wrong:
  - Userdata runs per-node on boot; the backup role only needs to exist once across the cluster (Vault replicates it).
  - Userdata runs before `vault operator init`; no root token available to write policies.
  - Baking the root token into userdata defeats the point of storing it in Secrets Manager.
  The existing design is correct: `init → store credentials → setup-backup-auth → backups work`.
- **Action:** Two small cleanups applied:
  1. Fix dangling `docs/backup-setup.md` reference in `scripts/backup-snapshot.sh` → point to real doc path.
  2. Update `setup-backup-auth.Jenkinsfile` policy stanza to include the `sys/storage/raft/configuration` read capability added by C4 (backup now calls `vault operator raft list-peers` for the Raft-consensus leader check).

### C7'. Vault configuration is imperative (Jenkins pipelines), not declarative (Terraform)
- **Source:** spun out of C7 discussion 2026-04-29
- **Location:** `jenkins/pipelines/setup-backup-auth.Jenkinsfile`, and any future `vault_*` resources (auth methods, policies, auth roles, secret engines)
- **Detail:** Today, Vault-internal resources (policies, auth methods, auth roles) are created by one-time Jenkins pipelines. Benefits of the current approach: clean separation of concerns, no chicken-and-egg with AWS infra TF, rebuild-resilient. Costs:
  - No drift detection — if someone runs `vault policy write backup` manually, nothing notices.
  - No auditor-friendly "policy as code" story.
  - Adding a new policy or role requires editing a Groovy pipeline rather than a Terraform file.
  - Review/PR flow is inconsistent with the rest of the infra.
- **Status:** deferred
- **Notes:** Discussed and explicitly deferred. Proposed future shape:
  - New `terraform/vault-config/` root with its own backend/state.
  - Uses `hashicorp/vault` provider; root token sourced via `data.aws_secretsmanager_secret_version` from `<cluster>/vault/root-token`.
  - Ports `setup-backup-auth.Jenkinsfile` → `vault_auth_backend "aws"` + `vault_policy "backup"` + `vault_aws_auth_backend_role "backup"`.
  - Migration/DR runbooks add a "apply vault-config TF after init" step.
  - Open question for later: whether to include the root-token and recovery-keys Secrets Manager entries in this TF too (leaning no — creates another chicken-and-egg).
  - Rebuild impact: after any fresh-deploy + snapshot-restore, the `vault-config/` state is stale against the new cluster. Need a documented pattern (probably `terraform state rm` + re-apply, or blow away state + `terraform apply`).
- **Action:** Deferred — not fixing now. Mid-migration to this codebase; introducing a new TF root adds cognitive load for no immediate benefit. Revisit after nonprod/prod migration is complete and the cluster is stable.

### C8. Persistent-vs-ephemeral EBS decision unresolved before prod migration
- **Source:** architecture
- **Location:** `project_ebs_debate.md`
- **Detail:** Persistent EBS preserved stale Raft state causing nonprod-test leaderless deadlock. 8 failure scenarios favor ephemeral, but ephemeral risks data loss on multi-AZ failure.
- **Status:** open
- **Notes:**
- **Action:**

---

## High

### H1. No Vault audit device configured
- **Source:** security
- **Location:** `userdata.sh.tpl` (missing)
- **Detail:** No file/syslog audit device enabled post-init. No forensic trail for access.
- **Status:** done
- **Notes:** Implemented via three artifacts:
  - **Userdata** — pre-creates `/var/log/vault/` (owned by vault:vault, 0750) and writes `/etc/logrotate.d/vault-audit` using `tee`. Rotation: daily OR maxsize 100M, retain 14, compress (delaycompress), copytruncate, dateformat with nanosecond precision (prevents same-second rotation collisions during size triggers). `su vault vault` so logrotate runs as the vault user.
  - **`jenkins/pipelines/setup-audit.Jenkinsfile`** — idempotent one-time job per cluster. Checks `vault audit list` first; only enables if absent. Emits `vault audit enable file file_path=/var/log/vault/audit.log log_raw=false`.
  - **Splunk integration** — zero new agent config. Splunk's existing `/var/log` scan picks up the audit log automatically.
  - **Logrotate harness** (`/tmp/verify_vault_audit_logrotate.sh`, 12 assertions) proves: config parses, daily trigger works, size trigger (>100M) works on fresh state, delaycompress leaves newest uncompressed and older compressed, retention caps at 14 rotated files, permissions preserved (0640), `notifempty` skips zero-byte files, `missingok` doesn't error if log hasn't been created yet. Caught a real edge case: same-second size-triggered rotations would overwrite each other without nanosecond dateformat — fixed in the shipped config.
- **Action:** Applied 2026-04-29 — `terraform/modules/vault-nodes/templates/userdata.sh.tpl`, new `jenkins/pipelines/setup-audit.Jenkinsfile`, `docs/operations.md §Audit Logging`, `docs/jenkins.md`.

**Follow-up tracked:**
- Alerting on `vault.audit.*.write_failure` deferred to H12 (Prometheus alert rules work).
- `log_raw=true` escape hatch for debugging is NOT enabled — if ever needed, use a separate short-lived audit device with an isolated file destination, not the production one.

### H2. IMDSv2 not enforced on EC2
- **Source:** security
- **Location:** `scripts/launch-node.sh:236`
- **Detail:** Audit claimed `HttpTokens=required` was missing from EC2 instance launch config.
- **Status:** false-positive
- **Notes:** Already implemented at `scripts/launch-node.sh:236` — `--metadata-options "HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=1,InstanceMetadataTags=enabled"`. IMDSv2 required, hop limit 1 (blocks container escape SSRF), tags enabled via IMDS. Userdata already consumes IMDSv2 via the token flow at `userdata.sh.tpl:26-29`. Audit missed the metadata-options flag because it was looking for Terraform-declared EC2 resources; this cluster launches instances via script rather than TF.
- **Action:** None. No change needed.

### H3. Secrets Manager has no rotation
- **Source:** security
- **Location:** `modules/secrets/main.tf:11-38`
- **Detail:** Root token + recovery keys have no automatic rotation (30-90 day policy).
- **Status:** wontfix
- **Notes:** These secrets hold Vault's DR credentials (root token, recovery keys), not ordinary API keys. AWS Secrets Manager auto-rotation would be either:
  1. **Cosmetic rotation** of the stored value without rotating the underlying Vault credential — leaves SM holding a value Vault won't accept. DR breaks silently.
  2. **Real rotation** that drives `rekey-recovery.sh` + `store-vault-credentials.sh` via Lambda — introduces a chicken-and-egg (Vault credential rotation failing while Vault itself is the thing that needs unlocking) and makes a Lambda the critical path for DR credential integrity.
  Neither is worth the risk. The real answer is **operator-driven rotation on a known schedule with supervision** — which is what C6's quarterly rotation drill (task #18) already covers.
- **Action:** No automated rotation. Operators run `rekey-recovery.sh` quarterly per the C6 drill. The drill exercises the rotation path on a known cadence with human oversight, confirming SM entries and Vault seal state stay in sync.

### H4. Backup S3 bucket — no deny-non-SSL, no object lock, no MFA delete
- **Source:** security
- **Location:** `modules/backup/main.tf`
- **Detail:** Vulnerable to insider deletion / ransomware.
- **Status:** done (MFA delete deferred)
- **Notes:** Added to `modules/backup/main.tf`:
  - **`aws_s3_bucket.object_lock_enabled=true`** — MUST be set at creation. Cannot be enabled retroactively; existing buckets need recreation (or S3 Replication migration).
  - **`aws_s3_bucket_object_lock_configuration.backup`** — default retention rule: GOVERNANCE mode, 30 days. GOVERNANCE (not COMPLIANCE) lets privileged operators with `s3:BypassGovernanceRetention` override for legitimate cleanup; COMPLIANCE would be undeletable by anyone including root, which is too strict for our threat model.
  - **`aws_s3_bucket_policy.backup`** with `DenyInsecureTransport` statement — blocks `aws:SecureTransport=false`, i.e., any request not over TLS.
  - Two new variables: `object_lock_enabled` (default true) and `object_lock_retention_days` (default 30, tuned to match the sync-prefix shortest retention).
- **MFA delete:** Not added. Requires root credentials + manual CLI invocation to enable (can't be set via Terraform `aws_s3_bucket_versioning`). Adds friction to every `aws s3 rm` which conflicts with the automated lifecycle rules. If compliance demands it, enable separately via `aws s3api put-bucket-versioning` with root credentials.
- **Action:** Applied 2026-05-01. `tofu validate` passes. Existing buckets will need recreation to enable Object Lock — coordinate with migration plan.

### H5. Hardcoded EBS device path `/dev/xvdf`
- **Source:** devops
- **Location:** `userdata.sh.tpl:16`
- **Detail:** NVMe-backed instance types use `/dev/nvme*`. Instance-type change silently breaks mount.
- **Status:** wontfix (reverted)
- **Notes:** Briefly implemented a runtime `resolve_data_device()` function that handled both xen (/dev/xvdf) and NVMe (/dev/nvme*n1) layouts. Reverted 2026-05-01 for two reasons:
  1. **Out of scope.** Operator controls the instance type; there's no scenario where a node boots with an unknown device layout. Instance-type changes are deliberate, reviewed, and exactly the moment someone would update the hardcoded path if needed.
  2. **Userdata size.** The template was at ~101% of the AWS 16KiB userdata limit after H1, P1.2, and H5 edits. The NVMe function was ~55 lines — the single largest new block. Removing it dropped rendered size from 16617 → 14373 bytes (87% of limit, ~2KB headroom).
- **Action:** Reverted to the original hardcoded `DATA_DEVICE="/dev/xvdf"` with a 3-line comment noting the m8g.medium assumption and what to change if moving to NVMe-native instance types.

### H6. `prevent_destroy=true` on EBS with no escape variable
- **Source:** devops
- **Location:** `modules/vault-nodes/main.tf:42`
- **Detail:** Intentional destroys require manual state edit.
- **Status:** done (documentation-only)
- **Notes:** Terraform does not allow `lifecycle.prevent_destroy` to be variable-driven — by design, it's a compile-time safety fence, not a runtime toggle. A variable would defeat the fence. The correct pattern (HashiCorp's own recommendation) is `terraform state rm` when destruction is legitimately needed, which preserves the safety property while giving operators an explicit, auditable path.
- **Action:** (1) Added a block comment above the `aws_ebs_volume.vault_data` resource explaining the intended destroy procedure. (2) Added a new "Destroying an EBS Volume" section in `docs/operations.md` (before Quick Reference) covering the 4-step state-rm + AWS-delete + re-apply flow. No helper script — the procedure is short and benefits from operator consciousness.

### H7. `weekly_retention_days` referenced but not declared
- **Source:** devops
- **Location:** `modules/backup/main.tf:74`
- **Detail:** Audit claimed the variable was referenced but not declared, breaking `tofu validate`.
- **Status:** false-positive
- **Notes:** Variable IS declared at `terraform/modules/backup/variables.tf:22` (default 365). `tofu validate` returns `Success! The configuration is valid.` Audit was wrong. No action required.
- **Action:** None.

### H8. `aws_region=us-east-1` conflicts with us-east-2 standard
- **Source:** devops
- **Location:** `environments/nonprod-test.tfvars:4`, `.../nonprod.tfvars:4`, `.../prod.tfvars:4`, `backend-configs/*.hcl`
- **Detail:** Audit flagged the tfvars region as conflicting with a stated us-east-2 preference.
- **Status:** wontfix
- **Notes:** The "us-east-2 standard" came from the operator's **global** CLAUDE.md preference — not a project fact. This vault-cluster project is deliberately in **us-east-1** and stays there. No migration intended. Project-scoped memory added at `memory/feedback_region.md` to prevent future audits from re-raising this.
- **Action:** None — all env tfvars + backend-configs remain on us-east-1.

### H9. `rolling-update.sh` doesn't validate `VAULT_TOKEN` permissions
- **Source:** devops
- **Location:** `scripts/rolling-update.sh:84-88`
- **Detail:** Script can fail mid-update after terminating nodes if token lacks perms.
- **Status:** done
- **Notes:** Added `preflight_token()` function called early in `main()` as part of Step 1 (Pre-flight checks), before any destructive operation. Verifies:
  - `vault token lookup` succeeds (token is real and unexpired)
  - `vault operator raft list-peers` succeeds (token has `sys/storage/raft/configuration` read)
  - `vault token capabilities sys/step-down` returns `sudo` or `update`
  Script exits 1 at preflight with a specific "required policy" error message pointing at the missing capability. Fails fast — not mid-update.
- **Action:** Applied 2026-05-01. shellcheck clean, bash -n clean.

### H10. Rolling update leader step-down race (60s timeout, no rollback)
- **Source:** sre
- **Location:** `scripts/rolling-update.sh:198-225`
- **Detail:** If election takes >60s, script exits leaving cluster mid-update.
- **Status:** done
- **Notes:** Two changes to `step_down_leader()`:
  - **Timeout env-tunable**: default raised to 180s (was 60), override via `STEP_DOWN_TIMEOUT=<seconds>`. 60s was observed too tight on loaded clusters; 180s is safe default + still fast-fail on genuinely stuck clusters.
  - **Explicit failure path**: on timeout, the error message now tells the operator exactly what state the cluster is in ("previous leader stepped down but no new leader elected") and what to do next (run cluster-status.sh; re-run with `STEP_DOWN_TIMEOUT=300`; DO NOT terminate any nodes). No silent mid-update state.
  - Hardened jq parsing: `.servers[]?` (survives unexpected shape), `2>/dev/null || echo ""` fallback, `head -1 | tr -d whitespace` normalization — same pattern as Phase 1 canary fixes.
- **Action:** Applied 2026-05-01. shellcheck clean, bash -n clean.

### H11. Cold-start wipes non-leader Raft data without index comparison
- **Source:** sre
- **Location:** `scripts/cold-start-cluster.sh:362-366`
- **Detail:** `rm -rf /opt/vault/data/*` on nodes 1/2. Writes that reached only those nodes are lost.
- **Status:** wontfix
- **Notes:** Audit misread the script's purpose. `cold-start-cluster.sh` is a DELIBERATE RESET tool, not a data-preservation recovery tool. It exists for nonprod-test teardown/reset and dev iteration. The unconditional wipe is the **documented industry-standard pattern** — `hashicorp/raft` library's `RecoverCluster` godoc explicitly says "join other new clean-state peer servers using the standard APIs." Three parallel agent reviews (SRE, Vault docs, community patterns) confirmed:
  - `raft list-peers` diff (my first proposed fix) would be a false safety signal — it validates membership, not log state
  - `peers.json` recovery **silently commits uncommitted entries** per HashiCorp docs (flagged as "last resort")
  - Committed-on-follower-only writes are **silently dropped** during any new-leader bootstrap — no client-visible error
  - No public documentation of any operator doing list-peers-diff convergence gating; the community consistently wipes + lets Raft catch up
  - For production data recovery, the right path is S3 snapshot restore via `docs/dr-lost-recovery-keys.md §Scenario 1`, not this script
- **Action:** Added a SCOPE block at the top of `cold-start-cluster.sh` making it explicit that this is a reset tool, pointing operators at the break-glass runbook for data-preserving recovery. No behavior change to the script.

### H12. No Prometheus alert rules shipped
- **Source:** sre
- **Location:** `monitoring/README.md:121-132`
- **Detail:** README lists recommendations only; no YAML rules. On-call discovers incidents reactively.
- **Missing alerts:** sealed node, no leader, audit failures, Raft commit lag, cert expiry, failed backups, EBS disk full.
- **Status:** done
- **Notes:** New `monitoring/alerts/vault-alerts.yml` — 16 rules across 6 groups:
  - **vault-availability (4):** VaultSealed, VaultNoLeader, VaultScrapeTargetDown, VaultQuorumDegraded
  - **vault-raft (3):** VaultLeadershipChurn, VaultRaftCommitSlow, VaultRaftApplyLag
  - **vault-audit (1):** VaultAuditLogFailures — closes H1 alerting TODO
  - **vault-backups (4):** VaultBackupSkipped24h, VaultBackupNoSuccess8h, VaultBackupValidationFailed, VaultBackupSnapshotStale — closes C4 and C5 alerting TODOs
  - **vault-storage (3):** VaultRaftDiskFilling, VaultRaftDiskCritical, VaultAuditDiskFilling
  - **vault-tls (1):** VaultCertExpiringSoon — optional, requires blackbox_exporter
  Every alert has `severity` label and `summary`/`description` annotations. Critical alerts link to runbook paths (all verified to resolve). Each expression uses standard Vault 1.21 metric names; deprecated `vault_core_ha_backend` avoided.
  - Validated via `promtool check rules` (16 rules).
  - Harness `/tmp/verify_alert_rules.sh` — 18 assertions including rule count, severity coverage, expected-alert presence, deprecated-metric rejection, runbook-link resolution.
  - `monitoring/README.md` Alerting section rewritten to document the rules file, load syntax, and validation command.
  - Thresholds are starting points — tune after a week of observed baseline.
- **Action:** Applied 2026-05-01. Closes H1 and C5 alerting TODOs (tasks #12 and various C5 deferred items as far as alerting goes; RTO/RPO targets and weekly-restore-drill are still deferred).

### H13. No cert-expiry monitoring
- **Source:** sre
- **Location:** `docs/troubleshooting.md:148-165`
- **Detail:** Self-signed certs generated at boot; no alert when <30 days to expiry. Cluster-wide TLS failure risk.
- **Status:** wontfix
- **Notes:** The risk the audit described doesn't actually materialize given this cluster's operational cadence:
  - **Node certs:** 365-day lifetime (`userdata.sh.tpl:203` — `openssl x509 ... -days 365`). Nodes are replaced monthly as part of standard ops rotation, so every node cert is regenerated every ~30 days. Expiry would require ~11 consecutive months of no rolling updates, which is implausible.
  - **CA cert:** 10-year lifetime (`scripts/generate-ca.sh:59` — `openssl req -new -x509 -days 3650`). Effectively not an expiry concern on operational time scales.
  - The "cluster-wide TLS failure risk" from the audit assumed certs weren't being refreshed. They are, as a side effect of monthly rolls.

  **Load-bearing assumption:** monthly rolling updates must continue. If rolls pause for >10 months (freeze window, forgotten procedure, blocked migration), certs drift toward expiry. Operators should treat "last rolling update >180 days ago" as a warning sign.
- **Action:** None. Assumption documented here; if monthly rolls ever stop being reality, revisit this finding.

### H14. NLB health check lacks `?standbyok=true`
- **Source:** architecture
- **Location:** `modules/nlb/main.tf`
- **Detail:** Standbys return 429 → NLB only routes to leader. Wasted read capacity; leader CPU bottleneck.
- **Status:** open
- **Notes:**
- **Action:**

### H15. Single-region KMS auto-unseal = sealed cluster on region outage
- **Source:** architecture
- **Location:** `modules/kms/`
- **Detail:** Region-wide AWS/KMS outage seals the cluster even if nodes + data are healthy.
- **Status:** open
- **Notes:**
- **Action:**

### H16. Vault 1.9→1.21 `allowed_parameters`/`denied_parameters` semantics changed
- **Source:** architecture
- **Detail:** List-value matching changed from whole-list to item-by-item. Post-restore ACL audit required.
- **Status:** open
- **Notes:**
- **Action:**

### H17. No auto-remediation for instance failures
- **Source:** architecture
- **Detail:** Script-based fleet; manual ops for hardware failure. Two nodes down = quorum lost.
- **Status:** open
- **Notes:**
- **Action:**

---

## Medium

### M1. CA private key in Secrets Manager, 365-day node certs
- **Source:** security
- **Location:** `userdata.sh.tpl:109-119,169`
- **Detail:** Tighten to 90-day certs + auto-renewal, or migrate to ACM Private CA.
- **Status:** wont-fix
- **Notes:** its ok. nodes get replaced more often.
- **Action:** none.

### M2. KMS key uses default key policy
- **Source:** security
- **Location:** `modules/kms/main.tf:2-15`
- **Detail:** Add explicit policy restricting `kms:Decrypt` to Vault role.
- **Status:** open
- **Notes:** 
- **Action:**

### M3. Egress wide-open to 0.0.0.0/0
- **Source:** security
- **Location:** `modules/security-groups/main.tf:37-43`
- **Detail:** Scope to AWS service endpoints (S3, KMS, Secrets Manager, SSM).
- **Status:** wont-fix
- **Notes:** this is fine
- **Action:** None

### M4. `ec2:DescribeInstances` on `Resource=*`
- **Source:** security
- **Location:** `modules/iam/main.tf:67`
- **Detail:** Add condition `ec2:ResourceTag/vault-cluster: ${var.cluster_name}`.
- **Status:** open
- **Notes:**
- **Action:**

### M5. SSM logs policy lacks encryption-in-transit enforcement
- **Source:** security
- **Location:** `modules/iam/main.tf:119`
- **Detail:** Add condition requiring `s3:x-amz-server-side-encryption`.
- **Status:** open
- **Notes:**
- **Action:**

### M6. `stat` command has macOS/Linux differences in userdata
- **Source:** devops
- **Location:** `userdata.sh.tpl:329`
- **Status:** open
- **Notes:**
- **Action:**

### M7. Terraform plan output suppressed in rolling-update
- **Source:** devops
- **Location:** `scripts/rolling-update.sh:281`
- **Status:** open
- **Notes:**
- **Action:**

### M8. SSM params not driven by module outputs (circular-dep risk)
- **Source:** devops
- **Location:** `terraform/main.tf:109-121`
- **Status:** open
- **Notes:**
- **Action:**

### M9. Bash arrays exported without `declare -a`
- **Source:** devops
- **Location:** `scripts/resolve-env.sh:77-82`
- **Status:** open
- **Notes:**
- **Action:**

### M10. CloudWatch Logs ARN uses wildcards for region/account
- **Source:** devops
- **Location:** `modules/iam/main.tf:136`
- **Detail:** Use `data.aws_caller_identity` / `data.aws_region` to constrain.
- **Status:** wont-fix`
- **Notes:** this is ok.
- **Action:** None

### M11. Backup timer jitter can skip windows during node replacement
- **Source:** sre
- **Detail:** `RandomizedDelaySec=900` + `Persistent=true` — new instance has no timer history. Gap up to 6h15m.
- **Status:** open
- **Notes:**
- **Action:**

### M12. `restore-snapshot.sh` parses tfvars with grep/sed
- **Source:** sre
- **Location:** `scripts/restore-snapshot.sh:56-68`
- **Detail:** Fragile to tfvars syntax changes (comments, multi-line).
- **Status:** open
- **Notes:**
- **Action:**

### M13. Grafana dashboard depends on CloudWatch datasource outside repo
- **Source:** sre
- **Location:** `monitoring/README.md:60-69`
- **Detail:** IAM config lives "on the Grafana side" — drift risk.
- **Status:** open
- **Notes:**
- **Action:**

### M14. No quorum-loss recovery runbook
- **Source:** sre
- **Location:** `docs/troubleshooting.md:263`
- **Detail:** Docs point to `cold-start-cluster.sh` (500 lines) with no step-by-step. Missing pre-flight checklist, failure-modes table, rollback.
- **Status:** open
- **Notes:**
- **Action:**

### M15. nonprod + nonprod-test share AWS account (blast radius)
- **Source:** architecture
- **Status:** open
- **Notes:**
- **Action:**

### M16. K8s agent sidecar 1.14 vs server 1.21 (7-minor skew)
- **Source:** architecture
- **Detail:** Supported but missing 1.15-1.21 fixes. Upgrade post-migration.
- **Status:** open
- **Notes:**
- **Action:**

---

## Low

### L1. `ec2:DescribeInstances` conditioning (see M4)
- merged into M4

### L2. CA key echoed to userdata logs (`set -x`)
- **Source:** security
- **Location:** `userdata.sh.tpl:2,109,120`
- **Detail:** Wrap secret retrieval with `set +x`.
- **Status:** open
- **Notes:**
- **Action:**

### L3. Empty-string instance tag values
- **Source:** devops
- **Location:** `environments/nonprod-test.tfvars:43-52`
- **Status:** open
- **Notes:**
- **Action:**

### L4. `trap` in `launch-node.sh` only triggers on function return
- **Source:** devops
- **Location:** `scripts/launch-node.sh:216`
- **Status:** open
- **Notes:**
- **Action:**

### L5. `disable_mlock = true` undocumented
- **Source:** devops
- **Location:** `userdata.sh.tpl:247`
- **Status:** open
- **Notes:**
- **Action:**

### L6. Jenkins cross-account assume-role not verified
- **Source:** sre
- **Status:** wont-fix
- **Notes:** 
- **Action:** None

### L7. Audit log shipping gap
- **Source:** sre
- **Detail:** Vault audit logs written locally; no shipping to Splunk / CloudWatch Logs. Lost on termination.
- **Status:** wont-fix`
- **Notes:** Handled in custom userdata, outside of this scope.
- **Action:** None

---

## Info / Open questions

### I1. CloudTrail coverage for Secrets Manager / KMS / SSM
- **Source:** security
- **Detail:** Verify CloudTrail logs these API calls in all accounts.
- **Status:** wont-fix
- **Notes:** not using cloudtrail logging
- **Action:** None

### I2. Vault telemetry endpoint unauthenticated
- **Source:** security
- **Location:** `userdata.sh.tpl:213`
- **Detail:** Scope Prometheus scraper source IPs.
- **Status:** wont-fix
- **Notes:** this is fine.
- **Action:** None

---

## Missing Runbooks

1. Monthly backup restore validation to nonprod-test
2. Full region-loss DR (cross-region bucket, rebuild steps)
3. Corrupted Raft log recovery (alt node selection vs S3 snapshot)
4. Certificate rotation on a running cluster
5. Quorum loss with stale backup (business continuity for 6h data-loss window)
6. Single AZ loss — node replacement under degraded quorum
7. KMS key rotation procedure
8. Secrets Manager vs SSM Parameter Store decision log

---

## Scripts Audit — 2026-04-29

Multi-agent audit of `scripts/*.sh` for silent-failure patterns under `set -euo pipefail`. Each finding was empirically verified with a `/tmp/verify_*.sh` harness before classification; fixes were applied only to verified bugs and re-verified against the same harness. Original audit produced ~48 claims; ~35 turned out to be false positives (especially `jq ... || echo "default"` under pipefail, `jq -e` inside `if`, and SIGKILL concerns — all of which behave correctly). Shellcheck was run with `-S warning` on every script post-fix; zero remaining warnings.

### S1. `cold-start-cluster.sh:382` — grep no-match silent death
- **Pattern:** `peer_count=$(... | grep -oE '^[0-9]+$' | head -1)` kills script under `set -euo pipefail` when grep finds no match.
- **Status:** done (pre-audit, by hand)
- **Fix:** Added `|| true` after `head -1`.
- **Harness:** `/tmp/verify_grep_nomatch.sh`

### S2. `recover-raft-cluster.sh:310` — same grep no-match pattern
- **Status:** done
- **Fix:** Added `|| true`.
- **Harness:** `/tmp/verify_grep_nomatch.sh`

### S3. `generate-ca.sh:68` — `openssl … | grep -A2 "Subject:"` no-match
- **Status:** done
- **Fix:** Added `|| true`.
- **Harness:** `/tmp/verify_grep_nomatch.sh`

### S4. `restore-snapshot.sh:62-63` — tfvars `grep | sed` silent death on missing key
- **Detail:** If `backup_s3_bucket` or `cluster_name` was absent/commented in the tfvars, grep exited 1, pipefail propagated, and the script died *before* the `[ -z ]` guard could print a useful error.
- **Status:** done
- **Fix:** Added `2>/dev/null ... || true` to each capture; added an explicit `cluster_name not found` guard that was previously missing.
- **Harness:** `/tmp/verify_tfvars_grep_sed.sh`

### S5. `store-vault-credentials.sh:47-48` — same tfvars pattern
- **Status:** done
- **Fix:** Same `|| true` treatment.
- **Harness:** `/tmp/verify_tfvars_grep_sed.sh`

### S6. `launch-node.sh:87` — `jq -r '.[]'` on null kills script
- **Detail:** `SUBNET_IDS=($(cfg_get private_subnet_ids | jq -r '.[]'))` dies with "Cannot iterate over null" if the config value is missing.
- **Status:** done
- **Fix:** Switched to `.[]? // empty`; added empty-array guard with clear error; suppressed SC2207 with a comment explaining bash 3.2 has no `mapfile`.
- **Harness:** `/tmp/verify_jq_null_iteration.sh`

### S7. `launch-node.sh:109` — `ADDITIONAL_SGS` jq null (most-likely-to-fire case)
- **Detail:** Field is optional in vault-config; when absent, `jq -r '.[]'` kills script before the `[ -n ]` guard runs.
- **Status:** done
- **Fix:** `.[]? // empty || true`; while-loop now also skips blank tokens.
- **Harness:** `/tmp/verify_jq_null_iteration.sh`

### S8. `launch-node.sh:102` — security-group array has no post-lookup guard
- **Status:** done
- **Fix:** Added `${#SECURITY_GROUP_IDS[@]} -eq 0` check with clear error message. Also suppressed SC2207 intentionally.
- **Harness:** n/a — added defensive guard

### S9. `cluster-status.sh:82,86,89` — `.data.config.servers[]` on unexpected Vault shape
- **Detail:** If Vault returns a response shape without `.error` but also without `.data.config.servers`, script dies mid-output.
- **Status:** done
- **Fix:** Used `[]?` on the iterator; added `length? // 0` on the count.
- **Harness:** `/tmp/verify_jq_null_iteration.sh`

### S10. `rekey-recovery.sh:60,67,108,117,122,123` — jq on non-JSON Vault responses
- **Detail:** If Vault returns an HTML 502 or plaintext 503 instead of JSON, bare `jq` under `set -e` kills the script with `jq: parse error` and no useful log context.
- **Status:** done
- **Fix:** Every `jq` capture now has `2>/dev/null || echo "<default>"` + defensive `[ -z ] && VAR='{}'` on the JSON body so the existing `[ -z "$NONCE" ]` guard gets to run and print the raw response for debugging.
- **Harness:** `/tmp/verify_jq_malformed.sh`

### S11. `cold-start-cluster.sh:210` — empty `health` passes through to jq
- **Detail:** `ssm_run` could succeed with empty output; subsequent jq on empty input returns empty string, but a later jq on the same empty var could die. Defense in depth.
- **Status:** done
- **Fix:** Force `[ -z "$health" ] && health='{}'` after the ssm_run, plus `// "unknown"` defaults and `|| echo "unknown"` guards on the three jq captures.
- **Harness:** `/tmp/verify_jq_malformed.sh` T10

### S12. `rolling-update.sh:392` — jq failure during rolling update dies without log
- **Detail:** Mid-rolling-update, a transient vault outage makes `vault operator raft list-peers` return error JSON (or HTML); the jq pipeline died without context, leaving the cluster mid-update.
- **Status:** done
- **Fix:** Added `2>/dev/null || echo "false"` to the pipeline and a belt-and-suspenders `[ -z "$is_leader" ] && is_leader="false"`. Also added `.servers[]?` to survive unexpected shapes.
- **Harness:** `/tmp/verify_jq_malformed.sh` T9

### S13. `cold-start-cluster.sh:156` — `NODE_0_ID` can be literal `"None"`
- **Detail:** `aws ec2 describe-instances --output text` with no match returns `None` (not empty). Downstream `describe-instances --instance-ids None` fails opaquely with `InvalidInstanceID.Malformed`.
- **Status:** done
- **Fix:** Explicit guard `if [ -z "$NODE_0_ID" ] || [ "$NODE_0_ID" = "None" ]` with a clear error pointing at `launch-node.sh`.
- **Harness:** `/tmp/verify_semantic_fixes.sh` T1

### S14. `cold-start-cluster.sh:262` — `[ "$sealed" == "true" ]` allows garbage through
- **Detail:** If `sealed` was anything other than `"true"` — empty, `"null"`, `"unknown"`, a jq error string — the check passed and the script proceeded to destructive `peers.json` write on a still-sealed Vault.
- **Status:** done
- **Fix:** Inverted the check to `[ "$sealed" != "false" ]` — only literal `"false"` is allowed to proceed. Also added `// "unknown"` default in the jq call and `[ -z ] && sealed="unknown"` belt-and-suspenders.
- **Harness:** `/tmp/verify_semantic_fixes.sh` T2/T3 (harness proves buggy version admits 5 of 6 non-"true" states; fixed version blocks all non-"false" states)

### S15. `sync-to-nonprod-test.sh:106-107` — `vault status || true` masks verify failure
- **Detail:** Post-restore verify step reported "Sync completed!" even if vault was unreachable/sealed.
- **Status:** done
- **Fix:** Replaced with `if ! vault status; then log_error; exit 1; fi`.
- **Harness:** `/tmp/verify_semantic_fixes.sh` T5

### S17. Batch-3 regression: `jq '.field // "default"'` swallows boolean `false`
- **Detail:** During Batch 3, I added `jq -r '.sealed // "unknown"'` to several scripts. `jq`'s `//` operator is "coalesce on null OR false" (not just null) — so on a healthy unsealed cluster, `.sealed:false` got mapped to `"unknown"`. Downstream `if [ "$sealed" != "false" ]` checks then aborted / waited unnecessarily on healthy clusters. Functionally broke cold-start, rekey-recovery, recover-raft-cluster.
- **Status:** done
- **Fix:** Replaced `jq -r '.field // "default"'` with `jq -r '.field | tostring'` — on boolean fields `tostring` yields literal `"true"`/`"false"`/`"null"`. Applied at:
  - `cold-start-cluster.sh:225-227, 260`
  - `rekey-recovery.sh:61`
  - `recover-raft-cluster.sh:169-170`
- **Harness:** `/tmp/verify_jq_boolean_regression.sh` — proves broken pattern aborts on healthy cluster; fixed pattern proceeds correctly.
- **Lesson:** `//` is unsafe on boolean-valued fields. Use `| tostring` (preserves false), or `has("field")` for explicit presence checks.

### S16. Shellcheck hygiene (SC2034 dead vars, SC2064 trap quoting)
- **Status:** done
- `recover-raft-cluster.sh:163,169` — removed unused `name` and `initialized` vars (SC2034)
- `generate-ca.sh:50` — switched `trap "rm -rf '$WORK_DIR'"` to `trap 'rm -rf "$WORK_DIR"'` (SC2064, idiomatic deferred expansion)
- `launch-node.sh:226` — same trap-quoting fix for `tag_spec_file`
- **Harness:** `/tmp/verify_trap_quoting.sh` (proves deferred expansion works with vars set before AND after the trap registration)

### Still-open items (not bugs — need operator decision)

- **`terminate-node.sh:177`** — with `--remove-from-raft` flag, a failed `vault operator raft remove-peer` is logged-only; the script still proceeds to terminate the instance. Leaves a dead peer in Raft config; no data loss, but future additional node loss could break quorum until operator runs remove-peer manually. Options: (a) promote warn→error+exit when `--remove-from-raft`, (b) retry, (c) keep current permissive behavior. **Not fixed** — awaits operator intent.
- **`restore-snapshot.sh:82-88`** — `aws s3 ls || echo "(none found)"` masks IAM AccessDenied as empty bucket. **Not fixed** — cosmetic UX trade-off.
- **`resolve-env.sh:62`** — `jq -r ".${1}"` technically allows jq-filter injection via `$1`, but `$1` is always a hardcoded string from internal callers. Defense-in-depth fix would be `--arg k "$1" '.[$k]'`. Low priority.

### False-positive patterns the audit over-reported (lessons)

The original agent audit flagged the following as bugs; all were verified with harnesses to be safe under `set -euo pipefail`:

- `cmd || echo "default"` — works correctly; `|| echo` DOES fire when pipefail propagates upstream failure
- `jq -e '.error'` inside an `if` condition — `set -e` is disabled in conditions (POSIX)
- `stat -f%z || stat -c%s || echo unknown` — works on macOS, Linux, and missing-file case
- `tofu <cmd>` / `aws <cmd>` / `vault <cmd>` as bare commands — `set -e` already halts on non-zero exit; explicit `|| check` is redundant
- `jq ... | length` on null — returns `0`, not `"null"`
- `while read ... < <(jq ...)` — process substitution isolates errors from set -e
- SIGKILL concerns — exit 137 propagates and triggers `||` fallbacks correctly

**Takeaway:** static pattern-matching produces too many false positives on shell scripts. Any future audit should require harness verification for every claim before fixes are applied.

---

## Discussion Notes

<!-- Freeform area for cross-cutting thoughts, meeting notes, decisions that span multiple findings -->

