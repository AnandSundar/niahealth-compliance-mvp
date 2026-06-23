# Post-Incident Report Template

> **Use this template** for every reportable incident. The T+1w output of any runbook in this repo is a filled-in copy of this file, filed at `RUNBOOKS/post-incidents/YYYY-MM-DD-{incident-id}.md` (the naming convention is `YYYY-MM-DD` followed by a short kebab-case identifier, e.g., `2026-06-23-rds-snapshot-leak.md`).
>
> The structure is NIST 800-61 incident-handling style (Summary → Timeline → Root cause → Impact → Actions taken → Control gaps → Follow-up actions → Lessons learned), adapted to the AWS + Canadian-framework context. Every section has a fill-in-the-blank placeholder; replace each `_italic_` block with the actual content.
>
> **The deliverable is one Markdown file per incident.** The file is the audit record; it lives next to the runbook that produced it. The privacy officer + legal counsel review the file before it is filed; a regulator may request the file as part of a future audit.

---

## Naming convention (read first)

The file is named `RUNBOOKS/post-incidents/YYYY-MM-DD-{incident-id}.md`, where:

- `YYYY-MM-DD` is the **T0 date** (the detection date, not the original-exposure date). For a Macie finding on 2026-06-23, the file is `2026-06-23-{incident-id}.md`.
- `{incident-id}` is a short kebab-case identifier, e.g., `rds-snapshot-leak`, `vendor-compromise`, `phishing-attempt`, `insider-breach`. The identifier is reusable across the runbook (e.g., `breach-rds-snapshot-leak.md` references `2026-06-23-rds-snapshot-leak.md` as the post-incident file for the canonical scenario).

---

## The template

```markdown
# Post-Incident Report — {incident-id}

> **Incident ID:** YYYY-MM-DD-{incident-id}
> **T0 detection date:** YYYY-MM-DD
> **T+1w filed date:** YYYY-MM-DD
> **Filed by:** [name + role]
> **Reviewed by:** [privacy officer name], [legal counsel name]
> **Classification:** [SEV1 / SEV2 / SEV3]
> **Runbook followed:** [link to RUNBOOKS/{runbook-name}.md]
> **Reportable to regulators:** [YES (IPC + OPC + CAI) / YES (IPC + OPC) / YES (OPC) / NO — RROSH not met]

---

## 1. Summary

_One paragraph. What happened, when, to what data, who was affected, what the
outcome was. Should be readable by a non-technical executive in 60 seconds._

On YYYY-MM-DD at HH:MM UTC, a Macie finding classified an automated RDS
snapshot in `s3://niahealth-backups/` as containing PHI. The snapshot had been
copied to a bucket configured with public-read access approximately N hours
earlier. Public access was revoked at T+2h. N distinct patient records were
affected. The breach was reportable to the IPC, OPC, and CAI; all three
notifications were filed by T+72h. No evidence of unauthorized access was
found in CloudTrail logs covering the public-access window.

---

## 2. Timeline

_Authoritative event log, in UTC. Each row is one event. The "source" column
names where the timestamp comes from (CloudTrail, Security Hub, manual, etc.).
The timeline is the audit-trail invariant; do NOT edit the timestamps after
the report is filed (append a correction instead)._

