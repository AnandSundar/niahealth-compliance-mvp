###############################################################################
# auth.py
# Cognito JWT verification.
#
# This module is the SECURITY BOUNDARY of the application. Every other
# module trusts that any request that successfully returns from
# `verify_jwt()` has been authenticated by Cognito with an unexpired
# RS256-signed token, issued for this User Pool, and intended for
# this User Pool Client. Three things must remain true forever:
#
#   1. `algorithms=["RS256"]` is hard-coded. The default for pyjwt's
#      `decode()` is `["HS256"]`, which would let a forged token
#      signed with the public key (HMAC) be accepted as "verified".
#      The "alg: none" attack is the original JWT footgun; the
#      "alg: HS256 confusion" attack is the modern variant. Both are
#      tested in tests/test_auth.py.
#
#   2. `audience=` is the Cognito User Pool Client ID. Cognito issues
#      tokens with `aud = <client_id>`; we must verify the token was
#      minted FOR this client (defense against cross-client token
#      reuse if a future second client is added).
#
#   3. `issuer=` is the Cognito User Pool issuer URL of the form
#      `https://cognito-idp.<region>.amazonaws.com/<user_pool_id>`.
#      Without this check, a token signed by another Cognito User
#      Pool in the same account (or a different account) could be
#      accepted.
#
# `leeway=60` absorbs clock skew between the Cognito signing service
# and the Fargate task's NTP-synced clock.
###############################################################################

from __future__ import annotations

import os
import time
from typing import Any, Dict, Optional, Tuple

import httpx
import jwt
from fastapi import Header, HTTPException, status


# ---------------------------------------------------------------------------
# Configuration. All values come from the ECS task definition's
# environment / secrets blocks. We read them lazily via `os.environ`
# at request time so the same image can be promoted across envs
# without rebuilding.
# ---------------------------------------------------------------------------
def _cognito_user_pool_id() -> str:
    value = os.environ.get("COGNITO_USER_POOL_ID")
    if not value:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="COGNITO_USER_POOL_ID is not configured",
        )
    return value


def _cognito_client_id() -> str:
    value = os.environ.get("COGNITO_CLIENT_ID")
    if not value:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="COGNITO_CLIENT_ID is not configured",
        )
    return value


def _aws_region() -> str:
    value = os.environ.get("AWS_REGION")
    if not value:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="AWS_REGION is not configured",
        )
    return value


def _jwks_url() -> str:
    return (
        f"https://cognito-idp.{_aws_region()}.amazonaws.com/"
        f"{_cognito_user_pool_id()}/.well-known/jwks.json"
    )


def _issuer_url() -> str:
    return (
        f"https://cognito-idp.{_aws_region()}.amazonaws.com/"
        f"{_cognito_user_pool_id()}"
    )


# ---------------------------------------------------------------------------
# JWKS cache. Cognito rotates its signing keys; the well-known JWKS
# endpoint publishes the current set. We cache the response for
# 10 minutes (in-process) keyed by the URL so all tasks share the
# same TTL. A failure to fetch logs but does not crash -- the next
# request will retry. (In practice, an outage of Cognito's JWKS
# endpoint is a Cognito-region-wide event and the task should serve
# stale keys until it recovers.)
# ---------------------------------------------------------------------------
_JWKS_TTL_SECONDS = 600
_jwks_cache: Dict[str, Tuple[float, Dict[str, Any]]] = {}


def get_jwks(force_refresh: bool = False) -> Dict[str, Any]:
    """Return the JWKS document, refreshing from Cognito when the
    10-minute TTL has expired (or when `force_refresh=True`).

    Returns the parsed JSON as a dict; the `keys` array is a list of
    JWK dicts that pyjwt can pass through directly.
    """
    url = _jwks_url()
    now = time.time()

    if not force_refresh:
        cached = _jwks_cache.get(url)
        if cached is not None and (now - cached[0]) < _JWKS_TTL_SECONDS:
            return cached[1]

    response = httpx.get(url, timeout=5.0)
    response.raise_for_status()
    jwks = response.json()
    _jwks_cache[url] = (now, jwks)
    return jwks


def _reset_jwks_cache_for_tests() -> None:
    """Test helper: clear the in-process cache."""
    _jwks_cache.clear()


