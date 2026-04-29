# DR Runbook — Lost Recovery Keys or Lost Root Token

**Scope:** This runbook covers two break-glass scenarios that cannot be fixed
by any script:

1. **Recovery keys LOST**, root token still held
2. **Root token LOST**, recovery keys still held
3. **BOTH lost** (hardest case)

For ordinary recovery-key *rotation* (you hold the current keys), use
`scripts/rekey-recovery.sh` — see [operations.md §Recovery Key Rotation](operations.md#recovery-key-rotation).

---

## Important: know the blast radius before you start

A cluster rebuild is **multi-hour** and visible to every app that uses
Vault. Before executing this runbook:

- Notify stakeholders (app teams, on-call, security). This is a controlled outage.
- Confirm you cannot reach recovery keys or root token anywhere:
  - AWS Secrets Manager at `<cluster>/vault/recovery-keys` and `<cluster>/vault/root-token`
  - Password manager / key vault of the prior operator
  - Sealed envelopes / HSM / offline backup
- Confirm snapshots exist and are recent (see
  [backups.md §Daily Validation](backups.md#daily-validation)).
- Pick a maintenance window.

If any of those are uncertain, STOP and investigate. The API deadlock is not
going anywhere; an improperly executed rebuild can lose data.

---

## Why no script fixes this

Vault's rekey / root-regen APIs require possession of the corresponding
credential to operate:

| API | Requires |
|---|---|
| `sys/rekey-recovery-key/init` + `/update` | current recovery keys |
| `sys/generate-root` (with recovery seal) | current recovery keys |

This is a deliberate security property — the recovery keys are the strongest
DR credential. A cluster that cannot prove possession cannot rotate them, and
no root token, IAM policy, KMS permission, or API flag bypasses this. The
only path through is to stand up a fresh cluster (which generates fresh keys
at `init`) and restore data from snapshot.

---

## Decision matrix

| Have | Lost | Path |
|---|---|---|
| Root token | Recovery keys | **Scenario 1** — Rebuild from snapshot. Root token is useful but not strictly required if you have snapshots. |
| Recovery keys | Root token | **Scenario 2** — Regenerate root token via `vault operator generate-root` + recovery keys. No rebuild needed. |
| Neither | Both | **Scenario 3** — Rebuild from snapshot. Root token loss is irrelevant because init generates a new one. |

---

## Scenario 1 — Recovery keys lost, root token held

### What you can still do with just a root token

- Read all secrets (if cluster is currently unsealed — KMS auto-unseal will
  keep it unsealed across restarts).
- Take snapshots: `vault operator raft snapshot save -`.
- Modify auth methods, policies, mounts.

### What you CANNOT do

- Rotate recovery keys (`rekey-recovery.sh` will fail at the "enter current
  keys" prompt).
- Regenerate a root token later if this one is lost — `generate-root` also
  requires recovery keys.
- Rebuild the cluster in-place. Recovery keys are baked into the seal
  metadata; they can only change via init.

### Execute rebuild

Follow the standard migration procedure. Treat the current cluster as the
"old" cluster and provision a new one.

**Step 0 — Take a fresh snapshot before you start:**

```bash
export VAULT_ADDR="https://vault.<env>.reisys.io"
export VAULT_TOKEN="<root-token>"

# Emergency snapshot labelled for provenance
vault operator raft snapshot save \
  /tmp/vault-prebreakglass-$(date -u +%Y%m%d-%H%M%S).snap

# Copy to S3 under a clearly labelled prefix
aws s3 cp /tmp/vault-prebreakglass-*.snap \
  s3://vault-<env>-backups/<cluster>/break-glass/
```

**Steps 1-7 — Follow the existing migration runbook:**

[migration.md §Migration Steps](migration.md#migration-steps) — the
"fresh deploy + restore" flow is identical to what this scenario needs. The
only differences:

- You're replacing a *running* cluster, not a 1.9.0 legacy one, so no version
  research is required.
- Recovery keys and root token for the new cluster come from `vault operator
  init` (steps 5-6 of migration.md).
- Update DNS in step 11 to cut traffic to the new cluster. Leave the old one
  up and sealed (not terminated) until validation is complete — you may need
  to take another snapshot.

**Step 8 — Store the NEW credentials immediately:**

```bash
./scripts/store-vault-credentials.sh <env>
# Paste the NEW root token and recovery keys from init output.
```

**Step 9 — Retire the old cluster:**

Only after the new cluster has validated, DNS has propagated, and at least one
full daily backup cycle has run on the new cluster:

```bash
VAULT_ENV=<env> ./scripts/terminate-node.sh --all
```

### RTO estimate

- Fresh deploy: ~15 min
- Snapshot restore + peer join: ~5 min
- Validation + DNS cutover: ~30 min (+ DNS propagation wait, up to TTL)
- **Total: roughly 1-2 hours** operator-driven. Page on-call, this is not a
  solo task.

---

## Scenario 2 — Root token lost, recovery keys held

You can regenerate a root token WITHOUT rebuilding. Vault supports this via
`generate-root` with recovery-key threshold.

### Prerequisites

- Recovery keys accessible (threshold count, usually 3 of 5)
- Cluster is unsealed (KMS auto-unseal keeps it unsealed)

### Procedure

The `generate-root` flow is a 4-step stateful operation on the server, tracked
by a nonce. Each step is a separate `vault` call.

```bash
export VAULT_ADDR="https://vault.<env>.reisys.io"

# 1. Generate a one-time password. The OTP XOR-encrypts the new token before
#    the server returns it — prevents the token from appearing on the wire
#    in plaintext.
OTP=$(vault operator generate-root -generate-otp)

# 2. Initialize the operation with that OTP. Capture the nonce.
NONCE=$(vault operator generate-root -init -otp="$OTP" -format=json | jq -r '.nonce')

# 3. Submit recovery keys one at a time. The threshold is usually 3 of 5.
#    The last call returns `.encoded_token`.
vault operator generate-root -nonce="$NONCE" <recovery-key-1>
vault operator generate-root -nonce="$NONCE" <recovery-key-2>
ENCODED=$(vault operator generate-root -nonce="$NONCE" -format=json <recovery-key-3> \
  | jq -r '.encoded_token')

# 4. Decode the encoded token using the OTP to get the usable root token.
NEW_ROOT=$(vault operator generate-root -decode="$ENCODED" -otp="$OTP")

echo "NEW ROOT TOKEN: $NEW_ROOT"

# 5. Store it in Secrets Manager.
./scripts/store-vault-credentials.sh <env>
# Paste the new root token. Skip the recovery-keys prompt (unchanged).

# 6. Revoke the old token IF it is ever recovered later. Not required — but
#    good hygiene since the old token remains valid until its TTL expires:
# VAULT_TOKEN="$NEW_ROOT" vault token revoke <old-token>
```

### If the operation gets wedged mid-way

The server tracks the in-progress operation by nonce. A fresh `-init` is
rejected while one is already running. To reset and start over:

```bash
# Check current state
vault operator generate-root -status

# Abort an in-progress operation
vault operator generate-root -cancel
```

### Non-interactive submission

Any recovery key can be piped via stdin instead of passed as a positional
argument — useful if the key contains shell-unsafe characters or you're
reading from a secure source:

```bash
echo "<recovery-key>" | vault operator generate-root -nonce="$NONCE" -
```

### RTO estimate

- Roughly 10 minutes of operator work, no cluster rebuild, no downtime.

### Official reference

HashiCorp docs:
https://developer.hashicorp.com/vault/tutorials/operations/generate-root

---

## Scenario 3 — Both lost

This is Scenario 1 with no root token. Mechanics:

- You cannot take a fresh snapshot from the running cluster (root token
  required to call `snapshot save`). Fall back to the most recent S3
  snapshot from the automated backup timer.
- Every other step is identical to Scenario 1.

### Additional risk

If the most recent S3 snapshot is stale (e.g., backup timer was also broken
for some time), you will lose writes made after that snapshot. Check
[backups.md §Daily Validation](backups.md#daily-validation) metrics for
snapshot age before proceeding — if `AgeHours` is large, escalate before
rebuilding.

### RTO estimate

Same as Scenario 1 (~1-2 hours), with additional RPO loss if snapshots
are stale.

---

## After any of these

1. Update the Secrets Manager entries at `<cluster>/vault/root-token` and
   `<cluster>/vault/recovery-keys`.
2. Audit the `audit/` device log (if configured — see [H1 finding](review-findings.md))
   to confirm no malicious activity occurred during the key-loss window.
3. Post-mortem: how did the keys get lost? Update this runbook with what was
   useful / not useful during the exercise.
4. Schedule a quarterly rotation drill using `scripts/rekey-recovery.sh` to
   ensure recovery keys are in Secrets Manager AND that operators know how
   to retrieve them.

---

## Prevention

Lost-keys is a process failure, not an inevitable one. Controls:

- **Init-time storage:** `scripts/store-vault-credentials.sh` should be the
  very first thing run after `vault operator init`. It writes to AWS
  Secrets Manager (`<cluster>/vault/recovery-keys`, `<cluster>/vault/root-token`).
- **Least-access audit:** Secrets Manager access to those paths should be
  narrow. Review IAM policies granting `secretsmanager:GetSecretValue` on
  `arn:aws:secretsmanager:*:*:secret:<cluster>/vault/*`.
- **Quarterly drill:** run `scripts/rekey-recovery.sh` every quarter.
  Confirms that (a) the keys in Secrets Manager are valid, (b) operators
  know how to retrieve them, (c) the rotation path works before you need it.
- **Do not store keys outside Secrets Manager without a compensating
  control.** Email, chat history, desktop files — these are how keys get
  lost.

---

## References

- [operations.md §Recovery Key Rotation](operations.md#recovery-key-rotation)
  — the normal (not break-glass) rotation path
- [migration.md](migration.md) — full rebuild-from-snapshot procedure
- [backups.md](backups.md) — snapshot cadence, validation, and restore
- [review-findings.md §C6](review-findings.md#c6-recovery-key-rekey-deadlock--no-fast-path-if-keys-lost)
  — why this runbook exists
- [HashiCorp: generate-root](https://developer.hashicorp.com/vault/tutorials/operations/generate-root)
- [HashiCorp: rekey](https://developer.hashicorp.com/vault/docs/commands/operator/rekey)
