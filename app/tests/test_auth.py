###############################################################################
# tests/test_auth.py
# JWT verification test cases.
#
# These tests exercise the verify_jwt dependency in isolation. The
# underlying JWKS endpoint is stubbed by conftest.py's stub_jwks
# fixture; tests never hit the network.
#
# The alg=none and alg=HS256 confusion tests are the load-bearing
# cases -- the explicit `algorithms=["RS256"]` in auth.py is the
# only thing that keeps the library from accepting a forged token.
###############################################################################

from __future__ import annotations

import time

import jwt
import pytest


class TestVerifyJwt:
    def test_missing_authorization_returns_401(self, app_client) -> None:
        response = app_client.get("/health-summary/abc-123")
        assert response.status_code == 401
        assert response.json()["error"]["detail"]["reason"] == "missing_or_malformed_bearer"

    def test_malformed_bearer_returns_401(self, app_client) -> None:
        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": "Token abc.def.ghi"},
        )
        assert response.status_code == 401
        assert response.json()["error"]["detail"]["reason"] == "missing_or_malformed_bearer"

    def test_empty_bearer_returns_401(self, app_client) -> None:
        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": "Bearer "},
        )
        assert response.status_code == 401
        assert response.json()["error"]["detail"]["reason"] == "empty_bearer_token"

    def test_expired_token_returns_401_token_expired(self, app_client, make_token) -> None:
        token = make_token(exp_offset=-60)  # expired 1 min ago
        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 401
        assert response.json()["error"]["detail"]["reason"] == "token_expired"

    def test_wrong_audience_returns_401(self, app_client, make_token) -> None:
        token = make_token(aud="wrong-client")
        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 401
        assert response.json()["error"]["detail"]["reason"] == "invalid_audience"

    def test_wrong_issuer_returns_401(self, app_client, make_token) -> None:
        token = make_token(iss="https://cognito-idp.us-east-1.amazonaws.com/someotherpool")
        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 401
        assert response.json()["error"]["detail"]["reason"] == "invalid_issuer"

    def test_valid_token_passes_auth(self, app_client, make_token, stub_db) -> None:
        token = make_token(sub="abc-123")
        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": f"Bearer {token}"},
        )
        # The auth boundary passes; the route layer then returns
        # either 200 (db row) or 200 (synthetic) or 5xx (no DB).
        # We accept any 2xx here.
        assert response.status_code == 200, response.text

    def test_alg_none_attack_is_rejected(self, app_client, rsa_keypair) -> None:
        """A forged token with `alg: none` MUST be rejected.

        This is the original JWT footgun -- if a library accepts
        `alg: none`, an attacker can mint an unverified token with
        any claims. pyjwt enforces the allowlist by default, but
        tests confirm our explicit `algorithms=["RS256"]` holds.
        """
        now = int(time.time())
        claims = {
            "sub": "abc-123",
            "aud": "test-client-id",
            "iss": "https://cognito-idp.ca-central-1.amazonaws.com/ca-central-1_testpool",
            "iat": now,
            "exp": now + 3600,
        }
        # pyjwt exposes a way to sign with alg=none only when called
        # via the lower-level API. We craft the token manually.
        import base64
        import json

        def _b64url(data: bytes) -> str:
            return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

        header = _b64url(json.dumps({"alg": "none", "kid": "test-kid-1", "typ": "JWT"}).encode())
        payload = _b64url(json.dumps(claims).encode())
        # No signature segment.
        token = f"{header}.{payload}."

        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": f"Bearer {token}"},
        )
        # Either 401 (rejected by pyjwt's allowlist) or 401 because
        # the alg=none token won't verify against the RS256 key.
        # Both are acceptable; the bug we are guarding against is
        # "the route returned 200 with attacker-controlled claims".
        assert response.status_code == 401, response.text

    def test_alg_hs256_confusion_is_rejected(self, app_client, rsa_keypair) -> None:
        """A forged token signed with HS256 using the public key as
        the secret MUST be rejected.

        In an HS256 confusion attack, the attacker takes the RSA
        public key (which the server has access to) and uses it as
        the HMAC secret to sign a token. If the server's verification
        logic doesn't pin the algorithm, pyjwt will accept the
        forged token because the public key IS a valid secret for
        HMAC purposes.

        Our explicit `algorithms=["RS256"]` makes the library reject
        any non-RS256 token before the signature is even checked.
        """
        import base64
        import hashlib
        import hmac
        import json

        def _b64url(data: bytes) -> str:
            return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

        # The "public key" the attacker would have: the JWK form.
        # In a real attack, they'd use the actual PEM/der of the
        # public key. We use the JWK JSON as the HMAC secret here
        # because that's what the attacker would have scraped from
        # the JWKS endpoint.
        secret = json.dumps(rsa_keypair["jwk"]).encode("utf-8")

        now = int(time.time())
        claims = {
            "sub": "abc-123",
            "aud": "test-client-id",
            "iss": "https://cognito-idp.ca-central-1.amazonaws.com/ca-central-1_testpool",
            "iat": now,
            "exp": now + 3600,
        }
        header = _b64url(json.dumps({"alg": "HS256", "kid": "test-kid-1", "typ": "JWT"}).encode())
        payload = _b64url(json.dumps(claims).encode())
        signing_input = f"{header}.{payload}".encode("ascii")
        signature = hmac.new(secret, signing_input, hashlib.sha256).digest()
        token = f"{header}.{payload}.{_b64url(signature)}"

        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 401, response.text
