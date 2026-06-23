# Interview Talking Points — NiaHealth Compliance MVP

> The interview-prep document. The 5-bullet pitch, the 3 architectural tradeoffs, the 2 known gaps, and the 1 question you'll be asked with a 60-second pre-rehearsed answer. Designed to be re-read in the 10 minutes before a technical round, not to be memorized.
>
> **How to use this document.** The 5-bullet pitch is the same one in [`README.md`](../README.md); the tradeoffs and gaps are the "depth" that an interviewer probes when they ask "tell me more about X." The 1 pre-rehearsed question is the question every HealthTech security interview asks; having a clean, time-boxed answer is the difference between "I can wing it" and "I've thought about this."
>
> **Calibration.** The interview for a Security, Infrastructure & Compliance Lead at a Canadian HealthTech typically has 3 rounds: a 30-min technical round (the one this document targets), a 60-min system-design round, and a 30-min culture/values round. The 5-bullet pitch fits the 30-min technical round; the 3 tradeoffs are the "tell me more" depth probes; the 1 pre-rehearsed question is the "what would you do if…" scenario.

---

## The 5-bullet pitch (60-90 seconds, end to end)

The full version lives in [`README.md`](../README.md#what-this-proves-in-an-interview). The compressed, memorizable version:

1. **Least-privilege IAM with permission boundaries + a single break-glass user.** Four per-service IAM roles, each with a tightly-scoped inline policy AND a permission boundary that denies `iam:Create*`, `iam:Attach*`, `kms:*`, and wildcard-on-wildcard. One break-glass IAM user with `AdministratorAccess` + explicit denies on `iam:CreateAccessKey` / `iam:UpdateAssumeRolePolicy` / `kms:ScheduleKeyDeletion`, and every console login pages the on-call SNS topic.
2. **KMS key per blast-radius domain with explicit `Deny` on `kms:ScheduleKeyDeletion`.** Four customer-managed CMKs (RDS, S3-PHI, CloudTrail, CloudWatch Logs), each with annual `enable_key_rotation = true`, and the key policy has an explicit `Deny` on `kms:ScheduleKeyDeletion` for non-admin principals — so a compromised service role can encrypt/decrypt (which it needs to do) but cannot silently destroy the key that protects PHI.
3. **S3 Object Lock COMPLIANCE mode with 7-year retention on the audit bucket.** Even the account root cannot delete a COMPLIANCE-locked object before retention expires. This is the audit-immutability invariant — the difference between "logs survive an insider" and "logs survive a regulator subpoena for 7 years."
4. **A regulator-ready breach response runbook with copy-paste IPC, OPC, and CAI notification templates.** T0 detection → T+1h triage → T+2h containment → T+24h investigation → T+72h notification → T+1w post-incident, with templates that cite the specific clauses (PHIPA s.13(1), PIPEDA Sch.1 §4.7, Law 25 §3.1). Designed to be followed by a new engineer on day 1.
5. **A CI pipeline that runs Checkov, tflint, OPA/Conftest, and an Inspector CVE gate, all via OIDC with no long-lived AWS keys.** The PR pipeline posts the `terraform plan` as a comment and uploads Checkov's SARIF to Code Scanning. The apply is gated on a `production` environment approval in the GitHub UI.

The 5 bullets are specific. Each one names a file in the repo, names a specific AWS resource, and names a specific clause or behavior. An interviewer can drill into any bullet and the answer is "let me show you the file" + a `cat`.

---

## The 3 architectural tradeoffs (and why we made the choice we did)

Every architecture is a set of tradeoffs. The 3 most-defensible tradeoffs in this project are the ones an interviewer will probe. Each one is structured as: **the question → the decision → why → what we'd revisit in a "Substantial" tier expansion.**

### Tradeoff 1: Single-region RDS + S3 CRR, not multi-region Aurora

**The question.** Why single-region RDS Postgres in `ca-central-1` with cross-region S3 replication to `ca-west-1`, instead of a multi-region active-active Aurora global cluster?

**The decision.** Single-region RDS Postgres (in isolated subnets, multi-AZ within the region) for the data plane; cross-region S3 replication for the data-tier PHI bucket (and the audit bucket's lifecycle → Glacier IR is the long-term cold tier).

**Why.**
- **Cost.** Aurora global database is ~$1,000+/month for a single writer + replica. Single-region RDS Postgres is ~$70-150/month for the equivalent compute + storage. The MVP runs at $0 (terraform-only); a real HealthTech at scale would re-evaluate.
- **Operational complexity.** Multi-region active-active has a non-trivial split-brain risk profile and requires per-region read-write conflict resolution. Single-region + CRR is a known-good pattern; the cross-region restore is a documented playbook (see the runbook's "deferred to follow-up work" note).
- **Data residency is satisfied.** Both `ca-central-1` and `ca-west-1` are in Canada. Quebec Law 25 §28.1 (cross-border express consent) is satisfied because no PHI ever leaves Canada. A US region is not used for PHI under any path.

**What we'd revisit in a "Substantial" tier expansion.** For a HealthTech with a real production load and an SLA that demands sub-hour RTO, Aurora global database is the right answer. The Terraform structure (per-layer modules, OIDC deploy roles, Checkov gating) is multi-region-ready; the cost is the constraint, not the architecture.

**The file that backs this decision.** [`infra/modules/data/rds.tf`](../infra/modules/data/rds.tf) for the single-region RDS; [`infra/modules/data/lifecycle.tf`](../infra/modules/data/lifecycle.tf) for the cross-region S3 replication.

### Tradeoff 2: A single break-glass IAM user, not full IdC for emergencies

**The question.** Why have a single break-glass IAM user at all? Why not require IdC for everything, including emergencies?

**The decision.** One IAM user (`niahealth-{env}-break-glass`) with `AdministratorAccess` + a virtual MFA device, stored in Secrets Manager, with an explicit `Deny` on `iam:CreateAccessKey` / `iam:UpdateAssumeRolePolicy` / `kms:ScheduleKeyDeletion` / unauthenticated `s3:DeleteObject` on the audit and state buckets. Every console sign-in events pages the on-call SNS topic within 60s.

**Why.**
- **IdC can go down.** Rare but possible: account-level outage in the IdC control plane, or a misconfigured permission set that locks out the admin group. The team needs a path back in that does not depend on IdC being available.
- **The MFA + paging compensate for the breadth.** `AdministratorAccess` is intentionally wide; the MFA device is the friction, the EventBridge rule on `aws.console-login` is the audit trail, and the explicit denies ensure the break-glass session cannot burn the bridge (no creating long-lived keys, no widening trust policies, no deleting KMS keys, no deleting audit evidence).
- **The break-glass is for emergencies, not for daily use.** If the on-call rotation is reaching for the break-glass more than once a quarter, the IdC posture is the problem, not the break-glass.

**What we'd revisit.** If the IdC control plane were ever shown to be unreliable (it has not been, as of 2026-06-23), the break-glass scope would narrow. If the on-call rotation was using the break-glass for non-emergency work, the IdC permission sets would expand to cover the gap. The break-glass is a *symptom* of the IdC posture; a healthy IdC posture means the break-glass is rarely used.

**The file that backs this decision.** [`infra/modules/identity/break_glass.tf`](../infra/modules/identity/break_glass.tf). The header comment in that file documents the trade-off explicitly.

### Tradeoff 3: Object Lock COMPLIANCE mode on the audit bucket, not GOVERNANCE

**The question.** Why Object Lock COMPLIANCE mode (not GOVERNANCE) on the audit S3 bucket? Isn't COMPLIANCE more rigid than we need?

**The decision.** The audit bucket (`niahealth-audit-{env}`) has `object_lock_enabled_for_bucket = true` with default retention 7 years, COMPLIANCE mode. **Even the account root cannot delete a COMPLIANCE-locked object before retention expires.** GOVERNANCE mode would allow root to bypass.

**Why.**
- **The audit trail is the regulator's evidence.** The 7-year retention is set higher than current PIPEDA guidance (the most-restrictive framework in scope) so future guidance changes do not force a re-architecture.
- **GOVERNANCE mode is "best-effort immutability."** It works against an external attacker, but not against a malicious insider with root credentials. The threat model for the audit bucket includes the insider; COMPLIANCE mode is the only mode that survives that threat.
- **The cost of being too rigid is the cost of waiting for retention to expire.** For a real destroy, an operator-driven process is required; for a real audit, the evidence is guaranteed to be there. The first is rare; the second is constant.

**What we'd revisit.** If a regulator explicitly required retention less than 7 years (none does, as of 2026-06-23), the default retention would shorten. If the audit-bucket objects needed lifecycle expiration (they do not — the audit data is regulator-grade, not cost-grade), the lifecycle rule would override. Neither is true today.

**The file that backs this decision.** [`infra/modules/observability/s3_archive.tf`](../infra/modules/observability/s3_archive.tf). The header comment in that file documents the COMPLIANCE-vs-GOVERNANCE choice explicitly.

---

## The 2 known gaps (be honest)

The architecture has known gaps. An interviewer who has read the repo will find them; better to surface them yourself and have a remediation plan than to be surprised. The 2 most-defensible gaps:

### Gap 1: Macie is daily, not real-time. A worst-case find in hour 1 is found in hour 24.

**The gap.** Amazon Macie's daily discovery job means a worst-case data-exposure event (an object written to a public S3 bucket at minute 0) is classified at minute 1440 (24h later) at the earliest. The 72h PIPEDA / OPC breach-report clock therefore starts at minute 1440, not at minute 0. The T+24h phase in the breach runbook is the regulator-determination phase; the T+72h phase is the notification phase. The actual response window is 48 hours (1440 minutes of MTTD + 2880 minutes of PIPC clock − 1440 minutes = 48 hours).

**Why it's a gap.** A 48-hour response window for a public-bucket breach is tight. The runbook works at 48h, but it has no slack. A 4-hour Macie MTTD would give 68h of response window; a 1-hour MTTD would give 71h.

**The remediation.** Replace the daily Macie job with an **event-driven detection path**: S3 Event Notifications → Lambda → Macie sensitive-data-event-driven detection. Macie supports sensitive-data discovery as an event-driven API (not just the daily batch job); the event-driven path compresses the MTTD from 24h to minutes. The Terraform structure for the new module is straightforward; the work is in the Macie + Lambda wiring, not in the surrounding infra.

**Why we did not fix it in the MVP.** Time + scope. The event-driven Macie path is a 1-2 week build on its own (the Lambda needs to handle Macie's async sensitive-data API, the EventBridge rule needs to filter for high-confidence matches, the false-positive rate needs tuning). The daily job is good enough for the MVP; the event-driven path is the natural first follow-up.

**The file that backs this gap.** [`infra/modules/observability/macie.tf`](../infra/modules/observability/macie.tf) (the daily job) and the MTTD preamble in [`RUNBOOKS/breach-rds-snapshot-leak.md`](../RUNBOOKS/breach-rds-snapshot-leak.md).

### Gap 2: The Inspector gate requires an auditor role that does not exist yet. The gate runs as a no-op until the role is added.

**The gap.** The PR pipeline at [`infra/.github/workflows/plan.yml`](../infra/.github/workflows/plan.yml) has a load-bearing "GUARD: Inspector2 scan" step that fails the build if the ECR image about to deploy has any unmitigated CRITICAL/HIGH CVE finding. The step assumes a separate read-only `auditor_role.tf` in [`infra/modules/landing/`](../infra/modules/landing/) that the landing module does NOT yet create. Until the auditor role is added + the `AUDITOR_ROLE_ARN` repo variable is set in the GitHub UI, the gate runs as a no-op with a warning (the step has `continue-on-error: true`).

**Why it's a gap.** The Inspector gate is the supply-chain control the plan calls out as load-bearing. The gate is wired correctly; the identity that the gate assumes is not yet created. A real HealthTech would have the gate enforced; the MVP has the gate's wiring but not the identity behind it.

**The remediation.** Add `infra/modules/landing/auditor_role.tf` with a read-only IAM role that has `inspector2:ListFindings` + `ecr:DescribeImages` + `ecr:GetRepositoryPolicy`. The role's trust policy pins `workflow_file: infra/.github/workflows/plan.yml` (the same pattern as the deploy role). The PR pipeline's Inspector step removes `continue-on-error: true`. The work is ~30 lines of Terraform + a repo-variable update in the GitHub UI.

**Why we did not fix it in the MVP.** Scope discipline. The landing module was owned by U2; the Inspector gate was added in U8. The follow-up to add the auditor role is a 1-PR change that did not make it into the U2 / U8 work; it is documented as the natural first follow-up in the post-incident template's "Control gaps" section (for any incident where the gate's no-op status is material).

**The file that backs this gap.** The "GUARD: Inspector2 scan" step in [`infra/.github/workflows/plan.yml`](../infra/.github/workflows/plan.yml), with the activation gate documented in the step's `if [ -z "${AUDITOR_ROLE_ARN}" ]` block.

---

## The 1 question you'll be asked (with a 60-second pre-rehearsed answer)

The question every Canadian HealthTech security interview asks: **"How would you respond to a ransomware attack on the production database?"** The interviewer is not looking for a 30-minute answer; they are looking for a 60-second answer that demonstrates you have thought about the actual sequence of events, the trade-offs, and the regulator-engagement path.

**The 60-second answer.**

> "A ransomware attack on the production database is a `deletion_protection = true` + Object Lock COMPLIANCE + cross-region replica story before it is a response story. RDS has deletion protection on, automated backups are retained for 35 days, the cross-region S3 replica is in `ca-west-1` Calgary and is reachable even if `ca-central-1` is fully compromised, and the audit trail is in an Object-Lock-COMPLIANCE bucket that even the account root cannot tamper with. So the first move is: do not pay the ransom.
>
> The response is T0 detection (a GuardDuty finding on the anomalous RDS API activity or a Macie finding on a now-public snapshot) → T+1h triage (confirm the encryption / confirm the blast radius / confirm the replica is intact) → T+2h containment (rotate the database master password, force a new RDS snapshot, freeze the write path at the ECS task role level) → T+24h investigation (timeline from CloudTrail, scope of the encryption, jurisdiction determination: IPC for Ontario, OPC for federal, CAI for Quebec) → T+72h notification to the regulators using the breach runbook's copy-paste templates → T+1w post-incident report with control gaps and follow-up action items. The full sequence is in `RUNBOOKS/breach-rds-snapshot-leak.md`; the ransomware scenario follows the same structure.
>
> The honest gaps are: a worst-case Macie MTTD is 24h, so the actual response window is 48h, not 72h; and the Inspector CVE gate in the PR pipeline is currently a no-op because the auditor role is not yet created. Both are documented as the first two follow-up items."

That answer is 60 seconds. It names the controls by ID (C5, C10, C15), names the runbook by file path, names the two known gaps, and ends with a forward-looking statement ("both are documented as the first two follow-up items"). An interviewer who wants depth can drill into any of those threads; an interviewer who wants breadth gets the full picture in 60 seconds.

**Variations the interviewer might use** (and how to pivot):

- "What if the encryption key was also compromised?" → The four CMKs are scoped per blast-radius domain; the KMS key policy has an explicit `Deny` on `kms:ScheduleKeyDeletion` for non-admins, and `enable_key_rotation = true` means the encryption envelope rotates annually. A compromised CMK still leaves the historical encryption envelope intact; rotation forces the next window of operations onto a new envelope. The blast radius is "this key domain" (RDS, S3-PHI, CloudTrail, or CWL), not "the entire account."
- "What if the attacker exfiltrated data *and* encrypted the database?" → That is a data-breach + ransomware scenario, not ransomware alone. The T+24h investigation phase enumerates both; the regulator determination is "data was accessed AND encrypted," which is reportable to IPC + OPC + CAI under the same clauses (PHIPA s.13(1), PIPEDA Sch.1 §4.7, Law 25 §3.1).
- "What if IdC is down at the same time as the attack?" → The break-glass user (C12) is the path back in. The break-glass has `AdministratorAccess` + explicit denies on the actions that would burn the bridge, and every console login pages the on-call SNS topic. The break-glass is for emergencies; this is one.

---

## How to rehearse

A 30-minute rehearsal the day before the interview is the difference between "I can talk about this" and "I can run the conversation."

1. **Read the 5-bullet pitch out loud, twice.** Time it: 60-90 seconds. If you are over 90 seconds, cut a bullet. If you are under 60, the bullets are too thin.
2. **Pick one tradeoff. Walk it end to end.** The decision, the why, the what-we'd-revisit. 2-3 minutes per tradeoff. The interviewer will probe at least one; you should have the structure memorized.
3. **Pick one gap. Walk the remediation plan.** The MTTD or the Inspector gate — pick one, walk the file path + the lines of Terraform + the follow-up PR. 2-3 minutes. The interviewer will probe at least one gap; you should have a clean "here is what I would change" answer.
4. **Deliver the 60-second ransomware answer to a friend.** A friend who has not seen the project. If they can summarize back to you in 30 seconds what you just said, the answer is clean. If they cannot, the answer is too long or too jargon-heavy.
5. **Re-read the runbook's T+1h decision tree and the regulator notification templates the morning of.** The templates are copy-paste-ready; the decision tree is the structure the interview is testing.

---

## Related documents

- [`README.md`](../README.md) — The 30-second elevator pitch + the 5 bullets + the "what this is NOT" disclaimers.
- [`CONTROLS.md`](../CONTROLS.md) — The 15-control matrix. The 5-bullet pitch references the control IDs (C1, C2, etc.); the matrix is the deep dive.
- [`RUNBOOKS/breach-rds-snapshot-leak.md`](../RUNBOOKS/breach-rds-snapshot-leak.md) — The canonical breach scenario. The 60-second ransomware answer is a variation on this runbook.
- [`RUNBOOKS/README.md`](../RUNBOOKS/README.md) — The on-call rotation + the first-5-minutes checklist. The interview will probe "what happens when the alert fires"; this is the answer.

---

*Last reviewed: 2026-06-23. Author: the NiaHealth compliance MVP project. License: see [`README.md`](../README.md) (MIT, pending the addition of a `LICENSE` file).*
