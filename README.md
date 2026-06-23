# NiaHealth — Compliance-as-Code Reference Architecture

> An interview-prep portfolio piece for a Security, Infrastructure & Compliance Lead role at a Canadian HealthTech. A single-account AWS reference architecture in `ca-central-1` (Montreal) for a sample health-summary REST API, with a 15-control matrix mapped to **PHIPA**, **PIPEDA**, and **Quebec Law 25**, an incident response runbook for the canonical health-tech breach scenario, and a CI/CD pipeline that runs `terraform plan` on every PR. **Terraform-only** — the architecture is validated with `terraform plan`; no live AWS deployment, no real PHI. Public GitHub repo for shareability.

---

## 30-second elevator pitch

A Toronto-based HealthTech handling Ontario + Quebec residents' personal health information needs a cloud architecture that satisfies three Canadian privacy frameworks (PHIPA, PIPEDA, Quebec Law 25) **at the same time**. This repo is the reference architecture for that requirement: a single AWS account in `ca-central-1` with four customer-managed KMS keys (one per blast-radius domain), private/isolated subnets with no PHI-egress to the public internet, an RDS Postgres + RDS Proxy data tier with IAM auth and TLS-only connections, an ECS Fargate sample app behind an ALB + WAFv2, an immutable audit bucket with 7-year Object Lock retention, and a 15-control matrix that does the Canadian-framework cross-walk that AWS itself has not published. The repo also includes a regulator-ready incident response runbook for the canonical RDS-snapshot-leak scenario, with IPC, OPC, and CAI notification templates ready to copy-paste. **The architecture is real Terraform; the runbook is the kind you could walk through at 3 AM on day 1 of the job; the control matrix is the kind of artifact a regulator could audit by `cat`-ing one file per control.**

---

## What this proves in an interview

The five specific things this project demonstrates (in 60-90 seconds, end to end):

1. **I can design least-privilege IAM with permission boundaries, explicit deny on `iam:Create*` / `iam:Attach*` / `kms:*`, and a single break-glass IAM user with `AdministratorAccess` + an explicit deny on `iam:CreateAccessKey` + `iam:UpdateAssumeRolePolicy` + `kms:ScheduleKeyDeletion`.** See [`infra/modules/identity/roles.tf`](infra/modules/identity/roles.tf) for the four per-service roles (`ecs-task-role`, `rds-proxy-role`, `firehose-role`, `lambda-rotation-role`) each attached to the same `service_boundary` permission policy, and [`infra/modules/identity/break_glass.tf`](infra/modules/identity/break_glass.tf) for the break-glass user. Every credential is either OIDC-federated (CI) or MFA-bound (human); no long-lived access keys in the repo, in secrets, or in CI.
2. **I can scope a KMS key per blast-radius domain and prove it with `terraform plan`.** Four customer-managed CMKs (RDS, S3-PHI, CloudTrail, CloudWatch Logs) with annual `enable_key_rotation = true` and an explicit `Deny` on `kms:ScheduleKeyDeletion` for non-admin principals. The S3 audit bucket uses a different CMK than the data-tier PHI bucket, so a compromise of the audit CMK cannot decrypt PHI. See [`infra/modules/security/kms.tf`](infra/modules/security/kms.tf).
3. **I can make the audit trail tamper-evident with S3 Object Lock COMPLIANCE mode and 7-year retention.** Even the account root cannot delete a COMPLIANCE-locked object before retention expires — that's the difference between "logs survive an insider" and "logs survive a regulator subpoena for 7 years." See [`infra/modules/observability/s3_archive.tf`](infra/modules/observability/s3_archive.tf).
4. **I can write a regulator-ready breach response runbook that an interviewer could walk through at 3 AM on day 1 of the job.** The T0 / T+1h / T+2h / T+24h / T+72h / T+1w structure is intentional; the IPC, OPC, and CAI notification templates cite the specific clauses (PHIPA s.13(1), PIPEDA Sch.1 §4.7, Law 25 §3.1) and are ready to copy-paste. See [`RUNBOOKS/breach-rds-snapshot-leak.md`](RUNBOOKS/breach-rds-snapshot-leak.md).
5. **I can ship a regulated architecture with a CI pipeline that runs Checkov, tflint, OPA/Conftest, and a load-bearing Inspector CVE gate, all via OIDC with no long-lived AWS keys.** The PR pipeline posts the `terraform plan` as a PR comment, uploads Checkov's SARIF to Code Scanning, and the apply is gated on a `production` environment approval in the GitHub UI. See [`infra/.github/workflows/plan.yml`](infra/.github/workflows/plan.yml) and [`infra/.github/workflows/apply.yml`](infra/.github/workflows/apply.yml).

