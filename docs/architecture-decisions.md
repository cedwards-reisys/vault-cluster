# Architecture Decision Records

Signed-off design decisions for this Vault cluster. Each ADR captures the
rationale behind a choice that might otherwise be re-litigated by audits,
new contributors, or future versions of ourselves.

**Triage rule:** when an audit or proposal conflicts with an accepted ADR,
default to wontfix unless the proposal brings new information the ADR
doesn't already address. Link the finding to the ADR and move on.

Format loosely follows Michael Nygard's ADR template.

---

## ADR-001: Env tfvars and backend-configs are placeholders

**Status:** Accepted · 2026-04-29

**Context.** `terraform/environments/*.tfvars` and `terraform/backend-configs/*.hcl`
in this repo contain non-production placeholder values (bucket names like
`your-terraform-state-bucket`, CIDR like `10.0.0.0/8`, subnet IDs like
`subnet-aaaaaaaa`). Real values are injected at deploy time by Jenkins
pipelines or operator invocation.

**Decision.** Keep placeholders in the repo. Do not commit production values.
Values are intentionally fail-closed (RFC1918 CIDRs, clearly fake subnet IDs)
so that an accidental `tofu apply` without overrides does something safe
rather than something public.

**Consequences.** Any finding that claims "these values look wrong" or
"tofu init will fail" is incorrect relative to the deployment model. The
placeholders are load-bearing — they prevent real values from leaking and
force operators to supply them consciously.

**Related findings:** C1 (done — swapped 0.0.0.0/0 → 10.0.0.0/8 placeholder),
C3 (wontfix), H8 (wontfix — us-east-1 is correct for this project).

---

## ADR-002: Vault configuration lives in Jenkins pipelines, not Terraform

**Status:** Accepted (deferred to revisit post-migration) · 2026-04-29

**Context.** Resources inside Vault (auth methods, policies, auth roles,
audit devices) are configured by one-time Jenkins pipelines
(`setup-backup-auth.Jenkinsfile`, `setup-audit.Jenkinsfile`) run post-init.
They are NOT managed by `hashicorp/vault` Terraform provider.

**Decision.** Keep the Jenkins-based pattern through the nonprod/prod
migration. Revisit "port to terraform/vault-config/" after migration is
complete and the cluster is stable.

**Rationale.** Clean separation of concerns: AWS-infra TF has one provider,
no chicken-and-egg with Vault init. Rebuild-resilient: after a
fresh-deploy + snapshot-restore, there's no stale vault-config Terraform
state to reconcile. Migration-focused: introducing a new TF root mid-migration
adds cognitive load for no immediate benefit.

**Consequences.** No drift detection on Vault-internal resources. If someone
runs `vault policy write backup` manually, nothing notices. Compliance/audit
story is "read the Jenkinsfile" rather than "read the .tf." Accepted trade-off
for the current phase.

**Related findings:** C7 (wontfix — audit misread the architecture),
C7' (deferred — tracked as task #19).

---

## ADR-003: Secrets Manager entries are not auto-rotated

**Status:** Accepted · 2026-04-29

**Context.** `<cluster>/vault/root-token` and `<cluster>/vault/recovery-keys`
hold the cluster's DR credentials. AWS Secrets Manager supports automatic
rotation via Lambda. We do not use it.

**Decision.** No Secrets Manager auto-rotation. Operator-supervised quarterly
rotation via `scripts/rekey-recovery.sh`, tracked as the C6 quarterly drill.

**Rationale.** Auto-rotation of a value without rotating the underlying Vault
credential leaves SM holding a value Vault won't accept — DR breaks silently.
Auto-rotation that drives the Vault-side rekey via Lambda makes a Lambda the
critical path for DR credential integrity, with potential chicken-and-egg
failure modes. Neither is worth the risk for credentials that are used
precisely when something else has already gone wrong.

