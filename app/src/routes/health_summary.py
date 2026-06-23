###############################################################################
# routes/health_summary.py
# GET /health-summary/{patient_id}
#
# Authorization: a patient can read their own data; a member of the
# "clinicians" Cognito group can read any patient's data. The auth
# model is enforced by `require_patient_or_clinician` (in auth.py).
#
# Source of truth: the `health_summaries` table in the `phi` schema
# of the `niahealth` database. If no row exists, we return a
# synthetic response so the demo works without seeded data; the
# `source: "synthetic"` flag tells the client this is a placeholder.
#
# Security: the `patient_id` is bound via psycopg's named parameter
# syntax (`:patient_id`) -- NEVER via string interpolation.
###############################################################################

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Dict

from fastapi import APIRouter, Depends, HTTPException, Path, status

from app.src.auth import require_patient_or_clinician, verify_jwt
from app.src.db import get_health_summary


router = APIRouter(prefix="/health-summary", tags=["health-summary"])


def _synthetic_health_summary(patient_id: str) -> Dict[str, Any]:
    """Return a synthetic health summary for the demo.

    Flagged with `source: "synthetic"` so the client (and tests) can
    tell this is a placeholder, not a real PHI read.
    """
    return {
        "patient_id": patient_id,
        "summary_text": (
            "No clinical record on file. (Synthetic response -- the "
            "demo is not connected to a real EMR. In production this "
            "endpoint returns the latest structured summary from the "
            "PHI database.)"
        ),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": "synthetic",
    }


@router.get(
    "/{patient_id}",
    response_model=None,  # we return a plain dict; Pydantic schemas are a U8+ nice-to-have
)
def read_health_summary(
    patient_id: str = Path(..., min_length=1, max_length=128),
    claims: Dict[str, Any] = Depends(verify_jwt),
) -> Dict[str, Any]:
    """Return the health summary for `patient_id`.

    403 when the caller is not the patient and not in the
    "clinicians" group. 200 with `source: "synthetic"` when the
    database has no row (demo behavior).
    """
    require_patient_or_clinician(claims, patient_id)

    row = get_health_summary(patient_id)
    if row is None:
        return _synthetic_health_summary(patient_id)

    return {
        "patient_id": row["patient_id"],
        "summary_text": row["summary_text"],
        "generated_at": row["generated_at"],
        "source": "db",
    }
