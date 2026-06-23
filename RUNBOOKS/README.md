# RUNBOOKS — On-call, Alert Handling, and Incident Response

> The home of every operational runbook in the NiaHealth compliance MVP. The runbooks are the executable counterpart to [`CONTROLS.md`](../CONTROLS.md) (which describes *what* is enforced) — the runbooks describe *what to do when the enforcement fires an alert*. Every runbook can be followed by a new engineer on day 1; the goal is no institutional knowledge required.
>
> **If you just got paged and you have never seen this repo before:** skip to the [First 5 Minutes checklist](#first-5-minutes-checklist-for-any-alert) at the bottom of this file, then open the runbook that matches the page text.

---

## Index of runbooks

| Runbook | When to use it | Owner | Status |
|---------|----------------|-------|--------|
| [`breach-rds-snapshot-leak.md`](breach-rds-snapshot-leak.md) | The canonical health-tech breach scenario: a Macie finding on a now-public RDS snapshot in `s3://niahealth-backups/`. Walks T0 detection → T+1h triage → T+2h containment → T+24h investigation → T+72h regulator notification → T+1w post-incident. Includes the IPC, OPC, and CAI notification templates inline. | Privacy officer + on-call engineering | Stable (U9) |
| _Additional runbooks deferred to follow-up work._ The plan's "Deferred to Follow-Up Work" section lists 2-3 more (insider breach, vendor compromise, ransomware) as natural follow-ups. Each follows the same T0 / T+1h / T+2h / T+24h / T+72h / T+1w structure. | | | _Not yet written_ |

### Post-incident reports (the T+1w output)

| Document | Naming convention | Where it lives |
|----------|-------------------|----------------|
| Post-incident report template | `post-incident-template.md` (the blank template) | [`post-incident-template.md`](post-incident-template.md) |
| Filed post-incident report | `YYYY-MM-DD-{incident-id}.md` | [`post-incidents/`](post-incidents/) |

The naming convention is `YYYY-MM-DD-{incident-id}.md` where `incident-id` is a short, kebab-case identifier (e.g., `2026-06-23-rds-snapshot-leak.md`, `2026-07-15-vendor-compromise.md`). The directory is gitignored from public view if the post-incident report contains customer-affected-record details; for the MVP, the reports contain no PHI and are kept in-repo.

---

## On-call rotation

The on-call rotation owns three things:

1. **The paging SNS topic subscription list.** Every alert in this architecture lands on an SNS topic; the topic's subscribers are the on-call rotation. Subscribing / unsubscribing is a manual operation, not a Terraform operation, because the subscriber list is operational data, not infrastructure.
2. **The break-glass envelope.** The break-glass console password + MFA seed live in Secrets Manager; the on-call rotation is the only group that knows how to print the envelope (via `infra/scripts/break-glass-envelope.sh.tpl`). The envelope is printed once per environment per quarter and stored in a physically-secured location.
3. **The 24/7 response.** A page can land at any hour. The on-call rotation has a documented escalation tree (see [After-hours escalation](#after-hours-escalation) below).

### Rotation cadence

The on-call rotation is a **weekly rotation**. Each operator carries the pager for one calendar week, Monday 09:00 → following Monday 09:00 (local time). The handoff is a 30-minute meeting on Monday morning with the outgoing + incoming operators; the agenda is the open follow-up action items from the past week's incidents and the current state of any in-flight investigations.

### Pager mechanics

The paging path is a single SNS topic. The exact topic ARN is environment-specific:

```
arn:aws:sns:<region>:<account>:niahealth-<env>-paging
```

The topic is created by [`infra/modules/identity/`](../infra/modules/identity/) (the `paging_sns_topic_arn` is consumed by the Security Hub EventBridge rule per [`infra/modules/observability/securityhub.tf`](../infra/modules/observability/securityhub.tf)). The subscriber list is owned by the on-call rotation; Terraform does not manage it.

#### How to subscribe to the paging topic

The on-call operator subscribes via the AWS Console or the CLI. **Do not** commit the subscription to Terraform — the subscriber list is operational data and changes too frequently for a PR-driven workflow.

**AWS Console path:**
1. Open the SNS console → Topics → `niahealth-<env>-paging`.
2. Create subscription → Protocol: `Email` (or `SMS` for SMS paging, or `https` for a webhook to PagerDuty / Opsgenie) → Endpoint: your on-call email / phone / webhook URL.
3. Confirm the subscription via the confirmation email (for Email protocol).

**AWS CLI path:**
```bash
aws sns subscribe \
  --topic-arn arn:aws:sns:<region>:<account>:niahealth-<env>-paging \
  --protocol email \
  --notification-endpoint <your-oncall-email>
```

After subscribing, confirm the subscription (Email protocol requires clicking the confirmation link in the AWS email).

#### How to unsubscribe

When your on-call week ends, unsubscribe:
```bash
aws sns list-subscriptions-by-topic --topic-arn arn:aws:sns:<region>:<account>:niahealth-<env>-paging
# Note the SubscriptionArn for your endpoint, then:
aws sns unsubscribe --subscription-arn <your-subscription-arn>
```

Do NOT leave stale subscriptions. A subscription from an engineer who has left the rotation is a security risk (PHI may appear in the alert body).

### What pages look like

A page is an SNS message. The body is the raw CloudTrail / Security Hub / Macie finding JSON. The format varies by source:

| Source | SNS message body | Example first line |
|--------|------------------|---------------------|
| **Macie (via Security Hub)** | Security Hub finding JSON | `"Macie finding: S3 object s3://niahealth-backups/rds-snapshot-2026-06-23 contains PHI (matched data identifier: CANADA_SIN) — Severity: HIGH"` |
| **GuardDuty (via Security Hub)** | Security Hub finding JSON | `"GuardDuty finding: Unusual S3 access pattern from 198.51.100.0 — Severity: HIGH"` |
| **AWS Config (NON_COMPLIANT)** | Config rule compliance change | `"Config rule niahealth-dev-s3-bucket-public-read-prohibbled is NON_COMPLIANT for resource arn:aws:s3:::niahealth-data-dev"` |
| **Break-glass console login** | EventBridge console sign-in event | `"Console login: user niahealth-dev-break-glass at 2026-06-23T14:23:00Z"` |

The first line of the SNS message identifies the runbook to open. The T+1h triage phase in `breach-rds-snapshot-leak.md` has a "What fires" section that names the Macie + Security Hub + SNS message flow.

### After-hours escalation

The on-call rotation is a single person, but no single person carries a 24/7 pager alone. The escalation tree is:

```
On-call primary (the pager holder)
  → On-call secondary (the person who took last week's pager)
    → On-call manager (the rotation's coordinator)
      → Privacy officer + Legal counsel (for any incident that could be
        a reportable breach)
        → CTO (for any incident that could affect PHI-bearing resources)
```

The on-call primary is expected to **acknowledge the page within 15 minutes**, even if the fix is going to take longer. The acknowledgement is the difference between "we noticed" and "we missed it" in a regulator-readiness conversation.

If the on-call primary does not acknowledge within 15 minutes, the paging system auto-escalates to the secondary. If the secondary does not acknowledge within 15 minutes, the manager is paged. The manager's role is to make the call to engage the privacy officer / legal counsel; the manager does NOT take over the technical response.

---

## First 5 minutes checklist (for any alert)

This is the canonical checklist for the moment a page lands. It is intentionally short — the first 5 minutes are about *not making things worse* and *engaging the right people*, not about fixing the underlying issue.

- [ ] **Acknowledge the page in the paging system.** Stops the escalation timer. You can still take hours to fix; you cannot take hours to acknowledge.
- [ ] **Read the page text carefully.** Identify the source (Macie, GuardDuty, Config, break-glass login, other). Identify the severity (CRITICAL, HIGH, MEDIUM, LOW).
- [ ] **Do NOT take destructive action yet.** Containment without forensics is the worst outcome. Wait until the runbook's T+1h triage phase before touching the resource.
- [ ] **Open a war-room.** Dedicated Slack channel (or your incident-channel equivalent) named `#incident-YYYY-MM-DD-{short-name}`. The T+1h triage phase will populate the timeline here.
- [ ] **Page your manager + the privacy officer if the source is a data-class finding** (Macie PHI, GuardDuty S3 exfiltration, Config NON_COMPLIANT on a public-access rule). The first 24 hours are when the decisions get made that determine whether the regulator is engaged. Get the right people in the room *now*, not at T+12h.
- [ ] **Open the runbook that matches the page text.** The Index above points to the right runbook for each source.
- [ ] **Take a deep breath.** The on-call rotation is a weekly cadence; the runbook is the difference between "I have to figure this out" and "I follow the runbook and the runbook is correct." The runbook is correct.

---

## How to add a new runbook

When a new incident type emerges (a vendor compromise, a ransomware attack, an insider breach, etc.), the on-call rotation adds a new runbook. The format is consistent across all runbooks — a new runbook should follow the same T0 / T+1h / T+2h / T+24h / T+72h / T+1w structure as `breach-rds-snapshot-leak.md`, with the following sections:

### Required sections (in order)

1. **Title and one-paragraph scenario description.** What is the scenario? When does this runbook apply?
2. **Glossary.** Acronyms used in the runbook (Canadian privacy stack: PHIPA, PIPEDA, IPC, OPC, CAI, RROSH; AWS service acronyms: RDS, KMS, Macie, GuardDuty, etc.). Every acronym is explained the first time it appears.
3. **Preamble / assumptions.** What is the assumed MTTD? What is the assumed blast radius? These are load-bearing assumptions; the runbook's timeline depends on them.
4. **TL;DR.** One paragraph summary of the response.
5. **Phase 0 — Pre-incident.** What the on-call rotation does *before* the alert fires.
6. **T0 — Detection.** What fires; what the page looks like; the first 5 actions.
7. **T+1h — Triage.** Verify, scope, classify. Decision tree.
8. **T+2h — Containment.** Stop the bleeding. Decision tree.
9. **T+24h — Investigation.** Build the timeline; enumerate affected records; make the regulator determination. Decision tree.
10. **T+72h — Notification.** Regulators + affected individuals. Decision tree.
11. **T+1w — Post-incident.** The post-incident report; control gaps; follow-up audits.
12. **Appendix — Regulator contact details.** IPC, OPC, CAI. Always include this; never make the on-call engineer look up the contact details under time pressure.
13. **Appendix — Notification templates.** For every regulator the scenario may engage, a copy-paste-ready template. The IPC, OPC, and CAI templates are reusable across breach runbooks; new runbooks for new scenarios can copy them verbatim.
14. **"What could go wrong here" callouts.** One per phase. These are the implicit-knowledge traps the runbook author is trying to surface.

### Style rules

- **No institutional knowledge required.** A new engineer should be able to follow the runbook from start to finish. Use plain English. Explain acronyms.
- **Decision trees at every phase.** The on-call engineer should never face a phase that is "decide what to do" without a tree. The tree's terminal node must be a concrete action (a CLI command, a console step, a page).
- **"What could go wrong here" callouts are load-bearing.** A new runbook without these callouts is incomplete; the callouts are the implicit-knowledge traps that a tabletop walkthrough surfaces.
- **Notification templates cite specific clauses.** The IPC template cites PHIPA s.13(1); the OPC template cites PIPEDA Sch.1 §4.7; the CAI template cites Law 25 §3.1. The clauses are the audit-trail invariant.
- **Cross-link to `CONTROLS.md`.** The new runbook should reference the control IDs that the response engages. A ransomware runbook engages C1 + C2 + C7 + C10 + C15; a vendor compromise runbook engages C3 + C9 + C12 + C15. The control IDs are the bridge between the runbook and the rest of the architecture.

### Filing post-incident reports

A post-incident report is filed at `RUNBOOKS/post-incidents/YYYY-MM-DD-{incident-id}.md` using the template at [`post-incident-template.md`](post-incident-template.md). The file lives in-repo (no PHI; the report is operational metadata) and is referenced from the runbook that produced it.

---

## Tabletop exercise (recommended quarterly)

A 15-minute tabletop walkthrough is the difference between "I have a runbook" and "I can run an incident." Schedule a recurring 30-minute calendar block with the on-call rotation; the agenda is one runbook, walked from T0 to T+1w, in dry-run mode. The walkthrough surfaces:

- Acronyms that are not in the glossary.
- Decision trees with missing terminal nodes.
- "What could go wrong here" callouts that are too vague to act on.
- Regulator contact details that are out of date.

A new runbook should be tabletop-walked at least once before it is filed in `RUNBOOKS/`. A walkthrough is also a good time to add a control gap to the post-incident report's "Lessons learned" section.

---

## Related documents

- [`CONTROLS.md`](../CONTROLS.md) — The 15-control matrix. The runbooks are the operational counterpart; the matrix is the audit-trail counterpart.
- [`docs/interview-talking-points.md`](../docs/interview-talking-points.md) — The interview-prep document; the 5-bullet pitch + the 3 tradeoffs + the 2 known gaps + the 1 pre-rehearsed question.
- [`infra/modules/observability/securityhub.tf`](../infra/modules/observability/securityhub.tf) — The Security Hub → EventBridge → SNS paging chain.
- [`infra/modules/identity/break_glass.tf`](../infra/modules/identity/break_glass.tf) — The break-glass user + the EventBridge rule on `aws.console-login` (the T+2h "rotate the break-glass" step in the breach runbook).

---

*Last reviewed: 2026-06-23. Author: the NiaHealth compliance MVP project. License: see [`README.md`](../README.md) (MIT, pending the addition of a `LICENSE` file).*
