# Makefile
# Terraform workflow for the NiaHealth compliance reference architecture.
#
# Conventions:
#   - `make init`        : one-time, after the bootstrap script has run
#   - `make validate`    : CI-safe (no backend), runs fmt-check first
#   - `make plan`        : uses envs/dev.tfvars (created in a later unit)
#   - `make check`       : the umbrella "is this PR safe to merge?" target
#
# All targets are intentionally .PHONY so make never gets confused by
# files in the working tree.

SHELL := /bin/bash
TF    := terraform
ENV   ?= dev
TFVARS ?= -var-file=envs/$(ENV).tfvars

.PHONY: help init init-backend validate fmt fmt-check plan plan-sanitized checkov conftest lint check clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: ## terraform init (requires bootstrap + backend.hcl)
	$(TF) init

init-backend=false:
	$(TF) init -backend=false

validate: fmt-check ## terraform validate (no backend)
	@find . -name '*.tf' -print0 | xargs -0 -n1 dirname | sort -u | while read -r d; do \
		( cd "$$d" && $(TF) init -backend=false >/dev/null 2>&1 && $(TF) validate -no-color ) || exit 1; \
	done

fmt: ## terraform fmt -recursive (write)
	$(TF) fmt -recursive

fmt-check: ## terraform fmt -check -recursive (CI)
	$(TF) fmt -check -recursive

plan: ## terraform plan with the selected env file
	$(TF) plan $(TFVARS)

# NOTE: scripts/sanitize-plan.sh is owned by a follow-up unit (U8).
# Until it lands, `plan-sanitized` just runs `plan` and notes the
# follow-up. The raw plan-output.txt is gitignored (see .gitignore).
plan-sanitized: plan
	@echo "plan-sanitized: scripts/sanitize-plan.sh is a U8 deliverable."
	@echo "Until then, treat plan-output.txt as not-for-commit."

checkov: ## Checkov static scan (extends BC_AWS_GENERAL_https baseline)
	checkov -d . --config-file policies/checkov.yaml --skip-download

conftest: ## OPA/Conftest tag + naming policy test
	@if compgen -G "*.tf" >/dev/null; then \
		conftest test --policy policies/conftest.rego *.tf; \
	else \
		echo "conftest: no .tf files at root, skipping (run inside modules/ instead)"; \
	fi

lint: ## tflint --recursive
	tflint --recursive

check: validate checkov conftest lint ## CI umbrella: validate + checkov + conftest + lint
	@echo "all checks passed"

clean: ## Remove .terraform working dir (DESTRUCTIVE: re-init required)
	rm -rf .terraform .terraform.lock.hcl