---

## Architecture diagram (link to the source)

The architecture is a single AWS account in `ca-central-1`, with cross-region replication to `ca-west-1` (Calgary) for backup-only. The full topology is rendered from source-controlled SVG files in `docs/architecture/`:

| Diagram | What it shows | Source |
|---------|---------------|--------|
| **Network + edge** | VPC, 3-tier subnets, NAT, VPC endpoints, ALB, WAFv2 | [`docs/architecture/network-edge.svg`](docs/architecture/network-edge.svg) |
| **Identity + secrets** | IAM Identity Center, OIDC deploy role, per-service IAM roles, Secrets Manager | [`docs/architecture/identity-secrets.svg`](docs/architecture/identity-secrets.svg) |
| **Data tier** | RDS Postgres, RDS Proxy, S3 PHI bucket with Macie + lifecycle | [`docs/architecture/data-tier.svg`](docs/architecture/data-tier.svg) |
| **Observability + audit** | CloudTrail, Config, GuardDuty, Security Hub, Macie, audit bucket | [`docs/architecture/observability-audit.svg`](docs/architecture/observability-audit.svg) |

The source `.mmd` (Mermaid) files are rendered to SVG by [`infra/scripts/render-architecture.sh`](infra/scripts/render-architecture.sh). The render script is idempotent; re-running it is safe.

---

## How to read this repo

The repository is organized top-down by implementation unit (U1..U9). Each unit has a single, well-defined concern and a focused diff. A new reader should walk the units in order:

```
U1: repo skeleton, architecture diagrams, plan
    -> docs/architecture/                 (the four .svg files)
    -> docs/plans/2026-06-23-001-...     (the source-of-truth plan)

U2: Terraform foundation
    -> infra/                            (root: providers, backend, versions, main.tf)
    -> infra/modules/landing/            (state bucket, OIDC provider, OIDC deploy role)
    -> infra/policies/                   (checkov.yaml, conftest.rego, tflint.hcl)

U3: Networking + edge
    -> infra/modules/networking/         (VPC, subnets, NAT, endpoints, flow logs)
    -> infra/modules/edge/               (ACM, ALB, WAFv2)
    -> infra/modules/security/kms.tf     (4 customer-managed CMKs)

U4: Identity + secrets
    -> infra/modules/identity/           (IdC, per-service roles, break-glass, Access Analyzer)
    -> infra/modules/security/secrets.tf + secrets-rotation.tf

U5: Logging + monitoring
    -> infra/modules/observability/      (CloudTrail, Config, GuardDuty, Security Hub, Macie, audit bucket)

U6: Data tier
    -> infra/modules/data/               (RDS, RDS Proxy, parameter group, S3 PHI, lifecycle/CRR)

U7: Sample application
    -> app/                             (FastAPI: health-summary, access-request, delete-my-data)
    -> infra/modules/compute/           (ECS Fargate, Cognito, ECR)

U8: CI/CD
    -> infra/.github/workflows/         (plan.yml, apply.yml)
    -> infra/.github/CODEOWNERS         (manual-approval gate)

U9: Documentation (this unit)
    -> CONTROLS.md                      (the 15-control matrix)
    -> RUNBOOKS/                        (incident response + on-call rotation + post-incident template)
    -> docs/interview-talking-points.md (the interview-prep document)
    -> README.md                        (this file)
```

A new reader who has never seen the project can answer (a) what it is, (b) what it proves, (c) what controls it implements, (d) how it would respond to a breach, in **under 10 minutes of reading** by following the units in order.

---

## What this is NOT

Be explicit. The repo has limits by design, and an interviewer should know them up-front:

