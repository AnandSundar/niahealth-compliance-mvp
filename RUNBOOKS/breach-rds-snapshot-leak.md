# RUNBOOK — RDS Snapshot Leak to Public S3

> **Canonical incident scenario** for the NiaHealth compliance MVP. Walks the response from T0 detection (a Macie finding on a now-public RDS snapshot in `s3://niahealth-backups/`) through T+1h triage, T+2h containment, T+24h investigation, T+72h regulator notification, and T+1w post-incident. Each phase has a checklist, a decision tree, and a "what could go wrong here" callout. Designed to be followed by a new engineer on day 1 — no institutional knowledge required.

---

## Glossary (read this first if you are not familiar with the Canadian privacy stack)

| Term | Meaning |
|------|---------|
| **PHIPA** | Ontario's *Personal Health Information Protection Act, 2004* (S.O. 2004, c. 3, Sched. A). Applies to "health information custodians" handling Ontarians' health data. |
| **PIPEDA** | The federal *Personal Information Protection and Electronic Documents Act*. Applies to commercial activity across Canada, including federally-regulated work. |
| **Law 25** | Quebec's *Act to modernize legislative provisions as regards the protection of personal information* (*Loi 25*). Applies to any organization that handles Quebec residents' personal information, regardless of where the organization is located. |
| **IPC** | Information and Privacy Commissioner of Ontario. The PHIPA regulator. Receives breach reports under **PHIPA s.13(1)**. |
| **OPC** | Office of the Privacy Commissioner of Canada. The PIPEDA regulator. Receives breach reports under **PIPEDA Schedule 1 §4.7** and the breach-reporting provisions. |
| **CAI** | *Commission d'accès à l'information* du Québec. The Quebec Law 25 regulator. Receives breach reports under **Law 25 §3.1**. |
| **RROSH** | "Real Risk of Significant Harm" — the PIPEDA test (Schedule 1 §4.7.3) for whether a breach is reportable to the OPC and to affected individuals. A breach is reportable when it is reasonable to believe the breach creates a real risk of significant harm to an individual. |
| **PHI** | Personal Health Information. PHIPA's term. In PIPEDA, the broader term is "personal information" (PI). The two overlap heavily for health data. |
| **RDS snapshot** | A point-in-time copy of an Amazon RDS database. Created automatically (by RDS's backup window) or manually (by `aws rds create-db-snapshot`). Stored in S3, owned by the AWS account. |
| **Macie** | Amazon Macie — a data-classification service that uses pattern matching + ML to find sensitive data (PHI, PII, credentials) in S3 buckets. |
| **MTTD** | Mean Time To Detect. The 24h MTTD for Macie means a worst-case data-exposure event is classified within 24 hours of the object being written to S3. |
| **PIPC breach-report clock** | The 72-hour clock that PIPEDA sets from the moment the organization determines the breach meets the RROSH threshold, to the moment the OPC + affected individuals must be notified. This runbook treats the clock as starting at **T0+24h (after Macie classification)**, not at the original object-exposure time. See "The MTTD assumption" preamble below. |
| **Object Lock COMPLIANCE mode** | An S3 bucket property that prevents any deletion (even by the account root) of an object before its retention expires. The audit bucket in this architecture uses COMPLIANCE mode with 7-year retention. |
| **CMK** | Customer-Managed Key (AWS KMS). One CMK per blast-radius domain in this architecture. |

---

## Preamble — the MTTD assumption (read this BEFORE the timeline)

This runbook assumes a **24-hour Mean Time To Detect (MTTD)** from the moment a sensitive object is written to a public-readable S3 location, to the moment Amazon Macie's daily classification job produces a Security Hub finding that triggers the paging EventBridge rule. This is the documented MTTD in [`infra/modules/observability/macie.tf`](../infra/modules/observability/macie.tf):

```hcl
# MTTD target: 24h from object write to Macie finding (the 72h
# PIPC breach-report clock starts T0+24h after Macie confirms
# discovery, NOT at first put -- the runbook documents the
# T0/T24/T72 timeline).
```

The **72-hour PIPEDA / OPC breach-report clock** therefore effectively starts at **T0+24h** — the moment Macie classification is the organization's first confirmed signal of the breach — **NOT** at the original object-exposure time. The IPC (under PHIPA) and CAI (under Law 25) clocks are not strictly 72h; PHIPA requires notice "as soon as possible" after the custodian knows of the breach, and Law 25 §3.1 sets a 72-hour "with diligence" threshold. The 24h MTTD assumption is load-bearing because:

1. Without it, the response timeline is impossible to plan (you cannot page a regulator at T-48h on an event that has not been detected).
2. With it, the T+24h phase in this runbook IS the regulator-determination phase — the phase where the on-call engineer decides whether the breach is reportable, which regulator(s) have jurisdiction, and who the affected individuals are.
3. The 24h MTTD is the cost of the chosen detection path (Macie daily jobs). A future iteration could add Macie sensitive-data-event-driven detection (a near-real-time path) which would compress the MTTD to minutes and re-anchor the 72h clock to the original exposure time.

**The "T0" in the timeline below is the Macie finding, NOT the original S3 PutObject.**

---

## TL;DR (one paragraph)

A Macie finding fires on a now-public RDS snapshot in `s3://niahealth-backups/` at T0. The Security Hub → EventBridge → SNS paging chain wakes the on-call within an hour. By T+1h the on-call has verified the finding, pulled the bucket policy + the snapshot's lifecycle, scoped the data to a specific RDS instance + table set, and classified the breach as reportable (RROSH met). By T+2h the public access is revoked, a forensic copy of the snapshot is made, all credentials with access to the snapshot are rotated, and the break-glass user is forced offline. By T+24h the timeline is built from CloudTrail, the affected records are enumerated, and the regulator determination is made (PHIPA → IPC; PIPEDA → OPC; Law 25 → CAI). By T+72h the IPC, OPC, and CAI have all received written notification, and affected individuals have received notice at their last known address per PHIPA s.13(1). By T+1w the post-incident report is filed, control gaps are catalogued, and follow-up audits are scheduled.

---

## Phase 0 — Pre-incident (you are reading this in a quiet moment)

The single best thing you can do for an incident response is have the pre-incident housekeeping done. Before any alert fires:

- [ ] **Subscribe to the paging SNS topic.** The SNS topic ARN is `arn:aws:sns:<region>:<account>:niahealth-<env>-paging` (owned by [`infra/modules/identity`](../infra/modules/identity/)). The subscription list is owned by the on-call rotation, not by Terraform. See [`RUNBOOKS/README.md`](README.md) for how to subscribe / unsubscribe.
- [ ] **Print the break-glass envelope.** Run `infra/scripts/break-glass-envelope.sh.tpl` once per environment per quarter. The envelope is the only path to console access if IdC is down. The orchestrator script retrieves the password + MFA seed from Secrets Manager — never commit them.
- [ ] **Bookmark the regulator contact details.** IPC, OPC, CAI contact details, hours, escalation paths, and online breach-report submission URLs are in the **Appendix** at the bottom of this runbook.
- [ ] **Rehearse the runbook once per quarter.** A 15-minute tabletop walkthrough is the difference between "I have a runbook" and "I can run an incident." Schedule a recurring 30-min calendar block with the on-call rotation.
- [ ] **Confirm CloudTrail is logging.** The T+24h investigation phase is *entirely dependent* on CloudTrail having the data. Run `aws cloudtrail describe-trails --query 'trailList[?IsMultiRegionTrail==\`true\`].Name'` and confirm the trail status is `IsLogging = true`.

---

## T0 — Detection (the Macie finding lands)

**What fires:** Macie's daily discovery job (per [`infra/modules/observability/macie.tf`](../infra/modules/observability/macie.tf)) classifies the public RDS snapshot as containing PHI, publishes a finding to Security Hub, the Security Hub → EventBridge rule (`securityhub_critical_high` per [`infra/modules/observability/securityhub.tf`](../infra/modules/observability/securityhub.tf)) matches the finding on `severity = CRITICAL|HIGH`, and an SNS message is published to the paging topic. The on-call engineer's phone buzzes.

**The page lands. You have 5 minutes before you need to be talking.** These are the first 5 actions, in order:

- [ ] **1. Acknowledge the page in the paging system.** Stops the escalation timer. Even if you are alone on the on-call rotation, acknowledge — the system will page your backup if you do not.
- [ ] **2. Open the Security Hub finding in the console.** The finding ID is in the SNS message body. Note: `Severity`, `ResourceType`, `Resource.Id`, `Sample` (the actual data that triggered the match), and the `GeneratorId` (which Macie job + which managed data identifier fired).
- [ ] **3. Do not touch the public S3 bucket yet.** Your first instinct will be to make the public bucket private immediately. **Do not.** Containment without forensics is the worst outcome — you destroy the evidence of the original exposure time and the access trail. Continue to step 4.
- [ ] **4. Start a war-room.** Open a dedicated Slack channel `#incident-YYYY-MM-DD-rds-snapshot-leak` (or your incident-channel equivalent). The T+1h triage phase will populate the timeline here.
- [ ] **5. Page your manager + legal + the privacy officer.** This is a reportable-data-class breach candidate. The first 24 hours are when the decisions get made that determine whether the regulator is engaged. Get the right people in the room *now*, not at T+12h.

### T0 — Decision tree

```
Is the Macie finding on the production RDS snapshot bucket?
├── YES -> Continue to T+1h triage. (This runbook is the canonical scenario.)
└── NO (a different bucket, a different classification)
    -> Open the finding, pull the bucket name + object key, and re-evaluate.
       The same phases apply, but the regulator determination is faster
       if the bucket is metadata-only (no PHI, no reportability).
```

### T0 — "What could go wrong here"

- **Macie didn't catch it.** If the page did NOT come from Macie — e.g., a customer email, a Twitter screenshot, a third-party tip — the detection time is the moment the tip was received, not the moment of Macie classification. The 72h clock starts at the tip time. The T+1h triage phase becomes the discovery phase.
- **The SNS topic has no subscribers.** Open the SNS topic in the console; the subscriber list is empty. Page manually (use your backup pager / phone tree / Slack #oncall). Add the missing-subscriber gap to the T+1w action items.
- **The Macie finding is on an object that is *not* PHI.** Macie is a pattern matcher; it can false-positive. T+1h triage determines whether the matched pattern is real PHI or a coincidental string (e.g., a 9-digit number that is not a SIN).

---

## T+1h — Triage (verify, scope, classify as RROSH)

**Goal:** Decide whether this breach is reportable, who the affected data subjects are, and which regulator(s) have jurisdiction. The T+1h phase ends with a "yes / no" on the reportability question.

### T+1h — Checklist

- [ ] **Verify the finding is real.** Open the S3 object in the console. Read enough of it to confirm the Macie match is actual PHI (a column header, a sample row, a recognizable record format). A quick `aws s3 cp s3://<bucket>/<key> - | head` against the staging account is acceptable; do NOT do this against the live bucket.
- [ ] **Determine the public-access window.** When did the object become public? `aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue=<bucket> --start-time <earliest-known-exposure>`. The window starts at the first `s3:PutBucketPolicy` / `s3:PutObjectAcl` that allowed public access and ends at the T+2h containment phase.
- [ ] **Identify the source RDS instance.** RDS snapshots in `s3://niahealth-backups/` are named `niahealth-<env>-rds-<timestamp>`. The instance ID is in the snapshot's metadata (CloudTrail event `CreateDBSnapshot` → `requestParameters.dbiInstanceIdentifier`). Confirm the instance ID, the database name, the table list, and the number of rows in each PHI table.
- [ ] **Estimate the affected-record count.** Run `aws rds describe-db-snapshots --db-snapshot-identifier <id> --query 'DBSnapshots[].AllocatedStorage'` for the snapshot size, then `SELECT count(*) FROM <phi-table>` against a recent backup to estimate row count. A real count is T+24h; T+1h only needs an order of magnitude for the reportability decision.
- [ ] **Classify as RROSH (or not).** Apply the PIPEDA "Real Risk of Significant Harm" test (Schedule 1 §4.7.3). The five factors:
    1. **Sensitivity of the personal information.** PHI is in the top quintile of sensitivity. RROSH satisfied on this factor alone for most clinical data.
    2. **Probability that the personal information has been, is being, or will be misused.** A public S3 bucket with no access logs means the probability is non-zero. The 24h window before T0 means at least one full daily crawl cycle has elapsed.
    3. **Any other prescribed factor.** (See OPC guidance for the full list.)
    4. **Steps taken to reduce the risk of harm.** The 4 public-access blocks on the data-tier bucket (C4) do NOT apply to a backup bucket — confirm whether `niahealth-backups` has the same posture; if not, RROSH weight increases.
    5. **Steps that can be taken by the organization to mitigate the risk.** The T+2h containment phase IS this step. RROSH is determined *after* containment actions are known; the analysis is forward-looking.

  **If RROSH is met: the breach is reportable. Start the T+24h investigation in parallel with the T+2h containment; the regulator determination is part of T+24h, not later.**

- [ ] **Determine which regulators have jurisdiction.**
    - **PHIPA → IPC.** Applies if any affected data subject is an Ontario resident AND the custodian is a "health information custodian" under PHIPA. *Default assumption for a Toronto-based HealthTech: yes, IPC has jurisdiction.*
    - **PIPEDA → OPC.** Applies to all commercial activity across Canada. *Default assumption: yes, OPC has jurisdiction, in addition to the IPC.*
    - **Law 25 → CAI.** Applies if any affected data subject is a Quebec resident OR if the organization handles Quebec residents' personal information. *Default assumption for a HealthTech: yes, CAI has jurisdiction.* Law 25 §3.1 sets a 72-hour-with-diligence threshold from the moment the organization determines the breach creates a risk of serious injury.
- [ ] **Open the post-incident report file** at `RUNBOOKS/post-incidents/YYYY-MM-DD-rds-snapshot-leak.md` (use the template at [`post-incident-template.md`](post-incident-template.md)). The file is the single source of truth for the rest of the response.

### T+1h — Decision tree

```
Is the matched data actually PHI?
├── NO  -> Close the finding. Document in the post-incident report.
│         The Macie pattern was a false positive. No regulator.
│
└── YES -> Was the data ever publicly accessible?
    ├── NO (object was always private; the Macie match is on a
    │       private-but-scanned object)
    │    -> Close the finding. No breach. Document.
    │
    └── YES -> Is RROSH met under the 5-factor PIPEDA test?
        ├── NO  -> Document the decision (which factor, why).
        │         The OPC still requires a record of the breach
        │         (PIPEDA §4.7.5), but no notification is required.
        │         Affected individuals are not notified.
        │
        └── YES -> Multi-regulator path. Continue to T+2h containment.
                  The T+24h phase will write the notifications.
```

### T+1h — "What could go wrong here"

- **You cannot reach the privacy officer.** Phone tree: every HealthTech should have a published escalation chain. If yours doesn't, page the on-call legal counsel. The decision to engage the regulator is *not* a decision you make alone; the legal + privacy team owns it.
- **The RDS instance is multi-tenant and the snapshot is from a shared cluster.** The scope just expanded by an order of magnitude. The T+24h investigation has to enumerate every tenant's data, not just yours.
- **The snapshot contains data from a M&A in-progress.** Cross-border data residency clauses in the deal agreement may override the regulator determination. Page legal *now*.

---

## T+2h — Containment (revoke access, snapshot for forensics, rotate creds)

**Goal:** Stop the bleeding. By the end of this phase, the bucket is no longer public, the affected data has been forensically preserved, and every credential that could have accessed the bucket has been rotated.

### T+2h — Checklist

- [ ] **Revoke public access on the snapshot bucket.**
    1. `aws s3api put-public-access-block --bucket niahealth-backups --public-access-block-configuration '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}'`
    2. `aws s3api delete-bucket-policy --bucket niahealth-backups` (if a public policy exists)
    3. **Capture the bucket policy + ACL BEFORE deletion.** `aws s3api get-bucket-policy --bucket niahealth-backups > forensic/bucket-policy.json`; `aws s3api get-bucket-acl --bucket niahealth-backups > forensic/bucket-acl.json`. The forensic copy is the audit trail for the regulator.
- [ ] **Snapshot the snapshot for forensics.** `aws s3 sync s3://niahealth-backups/ forensic/2026-06-23-rds-snapshot-leak/` — copy every object in the bucket to a new, private, encrypted, versioning-on, Object-Lock-COMPLIANCE forensic bucket. Use a fresh AWS account / org if available; the forensic copy should be readable by the breach-response team only.
- [ ] **Rotate every credential that had access to the bucket.** The blast radius of "had access" is broad. Run `aws iam generate-credential-report` and grep for principals with `s3:*` or `s3:GetObject` on `arn:aws:s3:::niahealth-backups/*` (the bucket policy + any IAM grants + any ACL grants). For each principal:
    - **IAM users** (other than break-glass): rotate the access key + the console password.
    - **IAM roles (service / OIDC):** delete + recreate the role, update the trust policy + permissions, redeploy. The ECS task role, the Firehose role, the data_ingest role, the S3 CRR role — any role with PutObject / GetObject on the backup bucket.
    - **Break-glass user:** force MFA re-enrollment, rotate the console password, force-console-sign-out. The EventBridge rule on `aws.console-login` will fire and page the on-call again — that's expected; acknowledge with a note in the channel.
- [ ] **Verify the public access is gone.** `aws s3api get-bucket-policy-status --bucket niahealth-backups` (should return `IsPublic: false`). `curl -I https://niahealth-backups.s3.amazonaws.com/<key>` (should return `403 Forbidden`, not `200 OK`). Run the same check from an external IP (your laptop) to be sure.
- [ ] **Open a Sev1 ticket with AWS Support** (if your plan allows). Reference the AWS account ID + the bucket name + the Macie finding ID. AWS may have additional telemetry (CloudFront access logs, S3 server access logs) that the on-call does not have.
- [ ] **Update the post-incident report** with the containment actions taken and the timestamps. The T+1w phase reads from this file.

### T+2h — Decision tree

```
Is the bucket now private?
├── NO  -> The bucket policy has multiple statements; the public
│         statement is one of several. Walk every statement.
│         If the bucket has an S3 website configuration, disable it
│         (aws s3api delete-bucket-website --bucket niahealth-backups).
│
└── YES -> Are the rotated credentials deployed?
    ├── NO  -> The rotation touched something downstream. The
    │         application may be in a degraded state. Open a
    │         follow-up incident; do not wait for the data incident
    │         to resolve first.
    │
    └── YES -> Continue to T+24h investigation. The containment
               phase is done.
```

### T+2h — "What could go wrong here"

- **You cannot delete the public bucket policy because the bucket has an S3 website configuration.** Disable the website configuration first (`delete-bucket-website`), then delete the policy.
- **The forensic copy is going into the same account that was breached.** Move it to a fresh account (or at minimum a fresh, MFA-locked-down OU) before the breach response is over. The compromised-account blast radius is not fully known at T+2h.
- **Rotating the data_ingest role breaks the in-flight write path.** The application is now offline for PHI writes. Confirm with the on-call app team whether the read path is affected; if so, the application has effectively been turned off. The decision to take the app offline to preserve evidence is a *legal* decision, not an engineering decision.
- **The IPC's clock is non-negotiable and you cannot reach counsel in time.** PHIPA requires notice "as soon as possible." If the on-call legal counsel is unreachable, the on-call engineering lead has the authority to file a placeholder notification with the IPC and supplement it later. **This is documented as a "what could go wrong" because it is the right thing to do; a late-perfect filing is worse than an early-imperfect one.**

---

## T+24h — Investigation (timeline, affected data, regulator determination)

**Goal:** Build the timeline. Enumerate the affected records. Make the regulator determination (which body has jurisdiction; whether all three regulators are notified, or only some). By the end of this phase, the notifications are *ready to send*; they are sent at T+72h to align with the 72h PIPC clock.

### T+24h — Checklist

- [ ] **Build the timeline from CloudTrail.** Run the following queries (adjust time window to the public-access window from T+1h):
    - `aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue=niahealth-backups --start-time <public-start> --end-time <now>` — every API call against the bucket.
    - Same query against the snapshot's IAM role (the role that called `CreateDBSnapshot` originally).
    - Same query against the AWS account root + every IAM user with console sign-in events in the public-access window.
- [ ] **Identify the data subjects.** Run `SELECT <pii-columns> FROM <phi-tables> ORDER BY created_at DESC LIMIT <count>` against the latest backup of the source RDS instance (NOT the public snapshot — the public snapshot is the forensic copy). The affected-record count is the number of distinct patient_id values in the snapshot.
- [ ] **Determine residency for each affected data subject.** Match the patient records against your residency database. Count: Ontario residents, Quebec residents, other-Canadian-province residents, non-Canadian residents. The IPC + OPC + CAI notifications each have different scope requirements; an all-Canada-HealthTech will have non-zero counts in all three.
- [ ] **Make the regulator determination (formal).** Document in the post-incident report:
    - **IPC (PHIPA s.13(1)).** Notify the IPC AND the affected individuals (s.13(1) "notice to the individual at the last known address"). Notice must include the description of the breach, the date / time period, a description of the PHI involved, and the steps taken / proposed to be taken. IPC has an online breach-report submission portal; the form is the canonical channel.
    - **OPC (PIPEDA Sch.1 §4.7).** Notify the OPC if RROSH is met (per the T+1h determination). Notify the affected individuals if RROSH is met AND it is reasonable to do so. The OPC's breach-report form (the PIPEDA Breach Report Form) is the canonical channel.
    - **CAI (Law 25 §3.1).** Notify the CAI if Quebec residents are affected AND the breach creates a "risk of serious injury." Notice must include the description of the breach, the sensitivity of the PI, the estimated number of people affected, and the steps taken. CAI has an online breach-report submission portal.
- [ ] **Draft the three notifications.** Use the templates in the **Appendix** below. The T+72h phase is the send phase; the drafts are ready by T+24h so the on-call legal + privacy team can review them in the intervening 48h.
- [ ] **Schedule a war-room at T+60h** to walk the privacy officer + legal + on-call engineering through the three notifications one more time before they are sent. A 60h checkpoint catches reviewer comments with 12h of slack.

### T+24h — Decision tree

```
Is the data subject list (and residency list) complete?
├── NO  -> The RDS row count is large. Use a sampling approach
│         (1% sample, 95% confidence interval) and document
│         the method in the post-incident report. The regulator
│         will accept a sampling-based estimate for the 72h
│         notification; the exact count can come at T+1w.
│
└── YES -> Are the three regulator determinations all "YES"?
    ├── NO (e.g., no Quebec residents) -> Drop the CAI
    │   notification; document the determination. The IPC + OPC
    │   notifications still go out.
    │
    └── YES -> Continue. All three notifications are drafted.
              The T+60h war-room is on the calendar.
```

### T+24h — "What could go wrong here"

- **CloudTrail is missing data for the public-access window.** The most likely cause: the trail was created *after* the public-access window started. Document the gap in the post-incident report; the regulator will accept a best-effort timeline with a documented gap.
- **The residency database is incomplete.** Approximate with the data subject's last-known postal code; document the approximation method.
- **The privacy officer + legal disagree on the regulator determination.** The privacy officer owns the final call. Document the legal team's dissent in the post-incident report; the privacy officer's call is the one that goes to the regulator.
- **A new affected record is discovered mid-week.** The 72h clock does not restart. The new record is added to the post-incident report; the original notifications stand. (The 72h clock is anchored to the original T0, not to new findings.)

---

## T+72h — Notification (IPC, OPC, CAI, affected individuals)

**Goal:** All three regulators (where applicable) receive written notification, and affected individuals receive notice at their last known address (PHIPA s.13(1) "notice to the individual at the last known address"). The 72h PIPEDA clock has now elapsed; the on-call team is out of the reportable-breach grace period.

### T+72h — Checklist

- [ ] **Send the IPC notification** (PHIPA s.13(1)). Use the **Appendix — IPC Notification Template** below. Submit via the IPC online portal (see Appendix) AND send the same text to the IPC breach-reporting email address. The IPC requires both.
- [ ] **Send the OPC notification** (PIPEDA Sch.1 §4.7). Use the **Appendix — OPC Notification Template** below. Submit via the OPC online breach-report form. The OPC also requires a record of every breach (reportable or not) — file the reportable one, and file the non-reportable one as a record.
- [ ] **Send the CAI notification** (Law 25 §3.1). Use the **Appendix — CAI Notification Template** below. Submit via the CAI online breach-report form. Law 25 §3.1 includes a 72-hour "with diligence" language; a notification at T+72h satisfies the threshold.
- [ ] **Send notifications to affected individuals** (PHIPA s.13(1) "notice to the individual at the last known address"). PIPEDA + Law 25 also require individual notice when RROSH is met. Use the **Appendix — Individual Notification Template** below. The notice must include:
    - A description of the breach (the unauthorized access, the data involved, the time period).
    - A description of the PI / PHI involved.
    - A description of what the organization has done / is doing to reduce the risk of harm.
    - Steps the individual can take to reduce the risk (credit monitoring, password reset, etc.).
    - Contact information for a person who can answer questions about the breach.
    - Information about the individual's right to file a complaint with the relevant privacy commissioner.
- [ ] **Document the send timestamps in the post-incident report.** The send timestamps are the regulator's proof that the 72h clock was respected.
- [ ] **Schedule the T+1w post-incident meeting.** The 1-week mark is when the root-cause analysis is complete and the control gaps are catalogued. The meeting reads the post-incident report, assigns follow-up action items, and schedules the follow-up audits.

### T+72h — Decision tree

```
Were all three notifications sent (where applicable)?
├── NO (a regulator's portal was down / unresponsive)
│    -> Document the send attempt + the failure in the post-
│       incident report. Re-send at the next business hour.
│       The 72h clock is the target, not a hard deadline, when
│       the failure is on the regulator's side; the IPC and OPC
│       have both stated this in their breach-reporting guidance.
│
└── YES -> Continue to T+1w post-incident. The notification
           phase is done.
```

### T+72h — "What could go wrong here"

- **A regulator asks a clarifying question within 24h of the notification.** This is normal. The IPC and OPC both send follow-up questions; the on-call privacy officer owns the response. The T+1w meeting reviews all follow-up correspondence.
- **A journalist or a class-action law firm reaches out before the individual notifications are sent.** Refer to legal. The on-call engineering lead should NOT respond to media; legal owns the communications plan.
- **A second breach is discovered during the notification phase.** Start a parallel runbook. The on-call rotation has to scale. The second breach's 72h clock starts at its own T0; the first breach's notification proceeds on schedule.
- **The individual notification letters are returned as undeliverable.** The PHIPA requirement is "notice to the individual at the last known address" — the *attempt* satisfies the requirement. Document the returned letters + the follow-up (e.g., a notice on the company website) in the post-incident report.

---

## T+1w — Post-incident (the post-incident report, control gaps, follow-up audits)

**Goal:** Close out the incident. The T+1w output is the post-incident report at `RUNBOOKS/post-incidents/YYYY-MM-DD-rds-snapshot-leak.md`, filled in from the [`post-incident-template.md`](post-incident-template.md) template.

### T+1w — Checklist

- [ ] **Hold the post-incident meeting.** Attendees: on-call engineering, privacy officer, legal counsel, the manager who was paged at T0, and a representative from the auditor rotation. The agenda is the post-incident report, walked section by section.
- [ ] **Catalogue the control gaps.** For each "what could go wrong here" callout that materialized in the actual response, add a control gap entry to the post-incident report. Each entry has: gap description, control objective, proposed remediation, owner, due date.
- [ ] **Schedule the follow-up audits.** The most common follow-ups:
    - **Drift detection:** a scheduled `terraform plan -detailed-exitcode` job that fails when the live infra drifts from the Terraform state. The plan's "deferred to follow-up work" section lists this as the natural first follow-up.
    - **Macie sensitive-data-event-driven detection:** replace the daily Macie job with an event-driven path that compresses the MTTD from 24h to minutes.
    - **Backup-bucket posture:** audit every S3 bucket in the account for the 4 public-access blocks; the breach was on a backup bucket that did NOT have the same posture as the data-tier bucket. The follow-up ensures every bucket (data, logs, backup) has the same posture.
    - **Inspector gate activation:** the U8 plan.yml Inspector gate requires a separate `auditor_role.tf` (a follow-up to the landing module) + the `AUDITOR_ROLE_ARN` repo variable in the GitHub UI. Until both are done, the gate runs as a no-op with a warning. Activate the gate.
- [ ] **File the post-incident report** at `RUNBOOKS/post-incidents/YYYY-MM-DD-rds-snapshot-leak.md`. The file is the audit record; it lives next to the runbook it came from.
- [ ] **Schedule a 30-day check-in** with the on-call rotation to verify that the follow-up action items are in flight. The check-in is the difference between "we wrote a report" and "we changed something."

### T+1w — "What could go wrong here"

- **The post-incident report identifies a control gap that has a CVE-like severity.** Open a follow-up incident. The control gap is itself a reportable event (in the sense of "we found a problem that requires immediate action"); the privacy officer decides whether it is also regulator-reportable.
- **The follow-up action items slip past their due dates.** The 30-day check-in surfaces the slip; escalate to the privacy officer + manager. Slipped control-gap remediation is the most common path to a *second* incident of the same type.
- **The post-incident report is requested by a regulator in a future audit.** The report is a regulator-readable artifact, not just an internal document. Write it accordingly. The template at [`post-incident-template.md`](post-incident-template.md) is structured to satisfy a regulator's request without redlines.

---

## Appendix — Regulator contact details

| Regulator | Jurisdiction | Submission channel | Hours |
|-----------|--------------|--------------------|-------|
| **IPC (Information and Privacy Commissioner of Ontario)** | Ontario PHIPA | Online breach-report portal: <https://www.ipc.on.ca/health-individuals/file-a-health-privacy-complaint/>; email: <info@ipc.on.ca>; phone: 416-326-3333 (Toronto) / 1-800-387-0073 (toll-free) | Mon-Fri 8:30am-5pm ET; emergency contact after hours via the IPC duty officer (page via the on-call legal team) |
| **OPC (Office of the Privacy Commissioner of Canada)** | Federal PIPEDA | Online breach-report form: <https://www.priv.gc.ca/en/privacy-topics/privacy-breaches/report-a-privacy-breach/>; phone: 613-995-8210 | Mon-Fri 8am-5pm ET; for active breaches, the OPC has a 24/7 intake via the on-call legal team |
| **CAI (Commission d'accès à l'information du Québec)** | Quebec Law 25 | Online incident-report form: <https://www.cai.gouv.qc.ca/incident-confidentialite/>; phone: 514-528-7741 (Montréal) / 1-888-528-7741 (toll-free) | Mon-Fri 8:30am-12pm, 1pm-4:30pm ET; emergency contact after hours via the on-call legal team |

**Submission evidence:** for each regulator submission, the post-incident report must include the submission timestamp, the confirmation number, and the PDF copy of the submitted form. The submission is the audit record.

---

## Appendix — IPC notification template (PHIPA s.13(1))

```
To: Information and Privacy Commissioner of Ontario
Re: Breach Report under PHIPA s.13(1)

1. The health information custodian:
   [Custodian legal name + address + contact person + phone + email]

2. Date / time of the breach:
   Public access start: YYYY-MM-DD HH:MM UTC (best estimate from CloudTrail)
   Public access end:   YYYY-MM-DD HH:MM UTC (T+2h containment)
   Detection time:      YYYY-MM-DD HH:MM UTC (T0 = Macie finding)
   Notification time:   YYYY-MM-DD HH:MM UTC (T+72h)

3. Description of the breach:
   An automated RDS snapshot was copied to an S3 backup bucket
   (s3://niahealth-backups/) that was configured with public-read access.
   The public access was in effect for [N] hours. Amazon Macie classified
   the snapshot as containing PHI on YYYY-MM-DD (T0), and the public access
   was revoked at YYYY-MM-DD (T+2h).

4. Description of the PHI involved:
   The snapshot contained [N] distinct patient records drawn from the
   following tables: [list]. The PHI included: patient name, date of
   birth, health card number, clinical notes, and medication list. The
   snapshot did not contain financial information, SIN, or other non-
   health identifiers.

5. Number of individuals affected: [N]
   Ontario residents: [N] | Quebec residents: [N] | Other: [N]

6. Steps taken to reduce the risk of harm:
   - Revoked public access on the backup bucket (T+2h).
   - Copied the snapshot to a private, encrypted, Object-Lock-COMPLIANCE
     forensic bucket for investigation.
   - Rotated every credential with access to the backup bucket.
   - Filed CloudTrail lookup requests to enumerate the public-access
     window.
   - Notified the OPC under PIPEDA Sch.1 §4.7 and the CAI under
     Quebec Law 25 §3.1.

7. Steps proposed to be taken:
   - Schedule a 30-day follow-up audit on every S3 bucket in the
     account for the 4 public-access blocks.
   - Replace the daily Macie job with an event-driven detection path
     (MTTD: minutes, not 24h).
   - Activate the Inspector CVE gate (currently a no-op in the
     plan.yml workflow).

8. Contact for follow-up:
   [Privacy officer name + title + phone + email]
```

---

## Appendix — OPC notification template (PIPEDA Sch.1 §4.7)

```
To: Office of the Privacy Commissioner of Canada
Re: Breach Report under PIPEDA Schedule 1 §4.7

1. The organization:
   [Organization legal name + address + privacy officer contact]

2. Date / time of the breach:
   [Same as IPC notification, identical timestamps]

3. Description of the breach:
   [Same as IPC notification, section 3 above]

4. Description of the PI involved:
   The PI involved the same dataset as the IPC notification (PHI is
   a subset of PI under PIPEDA; the PIPEDA-relevant PI additionally
   includes [list non-PHI personal information]).

5. RROSH determination:
   Real Risk of Significant Harm is MET. The five-factor analysis:
   (1) Sensitivity: the PI is PHI, in the top quintile of sensitivity.
   (2) Probability of misuse: the public-access window was [N] hours;
       a non-zero probability of access by an unauthorized party.
   (3) Any other prescribed factor: [list any that apply].
   (4) Steps taken to reduce the risk: containment completed at T+2h.
   (5) Steps the organization can take to mitigate: see below.

6. Number of individuals affected: [N]

7. Steps taken / proposed:
   [Same as IPC notification, sections 6 and 7]

8. Notification to affected individuals:
   Affected individuals have been notified at their last known address
   per PHIPA s.13(1) and PIPEDA Sch.1 §4.7. The notification letter
   is attached as Annex A.

9. Contact for follow-up:
   [Privacy officer name + title + phone + email]
```

---

## Appendix — CAI notification template (Quebec Law 25 §3.1)

```
To: Commission d'accès à l'information du Québec
Re: Incident de confidentialité — Loi 25 §3.1

1. L'organisation:
   [Nom légal + adresse + responsable de la protection des renseignements
    personnels + téléphone + courriel]

2. Date et heure de l'incident:
   [Identique à la notification IPC, mêmes horodatages]

3. Description de l'incident:
   [Identique à la notification IPC, section 3]

4. Description des renseignements personnels concernés:
   [Identique à la notification IPC, section 4]

5. Nombre de personnes concernées: [N]
   Résidents du Québec: [N] | Autres: [N]

6. Mesures prises pour atténuer le risque de préjudice:
   [Identique à la notification IPC, section 6]

7. Mesures proposées:
   [Identique à la notification IPC, section 7]

8. Personne-ressource pour le suivi:
   [Responsable de la protection des renseignements personnels + titre +
    téléphone + courriel]
```

---

## Appendix — Individual notification template (PHIPA s.13(1))

```
[On organization letterhead]

[Date]

[Patient name]
[Last known address]

Re: Privacy Incident Notice

Dear [Patient name],

We are writing to inform you of a privacy incident at [Organization]
that may have involved your personal health information.

WHAT HAPPENED:
On [date], an automated backup of our clinical database was copied to a
cloud storage location that was configured with public-read access. The
public access was in effect for approximately [N] hours, from [start]
to [end]. The exposure was discovered on [T0 date] and the public access
was revoked within 2 hours of discovery.

WHAT INFORMATION WAS INVOLVED:
The backup contained your [list: name, date of birth, health card number,
clinical notes, medication list]. The backup did not contain your [list:
financial information, SIN, or other non-health identifiers].

WHAT WE ARE DOING:
We have revoked the public access, rotated every credential that could
have accessed the backup, and filed reports with the Information and
Privacy Commissioner of Ontario, the Office of the Privacy Commissioner
of Canada, and the Commission d'accès à l'information du Québec. We have
also engaged outside security experts to verify the containment.

WHAT YOU CAN DO:
- Monitor your health card records for any unusual activity.
- Consider placing a fraud alert with the Canadian Anti-Fraud Centre
  (1-888-495-8501) if you have not already done so.
- Review your explanation of benefits statements from your health
  insurer for any services you did not receive.

YOUR RIGHTS:
You have the right to file a complaint with the Information and Privacy
Commissioner of Ontario (ipc.on.ca), the Office of the Privacy
Commissioner of Canada (priv.gc.ca), or the Commission d'accès à
l'information du Québec (cai.gouv.qc.ca), depending on your province
of residence.

CONTACT:
If you have questions, please contact our privacy officer at
[phone] or [email].

Sincerely,
[Privacy officer name + title]
[Organization name]
```

---

## Appendix — Related documents

- [`RUNBOOKS/README.md`](README.md) — Runbook index + on-call rotation + first-5-minutes checklist
- [`RUNBOOKS/post-incident-template.md`](post-incident-template.md) — T+1w post-incident report template
- [`RUNBOOKS/post-incidents/`](post-incidents/) — Filed post-incident reports (one per incident; naming convention: `YYYY-MM-DD-{incident-id}.md`)
- [`CONTROLS.md`](../CONTROLS.md) — The 15-control matrix (C15 is the breach-response control; C1 + C3 + C7 + C11 are the controls engaged during this scenario)
- [`infra/modules/observability/macie.tf`](../infra/modules/observability/macie.tf) — The Macie discovery job (the 24h MTTD source)
- [`infra/modules/observability/securityhub.tf`](../infra/modules/observability/securityhub.tf) — The Security Hub → EventBridge → SNS paging chain
- [`infra/modules/identity/break_glass.tf`](../infra/modules/identity/break_glass.tf) — The break-glass user + the EventBridge rule on `aws.console-login` (the rotation in T+2h is a touchpoint with C12)

---

*Last reviewed: 2026-06-23. Author: the NiaHealth compliance MVP project. License: see `README.md` (MIT, pending the addition of a `LICENSE` file).*
