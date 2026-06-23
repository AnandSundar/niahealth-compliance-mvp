###############################################################################
# routes/access_request.py
# POST /access-request
#
# PIPEDA 4.9 (and Quebec Law 25 §3.1) entitle a data subject to
# request access to their personal information held by an
# organization. The organization must respond within 30 days.
#
# The MVP endpoint does NOT fulfil the request -- it captures the
# request, logs it to the immutable audit bucket, and returns 202
# with a request_id so the operator can route it. The actual
# fulfilment pipeline (collation from EMR + delivery) is a U9+
# concern.
#
# Authorization: any authenticated user can file an access
# request -- the authz model is "self-service for any logged-in
# patient." We do NOT require `claims["sub"] == patient_id` because
# a clinician filing on behalf of a patient is a legitimate use
# case. (The patient_id in the body may differ from the caller's
# sub.)
#
# Audit shape:
#   key  = access-requests/{YYYY-MM-DD}/{sub}-{request_id}.json
#   body = { request_id, sub, patient_id, request_type,
#            justification, received_at, request_ip }
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
from pydantic import BaseModel, Field

from app.src.auth import verify_jwt


router = APIRouter(prefix="/access-request", tags=["access-request"])


class AccessRequestBody(BaseModel):
    """Schema for the access-request body. Validated at the edge
    by Pydantic so the route handler is guaranteed well-typed input.
    """

    patient_id: str = Field(..., min_length=1, max_length=128)
    request_type: str = Field(..., min_length=1, max_length=64)
    justification: str = Field(..., min_length=1, max_length=2048)


def _audit_bucket_name() -> str:
    value = os.environ.get("AUDIT_BUCKET_NAME")
    if not value:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="AUDIT_BUCKET_NAME is not configured",
        )
    return value


def _write_audit_log_entry(key: str, body: Dict[str, Any]) -> None:
    """Write a single JSON entry to the immutable audit bucket.

    The bucket is owned by the observability module and is configured
    with Object Lock in COMPLIANCE mode + a 7-year retention. Once
    written, the object CANNOT be deleted or modified -- even by
    the root account -- until the retention period elapses.
    """
    client = boto3.client("s3", region_name=os.environ.get("AWS_REGION"))
    try:
        client.put_object(
            Bucket=_audit_bucket_name(),
            Key=key,
            Body=json.dumps(body, sort_keys=True, default=str).encode("utf-8"),
            ContentType="application/json",
            # Server-side encryption with the S3-managed default
            # (the bucket policy requires SSE-KMS via the policy
            # attached by observability/s3_archive.tf).
            ServerSideEncryption="aws:kms",
        )
    except (BotoCoreError, ClientError) as exc:
        # Audit log writes are CRITICAL. If the write fails, the
        # route should return 5xx so the caller retries (or the
        # operator follows up) -- we never silently drop a
        # compliance event.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"reason": "audit_log_write_failed", "error": str(exc)},
        ) from exc


@router.post("", status_code=status.HTTP_202_ACCEPTED)
def create_access_request(
    body: AccessRequestBody,
    request: Request,
    claims: Dict[str, Any] = Depends(verify_jwt),
) -> Dict[str, Any]:
    """File an access request. Returns 202 with the request_id."""
    request_id = str(uuid.uuid4())
    received_at = datetime.now(timezone.utc)
    sub = claims.get("sub", "unknown")

    audit_body = {
        "request_id": request_id,
        "sub": sub,
        "patient_id": body.patient_id,
        "request_type": body.request_type,
        "justification": body.justification,
        "received_at": received_at.isoformat(),
        "request_ip": request.client.host if request.client else None,
    }

    # Partition by date so a daily index is cheap to query and so a
    # single day of access requests never exceeds S3's per-prefix
    # soft limit.
    date_prefix = received_at.strftime("%Y-%m-%d")
    key = f"access-requests/{date_prefix}/{sub}-{request_id}.json"
    _write_audit_log_entry(key, audit_body)

    return {
        "request_id": request_id,
        "logged_at": received_at.isoformat(),
    }