**Consequences.** Rotation cadence depends on operator discipline (the
quarterly drill). The drill exercises the rotation path on a known schedule
with human oversight, which is actually more reliable than a Lambda that
runs unattended and silently fails.

**Related findings:** H3 (wontfix), C6 (done + quarterly-drill task #18).

---

## ADR-004: AWS region is us-east-1

**Status:** Accepted · 2026-04-29

**Context.** All three environments (`nonprod-test`, `nonprod`, `prod`)
deploy to us-east-1. The operator's global tooling preference is us-east-2
for other projects, but this Vault cluster is not migrating.

**Decision.** us-east-1 is intentional and permanent for this project.

**Consequences.** Audits that reference "standardize on us-east-2" do not
apply here. Project-scoped memory recorded at
`~/.claude/projects/-Users-cedwards-Projects-vault-vault-cluster/memory/feedback_region.md`.

**Related findings:** H8 (wontfix).

---

## ADR-005: cold-start-cluster.sh is a reset tool, not a recovery tool

**Status:** Accepted · 2026-04-29

**Context.** `scripts/cold-start-cluster.sh` forces single-node Raft bootstrap
via `peers.json`, then relaunches remaining nodes with `rm -rf /opt/vault/data/*`
on their preserved EBS volumes. Writes that existed only on non-leader nodes
are lost.

**Decision.** This is the intended behavior. The script exists for deliberate
teardown/reset in nonprod-test during testing or demo resets. It is NOT a
data-preservation recovery tool for production.

**Rationale.** Confirmed by three parallel agent reviews (SRE, Vault docs,
community patterns):
- `hashicorp/raft` library's `RecoverCluster` godoc: "join other new
  clean-state peer servers using the standard APIs" — wipe is the
  documented pattern.
- `peers.json` recovery "implicitly commits uncommitted entries" per
  HashiCorp docs — flagged as last resort.
- Committed-on-follower-only writes are silently dropped on new-leader
  bootstrap, with or without a wipe.
- No public documentation of any operator doing convergence-check gating
  before wiping; community consistently wipes + lets Raft catch up.

**Consequences.** For production data recovery, operators must use the S3
snapshot restore path in [dr-lost-recovery-keys.md §Scenario 1](dr-lost-recovery-keys.md),
NOT `cold-start-cluster.sh`. The script's header has a SCOPE block making
this unambiguous.

**Related findings:** H11 (wontfix).

---

## ADR-006: Node certs rely on monthly rolling updates for freshness

**Status:** Accepted · 2026-04-29

**Context.** TLS certs for node-to-node communication are self-signed,
generated at boot by userdata with a 365-day lifetime. Nodes are replaced
as part of standard operational rotation (AMI updates, Vault version bumps,
config changes — all triggering a rolling update ~monthly).

**Decision.** No separate cert-expiry monitoring. Monthly rolls keep every
node cert refreshed to a fresh 365-day lifetime.

**Rationale.** Expiry would require ~11 consecutive months of no rolling
updates, which is implausible under normal ops. CA cert is 10-year, also
not an operational concern. Separate cert-expiry alerts would add complexity
for a risk that's already mitigated by existing process.

**Consequences (watch for).** If rolling updates pause for >10 months
(freeze window, blocked migration, forgotten procedure), node certs drift
toward expiry. Treat "last rolling update >180 days ago" as a warning
sign. Not automated because we should never be in that state.

**Related findings:** H13 (wontfix).

---

## ADR-007: Script-based fleet management, not ASG

**Status:** Accepted · 2026-04-29 (originally a C8 architectural finding)

**Context.** Node lifecycle is managed by scripts (`launch-node.sh`,
`terminate-node.sh`, `rolling-update.sh`) invoked by operators or Jenkins
pipelines. No Auto Scaling Group, no instance refresh, no Spot.

**Decision.** Keep script-based management. Revisit if rollout reliability
degrades past what's tolerable.

**Rationale.** ASGs with instance-refresh can replace all nodes
simultaneously, causing data loss with Raft storage. Stable per-AZ node IDs
and persistent EBS require deterministic replacement — which is what scripts
give us. Speed of replacement and debuggability of "what actually happened"
are higher value than automatic remediation for this cluster size (3 nodes
across 3 AZs).

**Consequences.** Manual intervention required for node failures. Quorum
protected by one-node-at-a-time replacement invariant enforced by the
scripts. Failure modes and defenses documented in
[docs/troubleshooting.md](troubleshooting.md).

**Related findings:** C8 (accepted — stay persistent, harden the scripts),
Phase 1 hardening work (#1, #5, #8 all shipped).

---

## ADR-008: Persistent EBS per AZ (not ephemeral)

**Status:** Accepted (will reconsider if rollout reliability degrades) · 2026-04-29

**Context.** Each AZ has a dedicated 200GB EBS volume attached to the Vault
instance in that AZ. Instance replacement keeps the volume; the new instance
mounts it and resumes the existing Raft identity. Three agent reviews in a
prior session all recommended switching to ephemeral; the operator rejected
after weighing failure modes.

**Decision.** Stay persistent. The EBS identity sentinel (Phase 1.2,
`userdata.sh.tpl`) defends against cross-cluster misattribution; the canary
check (Phase 1.3) defends against bad rollouts; the S3 snapshot +
dr-lost-recovery-keys.md runbook defends against multi-AZ loss.

**Rationale.** Fast node replacement (no snapshot restore on boot). Survives
single-AZ outages without data loss. Simpler mental model for operators.
Ephemeral would force a snapshot restore on every instance replacement and
make multi-AZ failure a data-loss event.

**Consequences.** Operators must understand that persistent EBS preserves
Raft state across instance replacement — this is usually a feature (stable
identity) but becomes a problem when topology genuinely changes (the
cold-start scenario, ADR-005). Must maintain Phase 1 hardening (sentinel,
canary) to keep rollouts reliable.

**Related findings:** C8 (accepted), EBS debate memory
`project_ebs_debate.md`, Phase 1 work (all done).

---

## ADR-009: NLB health check routes to leader only

**Status:** Open — not yet signed off

**Context.** NLB target group health check uses `/v1/sys/health` matcher=200.
Unmodified `/v1/sys/health` returns 200 only on the active leader; standbys
return 429. Result: NLB marks only the leader as healthy and routes all
client traffic to it.

**Decision (open).** Could be intentional (simplifies failover semantics,
avoids stale-read concerns) or inherited default. Marked **open** pending
operator review.

**If accepted:** add to this ADR the rationale, update H14 to wontfix.
**If rejected:** change NLB config to `/v1/sys/health?standbyok=true` to
distribute reads across all healthy nodes.

**Related findings:** H14 (open).

---

## ADR-010: Userdata stays inline, gzipped at launch

**Status:** Accepted · 2026-05-01 (updated to include gzip)

**Context.** EC2 user-data is capped at 16 KiB. Our rendered userdata grew
to ~14.4 KB (87% of limit) after accumulated additions: EBS sentinel (P1.2),
audit logrotate (H1), per-AZ stable node ID, auto-unseal config, embedded
backup script. A brief H5 experiment with runtime NVMe device detection
pushed the template over the limit and was reverted. To buy durable
headroom without moving to an AMI bake, `launch-node.sh` now gzips the
rendered userdata before passing it to `aws ec2 run-instances`.

**Decision.** Keep userdata inline. Gzip at launch time (cloud-init
decompresses transparently). The Terraform-generated `generated/userdata.sh`
stays plain-text on disk for debugging; only the wire payload is compressed.
Do not adopt AMI bake, `#include` from S3, or cloud-config multipart MIME
at this time.

**Rationale.**
- Gzip takes rendered size from 14.4 KB → ~5.5 KB (2.6x compression),
  leaving ~10.9 KB of headroom for future additions.
- No architectural change — cloud-init has decompressed gzipped user-data
  transparently since ~2011. Detected via gzip magic bytes (0x1f 0x8b)
  before the shebang or `#cloud-config` check.
- Plain file remains readable via `terraform/modules/vault-nodes/generated/
  userdata.sh` for inspection and diff.
- `launch-node.sh:prepare_userdata()` emits a startup log line reporting
  raw/compressed sizes and percentage of limit, and refuses to launch if
  even compressed userdata exceeds the limit.
- A baked AMI (deferred, see "Future options") would save ~9-11 KB of
  *rendered* size but adds a Packer pipeline. With gzip in place, AMI is
  no longer pressure-driven — it's a future optimization for boot speed
  and compliance, not for size relief.

**Future options (deferred).**

| Option | Savings | Cost | When to consider |
|---|---|---|---|
| AMI bake (Packer) | ~9-11 KB rendered, 60-70% faster boot | Packer pipeline, AMI artifact lifecycle | Post-migration, when boot speed matters for chaos testing or compliance asks |
| `#include` from S3 | Effectively unlimited | S3 dependency at boot, tamper vector | Only if gzip+AMI combined aren't enough |
| Cloud-config YAML (MIME multipart) | Declarative bits cleaner, ~same size | Refactor, two-format maintenance | Independent of size — revisit for readability when C7' ports Vault config to TF |

**Consequences.**
- Userdata size limit ≈ 10-11 KB post-compression headroom. Typical ~1 KB
  additions compress to ~300-500 bytes on the wire.
- `launch-node.sh:prepare_userdata()` will fail fast if compressed size
  ever exceeds 16 KiB — no silent truncation.
- A future operator looking at `aws ec2 describe-instances --attribute
  userData` will see base64-encoded gzip, not bash. Cloud-init logs at
  `/var/log/cloud-init.log` show the decompressed version.

**Previous fallback table (kept for reference during gzip decision).**

| Option | Savings | Cost |
|---|---|---|
| Gzip userdata (cloud-init auto-decompresses) | 3-5x (→ ~3-5 KB compressed) | None — transparent |
| `#include` script from S3 | Effectively unlimited | S3 dependency at boot, tamper vector |
| Cloud-config YAML (MIME multipart) | Declarative bits cleaner, ~same size | Refactor, two-format maintenance |
| Baked AMI (Packer) | ~9-11 KB | Packer pipeline, AMI artifact management, slower iteration |

**Watch for.** Any finding that proposes adding >500 bytes of userdata
logic should include a render-size check. If cumulative growth puts us
within 500 bytes of the cap, apply gzip as the first defensive step.

**Related findings:** H5 (wontfix/reverted — the NVMe detection function was
the trigger for establishing this ADR).

---

## Quick-reference: findings → ADRs

| Finding | Status | ADR |
|---|---|---|
| C1 | done | ADR-001 |
| C3 | wontfix | ADR-001 |
| C7 | wontfix | ADR-002 |
| C7' | deferred | ADR-002 |
| C8 | accepted | ADR-007, ADR-008 |
| H3 | wontfix | ADR-003 |
| H8 | wontfix | ADR-004 |
| H11 | wontfix | ADR-005 |
| H13 | wontfix | ADR-006 |
| H5 | wontfix | ADR-010 |
| H14 | open | ADR-009 (unsigned) |
| H17 | open | ADR-007 (probably wontfix per ADR) |

---

## Adding a new ADR

When a design decision comes up that's likely to be re-litigated:

1. Add a new section above "Quick-reference" with the next ADR number.
2. Use the Context / Decision / Rationale / Consequences / Related findings shape.
3. Status values: `Open` (pending review), `Accepted`, `Superseded by ADR-NNN`, `Deprecated`.
4. Update the Quick-reference table.
5. If the ADR closes open findings, mark them wontfix in
   [review-findings.md](review-findings.md) with a link back to the ADR.
