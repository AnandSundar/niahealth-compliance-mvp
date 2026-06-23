###############################################################################
# infra/.github/pull_request_template.md
#
# Default PR template. Applied automatically to every PR opened
# against main. The "Compliance impact" and "Security review"
# sections are the human-attestation backstop for the automated
# Checkov / Conftest / tflint gates in plan.yml -- a human must
# confirm the control story, not just the static checks.
###############################################################################

## What does this PR do?

<!-- One-paragraph description of the change. If it touches a
     control (encryption, IAM, public access, audit log, secrets),
     name the control ID from CONTROLS.md (U9) explicitly. -->

---

## Which U-units does this touch?

<!-- Check all that apply. A PR that crosses unit boundaries
     should justify the coupling in the description. -->

- [ ] U1 -- Architecture diagrams
- [ ] U2 -- Terraform foundation (state, providers, OIDC, policies)
- [ ] U3 -- Networking + edge (VPC, ALB, KMS, WAFv2)
- [ ] U4 -- Identity + secrets (IAM Identity Center, roles, Secrets Manager)
- [ ] U5 -- Logging + monitoring (CloudTrail, Config, GuardDuty, Security Hub, Macie)
- [ ] U6 -- Data tier (RDS Postgres, RDS Proxy, S3 PHI bucket)
- [ ] U7 -- Sample app (FastAPI + Cognito + RDS Proxy + ECS Fargate)
- [ ] U8 -- CI/CD (GitHub Actions OIDC, Checkov, tflint, Conftest)
- [ ] U9 -- Documentation (CONTROLS.md, runbooks, README)
- [ ] `docs/` -- Documentation only
- [ ] `scripts/` -- Bootstrap or utility scripts
- [ ] None of the above (drive-by: typo, comment, etc.)

---

## Compliance impact

<!-- The plan pipeline enforces static checks, but the
     control-story is a human attestation. Pick the closest match. -->

- [ ] No PHI control changes (no encryption, IAM, audit-log, or
      public-access impact)
- [ ] **PHI control change** -- flagged for **security review**
      (encryption, access, retention, network exposure)
- [ ] **Audit-log change** -- flagged for **compliance review**
      (CloudTrail, Config, Security Hub, Macie)

---

## Plan output

<!-- plan.yml runs on every PR and posts a `terraform plan` diff
     as a comment with the `niahealth-tfplan-marker` marker. Link
     the comment here, or attach the `tfplan` artifact from the
     workflow run. -->

- [ ] Plan comment posted on this PR (link: <!-- url -->)
- [ ] Plan artifact `tfplan` attached to this PR (link: <!-- url -->)
- [ ] No plan change (docs, tests, or comment-only)

---

## Rollback plan

<!-- If this PR needs to be reverted, what is the procedure?
     The standard rollback path is:
       1. workflow_dispatch on apply.yml with `action=rollback`
          (destroys the resources added by this PR)
       2. Re-apply the previous commit's tfplan (stored in
          s3://<state-bucket>/backups/<ts>.tfstate)
     Document any non-standard path here. -->

- [ ] Standard rollback: `workflow_dispatch` with `action=rollback`
- [ ] Custom rollback: <!-- describe -->

---

## Testing

<!-- plan.yml runs the full static-check suite automatically.
     The checkboxes below are for local pre-flight validation
     (faster feedback than waiting for CI) and for documenting
     the human-side checks. -->

- [ ] `terraform fmt -check -recursive` passed locally
- [ ] `terraform init -backend=false && terraform validate` passed locally
- [ ] `tflint --recursive --config infra/.tflint.hcl` passed locally
- [ ] `conftest test --policy infra/policies/conftest.rego infra/**/*.tf` passed locally
- [ ] `checkov -d infra --config-file infra/policies/checkov.yaml` hard-fail list passed locally
- [ ] `pytest app/ -v` passed locally (if `app/` was touched)
- [ ] Inspector gate: no unmitigated CRITICAL/HIGH CVE on the deploy image tag
- [ ] Do-not-apply guard: confirmed `terraform apply` is NOT in `infra/.github/workflows/plan.yml`

---

## Security review

<!-- The deploy role's trust policy (modules/landing/oidc.tf) pins
     sub + aud + workflow_file. Changes to IAM (modules/identity/,
     modules/landing/) or to apply.yml MUST be reviewed by
     @niahealth-security per CODEOWNERS. -->

- [ ] No new IAM permissions
- [ ] **New IAM permissions documented below** -- include the
      change rationale and the affected actions/resources

<!-- For new IAM permissions, paste the policy diff and answer:
     - Which actions are granted?
     - On which resources (ARNs, scopes)?
     - Why is this the minimum necessary?
     - Is the grant scoped to a specific condition (tag, region, time)?
-->

---

## Checklist

- [ ] PR is scoped to a single concern (split larger refactors)
- [ ] Commit messages reference the U-unit(s) touched
- [ ] No secrets in the diff (run `gitleaks` or equivalent locally)
- [ ] No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` references
- [ ] All GitHub Actions are pinned to a major version (`@v4`, `@v3`)
- [ ] Required reviewers tagged per `infra/.github/CODEOWNERS`
- [ ] Branch is up to date with `main`