| Time (UTC) | Phase | Event | Source |
|------------|-------|-------|--------|
| YYYY-MM-DD HH:MM | T-prep | [e.g., last rehearsal of the breach runbook] | [e.g., the war-room channel] |
| YYYY-MM-DD HH:MM | T0 | [e.g., Macie finding published to Security Hub] | [`infra/modules/observability/macie.tf`](../infra/modules/observability/macie.tf) |
| YYYY-MM-DD HH:MM | T0 | [e.g., Security Hub → EventBridge rule fires] | [`infra/modules/observability/securityhub.tf`](../infra/modules/observability/securityhub.tf) |
| YYYY-MM-DD HH:MM | T0 | [e.g., SNS message published to paging topic] | [SNS topic: `niahealth-{env}-paging`] |
| YYYY-MM-DD HH:MM | T0 | [e.g., on-call primary acknowledges page] | [paging system] |
| YYYY-MM-DD HH:MM | T0 | [e.g., war-room opened] | [Slack: `#incident-...`] |
| YYYY-MM-DD HH:MM | T0 | [e.g., manager + privacy officer + legal paged] | [paging system] |
| YYYY-MM-DD HH:MM | T+1h | [e.g., Macie finding verified; PHI confirmed real] | [Security Hub console + manual review] |
| YYYY-MM-DD HH:MM | T+1h | [e.g., public-access window determined to be N hours] | [`aws cloudtrail lookup-events`] |
| YYYY-MM-DD HH:MM | T+1h | [e.g., RROSH determination: MET] | [privacy officer's call] |
| YYYY-MM-DD HH:MM | T+1h | [e.g., regulator determination: IPC + OPC + CAI] | [privacy officer + legal counsel] |
| YYYY-MM-DD HH:MM | T+2h | [e.g., public access revoked on the bucket] | [`aws s3api put-public-access-block`] |
| YYYY-MM-DD HH:MM | T+2h | [e.g., forensic copy made to {forensic-bucket}] | [`aws s3 sync`] |
| YYYY-MM-DD HH:MM | T+2h | [e.g., all credentials rotated] | [rotation runbook] |
| YYYY-MM-DD HH:MM | T+2h | [e.g., public access verified gone] | [`curl -I` against the public URL] |
| YYYY-MM-DD HH:MM | T+24h | [e.g., CloudTrail timeline built] | [CloudTrail Lookups] |
| YYYY-MM-DD HH:MM | T+24h | [e.g., affected-record count: N] | [SELECT count(*) from RDS] |
| YYYY-MM-DD HH:MM | T+24h | [e.g., residency breakdown: Ontario N, Quebec N, other N] | [residency DB query] |
| YYYY-MM-DD HH:MM | T+24h | [e.g., three regulator notifications drafted] | [Appendix templates in runbook] |
| YYYY-MM-DD HH:MM | T+60h | [e.g., war-room walkthrough of the three notifications] | [Slack: `#incident-...`] |
| YYYY-MM-DD HH:MM | T+72h | [e.g., IPC notification sent — confirmation #XXX] | [IPC portal] |
| YYYY-MM-DD HH:MM | T+72h | [e.g., OPC notification sent — confirmation #YYY] | [OPC form] |
| YYYY-MM-DD HH:MM | T+72h | [e.g., CAI notification sent — confirmation #ZZZ] | [CAI portal] |
| YYYY-MM-DD HH:MM | T+72h | [e.g., individual notifications mailed — N letters] | [postal service receipt] |
| YYYY-MM-DD HH:MM | T+1w | [e.g., post-incident meeting held] | [meeting notes] |
| YYYY-MM-DD HH:MM | T+1w | [e.g., this report filed] | [git commit] |

---

## 3. Root cause

_One paragraph. The technical root cause (what failed) AND the process root
cause (why the failure was possible). Avoid blaming individuals; the report
is a system-level artifact, not a personnel review._

The technical root cause was [e.g., a `put-bucket-policy` call on
`niahealth-backups` that included `"Principal": "*"` without an
accompanying `Condition` block to scope the grant]. The process root cause
was [e.g., the backup-bucket creation Terraform template did not include
the same 4 public-access blocks that the data-tier bucket template
includes; the omission was not caught in PR review because the backup
bucket was added in a separate, less-reviewed change]. The
control gap that allowed both to land in production is captured in
[Section 6 — Control gaps] below.

---

## 4. Impact

_Quantify the impact. Record counts, residency breakdown, RROSH factors,
business impact (downtime, customer trust, contract penalties). The
regulator may request this section verbatim._

- **Affected records:** N
- **Affected individuals:** N (one record per individual; deduplicated)
- **Residency breakdown:** Ontario N | Quebec N | Other Canadian N | Non-Canadian N
- **PHI involved:** [list: e.g., patient name, date of birth, health card number, clinical notes, medication list]
- **PII involved (non-PHI):** [list: e.g., email address]
- **Sensitive non-PII involved:** [list: e.g., credentials, financial data]
- **RROSH factors:** [walk through the 5-factor PIPEDA test]
- **Business impact:** [e.g., N days of customer-trust work; one customer churned; no SLA breach; no contract penalty triggered]
- **Downtime:** [e.g., 0 minutes for the production application; the data-tier app was not affected; only the backup bucket was public]
- **Cost (response + remediation):** [e.g., N person-hours of engineering + N person-hours of legal + $X of credit monitoring for affected individuals]

---

## 5. Actions taken

_Authoritative list of every action taken during the response, in order.
Each action has a timestamp, a who, and a one-sentence description. The
list is the audit-trail proof that the response was orderly._

| Time (UTC) | Action | Owner | Reference |
|------------|--------|-------|-----------|
| YYYY-MM-DD HH:MM | [e.g., acknowledged page] | [on-call primary] | [paging system] |
| YYYY-MM-DD HH:MM | [e.g., opened war-room] | [on-call primary] | [Slack channel] |
| YYYY-MM-DD HH:MM | [e.g., verified Macie finding is real PHI] | [on-call primary] | [Security Hub console] |
| YYYY-MM-DD HH:MM | [e.g., revoked public access] | [on-call primary] | [`aws s3api put-public-access-block`] |
| YYYY-MM-DD HH:MM | [e.g., copied snapshot to forensic bucket] | [on-call primary] | [`aws s3 sync`] |
| YYYY-MM-DD HH:MM | [e.g., rotated credentials] | [on-call primary] | [rotation runbook] |
| YYYY-MM-DD HH:MM | [e.g., built CloudTrail timeline] | [on-call primary + on-call secondary] | [CloudTrail Lookups] |
| YYYY-MM-DD HH:MM | [e.g., enumerated affected records] | [data team] | [SELECT count(*) ...] |
| YYYY-MM-DD HH:MM | [e.g., sent IPC notification] | [privacy officer] | [IPC portal confirmation #] |
| YYYY-MM-DD HH:MM | [e.g., sent OPC notification] | [privacy officer] | [OPC form confirmation #] |
| YYYY-MM-DD HH:MM | [e.g., sent CAI notification] | [privacy officer] | [CAI portal confirmation #] |
| YYYY-MM-DD HH:MM | [e.g., mailed individual notifications] | [office manager] | [postal receipt] |

---

## 6. Control gaps

_For each "what could go wrong here" callout in the runbook that materialized
in the actual response, add a control gap entry. Each entry has: gap
description, control objective, proposed remediation, owner, due date. The
list is the input to the follow-up audit and to the next iteration of the
architecture._

### Gap 1: [e.g., backup buckets not covered by the 4 public-access blocks]

- **Gap description:** The data-tier S3 bucket has all 4 public-access
  blocks on (per [`infra/modules/data/s3_phi.tf`](../infra/modules/data/s3_phi.tf)),
  but the backup S3 bucket was created without those blocks. The
  inconsistency was not caught in PR review.
- **Control objective:** Every S3 bucket in the account has the 4
  public-access blocks on, regardless of whether it holds PHI. Defense in
  depth; the data-tier bucket is not the only bucket in the account.
- **Proposed remediation:** Add a Checkov custom check that flags any
  `aws_s3_bucket` resource without an accompanying
  `aws_s3_bucket_public_access_block` resource. The check is added to
  `infra/policies/checkov.yaml`.
- **Owner:** [name + role]
- **Due date:** YYYY-MM-DD

### Gap 2: [e.g., 24h MTTD for Macie is too long for a public-bucket breach]

- **Gap description:** Macie's daily classification job means a worst-case
  public-bucket breach is detected 24h after the object is written. The
  72h PIPC clock starts at the Macie classification time, leaving only 48h
  of response window.
- **Control objective:** Compress the MTTD to minutes by replacing the
  daily Macie job with an event-driven detection path (e.g., S3 Event
  Notifications → Lambda → Macie sensitive-data-event-driven detection).
- **Proposed remediation:** Add the event-driven path as a new module in
  `infra/modules/observability/`. Phase out the daily job once the
  event-driven path is validated.
- **Owner:** [name + role]
- **Due date:** YYYY-MM-DD

### Gap 3: [add as many as materialized]

- ...

---

## 7. Follow-up actions

_Concrete next steps with owners and dates. Each follow-up is a ticket
in the issue tracker; the post-incident report cross-references the
ticket. The 30-day check-in (in [`RUNBOOKS/README.md`](README.md))
verifies the follow-ups are in flight._

| Action | Owner | Due date | Ticket | Status |
|--------|-------|----------|--------|--------|
| [e.g., add the Checkov custom check from Gap 1] | [name] | YYYY-MM-DD | [#123] | OPEN |
| [e.g., enable the Inspector CVE gate in plan.yml] | [name] | YYYY-MM-DD | [#124] | OPEN |
| [e.g., schedule the audit of every S3 bucket for the 4 public-access blocks] | [name] | YYYY-MM-DD | [#125] | OPEN |
| [e.g., update the breach runbook's MTTD assumption once the event-driven Macie path lands] | [name] | YYYY-MM-DD | [#126] | OPEN |
| [e.g., tabletop walkthrough of the next runbook on the deferred list] | [name] | YYYY-MM-DD | [#127] | OPEN |

---

## 8. Lessons learned

_What did we learn that is not already captured in a control gap or a
follow-up action? This is the section for the cultural / process
insights that a future on-call engineer would benefit from reading._

- [e.g., the MTTD assumption is the most load-bearing single number in
  the breach runbook; future runbooks should call out the MTTD
  assumption explicitly in the preamble, not bury it in a comment in
  the Macie module.]
- [e.g., the privacy officer should be paged at T0, not T+12h. The
  first 24 hours are when the decisions get made; engaging the
  privacy officer earlier is the single biggest improvement we can
  make.]
- [e.g., the 60h checkpoint (12h before the 72h clock expires) is the
  right cadence for the final review of the regulator notifications.
  A 48h checkpoint would have left no slack; a 72h checkpoint would
  have been too late.]

---

## 9. Sign-off

| Role | Name | Signature | Date |
|------|------|-----------|------|
| On-call primary | | | |
| On-call secondary | | | |
| Privacy officer | | | |
| Legal counsel | | | |
| Manager | | | |
| Engineering lead | | | |

---

## Appendix A — CloudTrail timeline (raw)

_Paste the raw CloudTrail lookup output here. The list is the audit-trail
proof; the summary in Section 2 is the human-readable version._

```
$ aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue=niahealth-backups --start-time <public-start> --end-time <now>
<output here>
```

---

## Appendix B — Affected-record list (summary)

_Summary of the affected records (counts by table, by residency). The full
list lives in the forensic bucket, NOT in this report (PHI separation)._

| Table | Row count | Ontario residents | Quebec residents | Other |
|-------|-----------|-------------------|------------------|-------|
| health_summaries | N | N | N | N |
| (other tables) | N | N | N | N |

---

## Appendix C — Regulator submission confirmations

_For each regulator the breach was reported to, the submission confirmation
(portal confirmation number + PDF copy of the submitted form)._

### IPC (PHIPA s.13(1))

- **Submission timestamp:** YYYY-MM-DD HH:MM UTC
- **Confirmation number:** XXX
- **PDF copy:** [`forensic/ipc-submission-YYYY-MM-DD.pdf`](forensic/ipc-submission-YYYY-MM-DD.pdf) (lives in the forensic bucket, NOT in this repo)

### OPC (PIPEDA Sch.1 §4.7)

- **Submission timestamp:** YYYY-MM-DD HH:MM UTC
- **Confirmation number:** YYY
- **PDF copy:** [`forensic/opc-submission-YYYY-MM-DD.pdf`](forensic/opc-submission-YYYY-MM-DD.pdf)

### CAI (Quebec Law 25 §3.1)

- **Submission timestamp:** YYYY-MM-DD HH:MM UTC
- **Confirmation number:** ZZZ
- **PDF copy:** [`forensic/cai-submission-YYYY-MM-DD.pdf`](forensic/cai-submission-YYYY-MM-DD.pdf)

---

## Appendix D — Communication artifacts

_For every external communication (regulator notification, individual
notification, internal announcement, customer-facing FAQ, press release),
a copy of the artifact + the send timestamp + the recipient list._

- **Internal announcement (war-room invite + status updates):** Slack
  channel `#incident-YYYY-MM-DD-{incident-id}` (transcript exported as
  [`forensic/war-room-transcript.txt`](forensic/war-room-transcript.txt))
- **Individual notification letter template:** see [`RUNBOOKS/breach-rds-snapshot-leak.md` — Appendix — Individual notification template](breach-rds-snapshot-leak.md)
- **Customer-facing FAQ:** [link to FAQ doc]
- **Press release (if any):** [link to press release]

---

*This template is the canonical artifact for the T+1w phase of every
runbook in [`RUNBOOKS/`](README.md). The template is structured to
satisfy a regulator's request without redlines.*