# ---------------------------------------------------------------------------
# JWT verification. The hard-coded `algorithms=["RS256"]` is the single
# most important line in this file. Do not change it.
# ---------------------------------------------------------------------------
def verify_jwt(authorization: Optional[str] = Header(None)) -> Dict[str, Any]:
    """FastAPI dependency that extracts the Bearer token, verifies it
    against Cognito's JWKS, and returns the claims dict on success.

    `authorization` is declared `Optional[str]` (not `Header(...)`)
    so that a missing Authorization header produces a 401 from the
    explicit check below, NOT a 422 from FastAPI's automatic
    required-header validation. The 401 path is the security
    boundary's contract.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"reason": "missing_or_malformed_bearer"},
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = authorization[len("Bearer ") :].strip()
    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"reason": "empty_bearer_token"},
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        unverified_header = jwt.get_unverified_header(token)
    except jwt.InvalidTokenError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"reason": "malformed_token_header", "error": str(exc)},
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    kid = unverified_header.get("kid")
    if not kid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"reason": "missing_kid"},
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        jwks = get_jwks()
    except httpx.HTTPError as exc:
        # If the JWKS endpoint is down, refuse rather than fall back to
        # an unverified path. (Fail closed.)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"reason": "jwks_unavailable"},
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    # Find the key with the matching `kid`. The keys list is small
    # (typically 2-3) so a linear scan is fine.
    matching_key: Optional[Dict[str, Any]] = None
    for key in jwks.get("keys", []):
        if key.get("kid") == kid:
            matching_key = key
            break

    if matching_key is None:
        # Try a forced refresh in case of a recent rotation; if the
        # key still isn't present, the token is from a different
        # signing identity and we reject it.
        try:
            jwks = get_jwks(force_refresh=True)
            for key in jwks.get("keys", []):
                if key.get("kid") == kid:
                    matching_key = key
                    break
        except httpx.HTTPError:
            pass

        if matching_key is None:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail={"reason": "unknown_kid"},
                headers={"WWW-Authenticate": "Bearer"},
            )

    # Convert the JWK to a verification key that pyjwt understands.
    # Cognito publishes JWKs in the standard format; pyjwt's
    # algorithms module exposes `from_jwk` to convert. The test
    # stub in conftest.py attaches a `pem` field to the JWK for
    # convenience; production never has it.
    if "pem" in matching_key:
        verify_key: Any = matching_key["pem"]
    else:
        try:
            verify_key = jwt.algorithms.RSAAlgorithm.from_jwk(matching_key)
        except (KeyError, ValueError) as exc:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail={"reason": "unsupported_jwk"},
                headers={"WWW-Authenticate": "Bearer"},
            ) from exc

    try:
        # SECURITY-CRITICAL: algorithms=["RS256"] is the defense against
        # the alg=none and HS256-confusion attacks. Do NOT relax this.
        claims = jwt.decode(
            token,
            verify_key,
            algorithms=["RS256"],
            audience=_cognito_client_id(),
            issuer=_issuer_url(),
            leeway=60,
            options={
                "require": ["exp", "iat", "iss", "aud", "sub"],
            },
        )
    except jwt.ExpiredSignatureError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"reason": "token_expired"},
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
    except jwt.InvalidAudienceError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"reason": "invalid_audience"},
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
    except jwt.InvalidIssuerError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"reason": "invalid_issuer"},
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
    except jwt.InvalidAlgorithmError as exc:
        # This is the alg=none / HS256-confusion trip wire. The pyjwt
        # library raises this when the token's `alg` header is not in
        # the allowed list.
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"reason": "invalid_algorithm"},
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
    except jwt.InvalidTokenError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"reason": "invalid_token", "error": str(exc)},
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    return claims


# ---------------------------------------------------------------------------
# Authorization helper. The Cognito claims include:
#   - sub           : the user's stable UUID (their patient_id when
#                     the user is a patient).
#   - cognito:groups: a list of group names the user belongs to. We
#                     use the "clinicians" group as the role that
#                     grants access to any patient's record.
#
# The rule:
#   - a patient can read/delete their OWN data (claims["sub"] == patient_id)
#   - a member of the "clinicians" group can read any patient's data
# Everything else is 403.
# ---------------------------------------------------------------------------
def require_patient_or_clinician(claims: Dict[str, Any], patient_id: str) -> None:
    """Enforce that `claims` is authorized to access `patient_id`'s
    record. Raises HTTP 403 if not.
    """
    if claims.get("sub") == patient_id:
        return

    groups = claims.get("cognito:groups") or []
    if "clinicians" in groups:
        return

    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail={"reason": "not_authorized_for_patient"},
    )
