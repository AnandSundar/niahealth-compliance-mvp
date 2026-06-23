#!/usr/bin/env bash
###############################################################################
# infra/scripts/break-glass-envelope.sh.tpl
#
# BREAK-GLASS ENVELOPE PRINTER (TEMPLATE -- NOT RUN AS-IS).
#
# This is a TEMPLATE. The .tpl suffix means the orchestrator / operator
# must substitute the placeholders below before running the script.
# Once substituted, the script prints a sealed-envelope text block
# for the team's physical safe: account ID, region, username, console
# URL, MFA seed, and the ARN of the Secrets Manager secret holding
# the console password.
#
# Why a script (not a Terraform output): the envelope must include
# the MFA seed AND the console password. Both are SENSITIVE. The
# Terraform plan only generates them on first apply; storing them
# in a Terraform output file would put them in plaintext on disk.
# The orchestrator runs this script with the values piped in from
# Secrets Manager:
#
#   aws secretsmanager get-secret-value --secret-id \
#     niahealth-dev/break-glass-password --query SecretString --output text
#
# and writes the resulting envelope to an air-gapped printer.
#
# USAGE:
#   1. After `terraform apply`, retrieve the password + MFA seed from
#      Secrets Manager (privileged operator only).
#   2. Substitute the placeholders below.
#   3. Run the script on an air-gapped workstation connected to a
#      printer.
#   4. Place the printed envelope in the team's physical safe.
#   5. DELETE the temporary plaintext file from the workstation.
#
# WARNING: This script DOES NOT contain real secrets. The
# placeholders are intentional and must be replaced at print time.
###############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Placeholders. The operator MUST substitute these before running.
# ---------------------------------------------------------------------------
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID must be set (e.g. 123456789012)}"
: "${AWS_REGION:?AWS_REGION must be set (e.g. ca-central-1)}"
: "${USERNAME:?USERNAME must be set (e.g. niahealth-dev-break-glass)}"
: "${CONSOLE_LOGIN_URL:?CONSOLE_LOGIN_URL must be set (e.g. https://niahealth-dev.signin.aws.amazon.com/console)}"
: "${PASSWORD_SECRET_ARN:?PASSWORD_SECRET_ARN must be set (Secrets Manager ARN)}"
: "${MFA_SEED_SECRET_ARN:?MFA_SEED_SECRET_ARN must be set (Secrets Manager ARN)}"
: "${PASSWORD:?PASSWORD must be supplied via stdin or env from the privileged retrieval path}"
: "${MFA_SEED:?MFA_SEED must be supplied via stdin or env from the privileged retrieval path}"

# ---------------------------------------------------------------------------
# The envelope itself. Each field is on its own line so a printed copy
# is OCR-friendly and unambiguous.
# ---------------------------------------------------------------------------
cat <<EOF
+--------------------------------------------------------------+
|                                                              |
|             !!! EMERGENCY USE ONLY !!!                       |
|                                                              |
|       EVERY LOGIN IS PAGED WITHIN 60 SECONDS.                |
|       EVERY USE MUST BE LOGGED IN THE INCIDENT CHANNEL.      |
|                                                              |
|       This envelope is for the recovery of NiaHealth AWS     |
|       account access in the event that IAM Identity Center  |
|       is unavailable or all admin identities are locked      |
|       out.                                                   |
|                                                              |
+--------------------------------------------------------------+

  AWS Account ID      : ${AWS_ACCOUNT_ID}
  AWS Region          : ${AWS_REGION}
  IAM Username        : ${USERNAME}
  Console Login URL   : ${CONSOLE_LOGIN_URL}

  Password            : ${PASSWORD}
                        (also stored in Secrets Manager ARN below)

  MFA Device Name     : ${USERNAME}-mfa
  MFA Seed            : ${MFA_SEED}
                        (also stored in Secrets Manager ARN below)

  Password Secret ARN : ${PASSWORD_SECRET_ARN}
  MFA Seed Secret ARN : ${MFA_SEED_SECRET_ARN}

  Paging Topic        : the SNS topic named
                        "\${AWS_ACCOUNT_ID}-break-glass-paging" pages the
                        on-call rotation within 60 seconds of any console
                        sign-in by this user.

  Use only when:
    - IAM Identity Center is unavailable for > 30 min.
    - All admin permission-set assignments are locked out.
    - A regulator-mandated immediate action requires AWS access.

  After use:
    1. Rotate the password via the Secrets Manager Console.
    2. Rotate the MFA seed by re-applying Terraform.
    3. File an incident report in the IR channel.
    4. Print a fresh envelope and replace this one.

+--------------------------------------------------------------+
EOF