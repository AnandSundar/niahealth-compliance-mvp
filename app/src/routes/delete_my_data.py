###############################################################################
# routes/delete_my_data.py
# POST /delete-my-data
#
# PHIPA s.18 (Ontario) and Quebec Law 25 §3.1 entitle a data
# subject to request erasure of their personal information.
# Compliance deadline: 30 days from the request.
#
# The MVP semantics: a HARD delete. The patient's `summary_text`
# and `generated_at` columns are NULLed in the RDS row. The
# `patient_id` is retained so a subsequent sync from the EMR does
# not re-create the same record. A soft-delete variant (retention
# period + flag) is explicitly deferred to a post-MVP iteration --
# the plan's R22 control calls for hard erase to satisfy the
# right-to-erasure requirement without the operational complexity
# of a retention policy on the application side.
#
# The audit log retains a deletion record for the full 7-year
# retention per Object Lock -- the deletion event is permanently
# auditable, the data is not.
#
# Authorization: the caller must be the patient OR a member of the
# "clinicians" group. A clinician can delete a patient's record
# (e.g. on the patient's behalf during a clinic visit); a patient
# can self-delete. Anyone else is 403.
#
# Audit shape:
#   key  = deletions/{YYYY-MM-DD}/{sub}-{deletion_id}.json
#   body = { deletion_id, sub, patient_id, deleted_at,
#            request_ip, retained_in_audit_log_for }
###############################################################################

from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from typing import Any, Dict

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import APIRouter, Depends, HTTPException, Request, status

from app.src.auth import require_patient_or_clinician, verify_jwt
from app.src.db import delete_patient_data


router = APIRouter(prefix="/delete-my-data", tags=["delete-my-data"])


def _audit_bucket_name() -> str:
    value = os.environ.get("AUDIT_BUCKET_NAME")
    if not value:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="AUDIT_BUCKET_NAME is not configured",
        )
    return value


def _write_audit_log_entry(key: str, body: Dict[str, Any]) -> None:
    client = boto3.client("s3", region_name=os.environ.get("AWS_REGION"))
    try:
        client.put_object(
            Bucket=_audit_bucket_name(),
            Key=key,
            Body=json.dumps(body, sort_keys=True, default=str).encode("utf-8"),
            ContentType="application/json",
            ServerSideEncryption="aws:kms",
        )
    except (BotoCoreError, ClientError) as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"reason": "audit_log_write_failed", "error": str(exc)},
        ) from exc


@router.post("", status_code=status.HTTP_200_OK)
def delete_my_data(
    patient_id: str,
    request: Request,
    claims: Dict[str, Any] = Depends(verify_jwt),
) -> Dict[str, Any]:
    """Hard-null the PHI columns for `patient_id` and log the
    deletion event to the audit bucket.

    `patient_id` is passed as a query string parameter so the
    clinician-on-behalf use case works (a clinician deletes a
    patient's record, not their own).
    """
    require_patient_or_clinician(claims, patient_id)

    deletion_id = str(uuid.uuid4())
    deleted_at = datetime.now(timezone.utc)
    sub = claims.get("sub", "unknown")

    # Hard-null the PHI columns. The function returns True when a
    # row was updated, False when no row matched. We treat False
    # as a no-op success -- the patient's data is already gone --
    # but still log the deletion event so the audit trail records
    # the attempt.
    delete_patient_data(patient_id)

    audit_body = {
        "deletion_id": deletion_id,
        "sub": sub,
        "patient_id": patient_id,
        "deleted_at": deleted_at.isoformat(),
        "request_ip": request.client.host if request.client else None,
        "retained_in_audit_log_for": "7y",
    }
    date_prefix = deleted_at.strftime("%Y-%m-%d")
    key = f"deletions/{date_prefix}/{sub}-{deletion_id}.json"
    _write_audit_log_entry(key, audit_body)

    return {
        "deletion_id": deletion_id,
        "completed_at": deleted_at.isoformat(),
        "retained_in_audit_log_for": "7y",
    }
