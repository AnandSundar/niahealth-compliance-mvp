#!/usr/bin/env bash
###############################################################################
# render-architecture.sh
#
# Produces a textual architecture summary by listing:
#   1. The SVG files in docs/architecture/ (the rendered diagrams
#      produced by U1).
#   2. The Terraform modules in infra/modules/ (the per-layer building
#      blocks produced by U2+).
#
# The output is plain text (no external tools required -- not even
# `tree`). It is intended to be readable in a PR comment, an interview
# review, or a Slack paste.
#
# Usage:
#   ./infra/scripts/render-architecture.sh            # from repo root
#   ./infra/scripts/render-architecture.sh --with-policies   # also list policies
#
# Exit codes:
#   0  success
#   1  could not find docs/architecture/ or infra/modules
###############################################################################

set -euo pipefail

# Resolve the script directory and the repo root from it, so the
# script can be invoked from anywhere (not just the repo root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

WITH_POLICIES=0
for arg in "$@"; do
  case "$arg" in
    --with-policies) WITH_POLICIES=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
  esac
done

# Simple tree-like printer. Two spaces of indent per level.
# No external dependencies; we walk the directory ourselves. We split
# the listing into one "top-level entry" pass and one "children of
# directories" pass so the output looks like:
#   landing/
#     main.tf
#     variables.tf
#     ...
# rather than a flat "all files at depth N" dump.
list_dir() {
  local root="$1"
  local prefix="$2"

  # Top-level entries (directories + loose files).
  find "$root" -mindepth 1 -maxdepth 1 -print 2>/dev/null \
    | sed "s#${root}/##" \
    | sort \
    | while IFS= read -r entry; do
        if [ -d "${root}/${entry}" ]; then
          printf "%s%s/\n" "$prefix" "$entry"
          # Children of this directory, one indent deeper.
          find "${root}/${entry}" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null \
            | sed "s#${root}/${entry}/##" \
            | sort \
            | while IFS= read -r child; do
                printf "%s  %s\n" "$prefix" "$child"
              done
        else
          printf "%s%s\n" "$prefix" "$entry"
        fi
      done
}

section() {
  printf "\n%s\n" "$1"
  printf '%s\n' "$(printf '%.s-' $(seq 1 ${#1}))"
}

echo "NiaHealth compliance reference architecture -- textual summary"
echo "Repo: ${REPO_ROOT}"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 1. Architecture diagrams.
section "Architecture diagrams (docs/architecture/)"
if [ -d "${REPO_ROOT}/docs/architecture" ]; then
  list_dir "${REPO_ROOT}/docs/architecture" "  " 1
else
  echo "  (missing: docs/architecture/ not found -- was U1 run?)"
fi

# 2. Terraform modules.
section "Terraform modules (infra/modules/)"
if [ -d "${REPO_ROOT}/infra/modules" ]; then
  list_dir "${REPO_ROOT}/infra/modules" "  " 2
else
  echo "  (missing: infra/modules/ not found -- this script is meant to live under infra/scripts/)"
  exit 1
fi

# 3. Optional: policy files.
if [ "$WITH_POLICIES" -eq 1 ]; then
  section "Policy files (infra/policies/)"
  if [ -d "${REPO_ROOT}/infra/policies" ]; then
    list_dir "${REPO_ROOT}/infra/policies" "  " 1
  else
    echo "  (missing: infra/policies/ not found)"
  fi
fi

section "End of summary"
echo
