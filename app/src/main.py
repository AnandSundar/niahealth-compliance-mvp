###############################################################################
# main.py
# FastAPI app entry point.
#
# Layout:
#   /healthz   -- unauthenticated liveness probe (used by the task
#                  definition's HEALTHCHECK and the ALB target group
#                  health check).
#   /health-summary/{patient_id}
#              -- GET; requires Cognito JWT; patient-or-clinician.
#   /access-request
#              -- POST; requires Cognito JWT; logs to the audit bucket.
#   /delete-my-data
#              -- POST; requires Cognito JWT; patient-or-clinician;
#                  hard-nulls PHI columns and logs the deletion to
#                  the audit bucket.
#
# Authentication: every protected route is gated by the `verify_jwt`
# dependency (from auth.py). Authorization is enforced INSIDE the
# route via `require_patient_or_clinician` where the patient_id is
# the URL parameter.
#
# Exception handlers: a small handful of HTTPExceptions are mapped
# to consistent JSON envelopes so the test suite can assert on the
# shape, not the message.
###############################################################################

from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone
from typing import Any, Dict

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse

from app.src.auth import verify_jwt
from app.src.routes import access_request, delete_my_data, health_summary


def _build_version_metadata() -> Dict[str, str]:
    """Return the build metadata the /healthz endpoint surfaces.

    GIT_SHA and BUILD_TIMESTAMP are passed in by the CI build (U8)
    as task definition env vars. They are NOT secrets.
    """
    return {
        "version": "0.1.0",
        "git_sha": os.environ.get("GIT_SHA", "unknown"),
        "build_timestamp": os.environ.get("BUILD_TIMESTAMP", "unknown"),
    }


# Build a single FastAPI app instance. Routers are attached below.
app = FastAPI(
    title="NiaHealth Sample App",
    version="0.1.0",
    description=(
        "Compliance-as-code reference architecture sample. "
        "All /health-summary, /access-request, and /delete-my-data "
        "routes require a valid Cognito JWT in the Authorization header."
    ),
)


# ---------------------------------------------------------------------------
# Unauthenticated routes.
# ---------------------------------------------------------------------------
@app.get("/healthz", tags=["health"])
def healthz() -> Dict[str, Any]:
    """Liveness probe. Returns build metadata for traceability."""
    metadata = _build_version_metadata()
    return {
        "status": "ok",
        "version": metadata["version"],
        "git_sha": metadata["git_sha"],
        "build_timestamp": metadata["build_timestamp"],
    }


# ---------------------------------------------------------------------------
# Authenticated routes. Each router applies `Depends(verify_jwt)` at
# the router level so EVERY route in the file is gated -- the test
# suite's 401-on-missing-bearer checks rely on this.
# ---------------------------------------------------------------------------
app.include_router(health_summary.router, dependencies=[Depends(verify_jwt)])
app.include_router(access_request.router, dependencies=[Depends(verify_jwt)])
app.include_router(delete_my_data.router, dependencies=[Depends(verify_jwt)])


# ---------------------------------------------------------------------------
# Exception handlers. Map the canonical 401/403/404 from the auth
# and route layers to a single JSON envelope.
# ---------------------------------------------------------------------------
def _error_envelope(request: Request, exc: HTTPException) -> JSONResponse:
    body: Dict[str, Any] = {
        "error": {
            "status_code": exc.status_code,
            "detail": exc.detail,
            "path": str(request.url.path),
        },
        "request_id": getattr(request.state, "request_id", None) or str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    headers = getattr(exc, "headers", None) or {}
    return JSONResponse(status_code=exc.status_code, content=body, headers=headers)


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    return _error_envelope(request, exc)


@app.middleware("http")
async def add_request_id(request: Request, call_next):
    """Attach a request_id to every request. The audit-log writes
    reference this so a deletion/access record can be correlated to
    the request that triggered it.
    """
    request.state.request_id = str(uuid.uuid4())
    response = await call_next(request)
    response.headers["X-Request-Id"] = request.state.request_id
    return response