- **This is terraform-only.** The architecture is validated with `terraform plan` (the plan output is committed at the path the plan run writes to). No live `terraform apply` has been run. The bootstrap step (`infra/scripts/bootstrap.sh`, documented in [`infra/README.md`](infra/README.md)) creates the S3 state bucket + DynamoDB lock table; it is the only step that touches a real AWS account and runs at ~$1-5/month.
- **This is not a live deployment with real PHI.** There is no real data in the system. The sample app at `app/` has synthetic health-summary data; the `delete-my-data` route performs a hard-null of the synthetic row. Running this against a real patient record would be a privacy disaster; the repo is the architecture and the controls, not the production system.
- **This is not legal advice.** The PHIPA / PIPEDA / Quebec Law 25 clause citations in [`CONTROLS.md`](CONTROLS.md) and the IPC / OPC / CAI notification templates in [`RUNBOOKS/breach-rds-snapshot-leak.md`](RUNBOOKS/breach-rds-snapshot-leak.md) are the author's reading of the frameworks at 2026-06-23, not legal opinions. A real HealthTech would have outside counsel review every clause citation before any regulator submission.
- **This is not a SOC 2 / HITRUST CSF cross-walk.** The architecture is HIPAA-friendly (the controls are equivalent; AWS publishes HIPAA mappings) but the project's primary framework anchors are Canadian. SOC 2 + HITRUST CSF v11 evidence collection are deferred to follow-up work.
- **This is not multi-account.** A real HealthTech at scale would use AWS Organizations + Control Tower + SCPs. The single-account scope is the right answer for a 1-2-week MVP; the Terraform structure (per-layer modules, OIDC-only deploy roles, Checkov gating) is multi-account-ready, so a future scale-out is a `terraform apply` away, not a rewrite.
- **This is not a complete production system.** The 2-3 follow-up runbooks (insider breach, vendor compromise, ransomware) and the cross-region DR runbook (restore from `ca-west-1` Calgary) are explicitly out of scope for the MVP. See the plan's "Deferred to Follow-Up Work" section.
- **This is not free of operational complexity.** The 15-control matrix is auditable; the operational reality (Macie daily jobs, Secrets Manager rotation, Inspector CVE gating, the on-call rotation) requires a team to maintain it. The architecture does not run itself.

---

## Quick start (terraform-only)

```bash
# 1. Validate the Terraform statically (no AWS access required).
cd infra
terraform init -backend=false
terraform validate
terraform fmt -check -recursive

# 2. Run the policy-as-code suite.
checkov -d . --config-file policies/checkov.yaml
tflint --recursive --config .tflint.hcl --minimum-failure-severity=warning
conftest test --policy policies/conftest.rego '**/*.tf'

# 3. Render the architecture diagrams from the source Mermaid files.
bash scripts/render-architecture.sh
```

The PR pipeline at [`infra/.github/workflows/plan.yml`](infra/.github/workflows/plan.yml) does steps 1 and 2 on every pull request, uploads Checkov's SARIF to GitHub Code Scanning, and posts the `terraform plan` output as a PR comment. A merge to `main` triggers [`infra/.github/workflows/apply.yml`](infra/.github/workflows/apply.yml), which is gated on a `production` environment approval in the GitHub UI.

To actually deploy this against a real AWS account, the one-time bootstrap is documented in `infra/README.md` (the bootstrap creates the S3 state bucket + DynamoDB lock table; everything downstream uses OIDC).

---

## License

This project is released under the **MIT License** (permissive; common for portfolio pieces). The `LICENSE` file is a follow-up — for the MVP, this README is the canonical statement of the license choice. The MIT license text is reproduced below for reference; the canonical text will live in the `LICENSE` file when it lands.

```
MIT License

Copyright (c) 2026 NiaHealth Compliance MVP

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

---

## Related documents

- [`CONTROLS.md`](CONTROLS.md) — The 15-control matrix. The primary deliverable of the project; the cross-walk that AWS itself has not published for PHIPA / PIPEDA / Quebec Law 25.
- [`RUNBOOKS/breach-rds-snapshot-leak.md`](RUNBOOKS/breach-rds-snapshot-leak.md) — The canonical incident response runbook (RDS snapshot leaked to public S3). T0 → T+1w, with IPC / OPC / CAI notification templates.
- [`RUNBOOKS/README.md`](RUNBOOKS/README.md) — Runbook index + on-call rotation + first-5-minutes checklist.
- [`RUNBOOKS/post-incident-template.md`](RUNBOOKS/post-incident-template.md) — The T+1w post-incident report template (NIST 800-61 style).
- [`docs/interview-talking-points.md`](docs/interview-talking-points.md) — The interview-prep document. The 5-bullet pitch + the 3 architectural tradeoffs + the 2 known gaps + the 1 pre-rehearsed question.
- [`docs/plans/2026-06-23-001-feat-niahealth-compliance-reference-architecture-plan.md`](docs/plans/2026-06-23-001-feat-niahealth-compliance-reference-architecture-plan.md) — The source-of-truth plan that produced this repo.
- [`infra/README.md`](infra/README.md) — Terraform-specific quickstart; the one-time bootstrap for the S3 state bucket + DynamoDB lock table.

---

*Last reviewed: 2026-06-23. Author: the NiaHealth compliance MVP project. License: MIT (see above; `LICENSE` file is a follow-up).*
