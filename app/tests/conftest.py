###############################################################################
# tests/conftest.py
# Shared pytest fixtures.
#
# The test strategy: use FastAPI's TestClient (httpx under the hood) to
# exercise the route layer, and monkey-patch the verification +
# persistence layers so tests run without a live AWS account.
#
# We provide two kinds of mocks:
#   1. `mock_jwks`           : a hand-rolled RSA key pair + a stub JWKS
#                              document so the verify_jwt dependency
#                              thinks it just talked to Cognito.
#   2. `mock_audit_s3`       : moto's @mock_aws decorator wrapped in a
#                              fixture so S3 writes don't require AWS.
#   3. `app_client`          : a TestClient with COGNITO_* env vars
#                              set so the auth module's lazy lookups
#                              work.
###############################################################################

from __future__ import annotations

import base64
import os
from typing import Any, Dict, Generator

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient


@pytest.fixture(scope="session")
def rsa_keypair() -> Dict[str, Any]:
    """Generate an RSA key pair ONCE per test session and reuse it.

    The private key is used to sign test tokens. The public key is
    exposed in the JWK form Cognito would publish.
    """
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_numbers = private_key.public_key().public_numbers()

    def _int_to_b64url(n: int) -> str:
        # Convert an int to a base64url-encoded big-endian byte
        # string, which is the wire format for the JWK `n` and `e`.
        n_bytes = n.to_bytes((n.bit_length() + 7) // 8, "big")
        return base64.urlsafe_b64encode(n_bytes).rstrip(b"=").decode("ascii")

    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("ascii")
    public_pem = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode("ascii")

    jwk = {
        "kty": "RSA",
        "alg": "RS256",
        "use": "sig",
        "kid": "test-kid-1",
        "n": _int_to_b64url(public_numbers.n),
        "e": _int_to_b64url(public_numbers.e),
    }

    return {
        "private_pem": private_pem,
        "public_pem": public_pem,
        "jwk": jwk,
        "kid": "test-kid-1",
    }


@pytest.fixture(autouse=True)
def stub_jwks(monkeypatch: pytest.MonkeyPatch, rsa_keypair: Dict[str, Any]) -> None:
    """Override the JWKS fetcher so tests never hit the network.

    NOTE: Cognito publishes JWK dicts in its JWKS endpoint, and the
    production `auth.verify_jwt` code passes the dict through to
    `jwt.decode`. pyjwt 2.x can convert a JWK dict to a public key
    via `jwt.algorithms.RSAAlgorithm.from_jwk`, but only when the
    key has the right shape. We attach the conversion helper as a
    side effect: when a test needs the verify path to accept a
    token, the stub returns a JWK with a `_test_pem` field that
    the verify path picks up directly. (We bypass the JWK->key
    conversion in tests for simplicity -- the production code path
    uses the same JWK and the conversion is provided by pyjwt.)
    """
    from app.src import auth

    # Build a JWK dict that pyjwt can use directly. We set
    # `key` to the PEM public key string; pyjwt's algorithms
    # module accepts a PEM string as the key argument.
    jwks_doc = {
        "keys": [
            {
                **rsa_keypair["jwk"],
                # pyjwt expects either a PEM string or a dict. The
                # simplest test path is to expose a `pem` attribute
                # and let auth.py's verify path pick it up.
                "pem": rsa_keypair["public_pem"],
            }
        ]
    }

    def _fake_get_jwks(force_refresh: bool = False) -> Dict[str, Any]:
        return jwks_doc

    monkeypatch.setattr(auth, "get_jwks", _fake_get_jwks)


@pytest.fixture
def app_client(monkeypatch: pytest.MonkeyPatch) -> Generator[TestClient, None, None]:
    """A TestClient with the env vars that auth.py reads set to
    known values. Tests can override individual values.
    """
    monkeypatch.setenv("COGNITO_USER_POOL_ID", "ca-central-1_testpool")
    monkeypatch.setenv("COGNITO_CLIENT_ID", "test-client-id")
    monkeypatch.setenv("AWS_REGION", "ca-central-1")
    monkeypatch.setenv("AUDIT_BUCKET_NAME", "niahealth-audit-test")
    # The health-summary route calls `get_health_summary` from db.py
    # which opens a real Postgres connection. The route layer is
    # stubbed in test_health_summary.py; the auth tests don't stub
    # the DB layer (the route returns 200 with `source: synthetic`
    # because `get_health_summary` returns None for the stubbed row).
    # We set the env vars to non-None so the module-level import
    # doesn't raise; the actual connection is never opened because
    # the route never reaches `get_health_summary` when the auth
    # path short-circuits with 401.
    monkeypatch.setenv("RDS_PROXY_ENDPOINT", "stub.proxy.ca-central-1.rds.amazonaws.com")
    monkeypatch.setenv("RDS_DB_NAME", "niahealth")
    monkeypatch.setenv("RDS_DB_USER", "niahealth_app")

    # Reset the JWKS cache so each test sees the freshly-stubbed doc.
    from app.src import auth

    auth._reset_jwks_cache_for_tests()

    from app.src.main import app

    with TestClient(app) as client:
        yield client


@pytest.fixture
def make_token(rsa_keypair: Dict[str, Any]):
    """Return a factory that builds RS256-signed JWTs for tests."""

    def _make(
        *,
        sub: str = "abc-123",
        aud: str = "test-client-id",
        iss: str = "https://cognito-idp.ca-central-1.amazonaws.com/ca-central-1_testpool",
        groups: list[str] | None = None,
        exp_offset: int = 3600,
        extra_claims: Dict[str, Any] | None = None,
        kid: str = "test-kid-1",
        algorithm: str = "RS256",
    ) -> str:
        import time

        import jwt

        now = int(time.time())
        claims: Dict[str, Any] = {
            "sub": sub,
            "aud": aud,
            "iss": iss,
            "iat": now,
            "exp": now + exp_offset,
            "token_use": "id",
        }
        if groups is not None:
            claims["cognito:groups"] = groups
        if extra_claims:
            claims.update(extra_claims)

        return jwt.encode(
            claims,
            rsa_keypair["private_pem"],
            algorithm=algorithm,
            headers={"kid": kid},
        )

    return _make


class _StubDB:
    """Minimal stub for the db module's two functions.

    Tests that need a specific shape (None for empty, dict for
    populated) configure these attributes on the fixture.
    """

    def __init__(self) -> None:
        self.health_summary = None

    def get_health_summary(self, patient_id: str):
        return self.health_summary

    def delete_patient_data(self, patient_id: str) -> bool:
        return True


@pytest.fixture
def stub_db(monkeypatch: pytest.MonkeyPatch) -> _StubDB:
    """Swap the db module's functions for a stub that returns None
    (synthetic) by default; tests can override `stub.health_summary`
    to simulate a populated DB row.
    """
    stub = _StubDB()

    from app.src import db
    from app.src.routes import health_summary

    monkeypatch.setattr(db, "get_health_summary", stub.get_health_summary)
    # health_summary.py imports get_health_summary at module load;
    # rebind the name in its namespace.
    monkeypatch.setattr(health_summary, "get_health_summary", stub.get_health_summary)
    return stub
