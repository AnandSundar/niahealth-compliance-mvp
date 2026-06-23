###############################################################################
# tests/test_access_request.py
# POST /access-request tests.
#
# The audit log S3 writes are stubbed via moto's @mock_aws so the
# tests can assert on what was written. We override the audit-bucket
# name env var so it points at a moto-managed bucket.
###############################################################################

from __future__ import annotations

import json
from typing import Any, Dict

import boto3
import pytest
from botocore.exceptions import ClientError
from moto import mock_aws


@pytest.fixture
def audit_bucket(monkeypatch: pytest.MonkeyPatch) -> str:
    """Create a moto-mocked S3 bucket to act as the audit bucket."""
    with mock_aws():
        s3 = boto3.client("s3", region_name="ca-central-1")
        bucket_name = "niahealth-audit-test"
        s3.create_bucket(
            Bucket=bucket_name,
            CreateBucketConfiguration={"LocationConstraint": "ca-central-1"},
        )
        yield bucket_name


class TestAccessRequest:
    def test_unauthenticated_returns_401(self, app_client) -> None:
        response = app_client.post(
            "/access-request",
            json={"patient_id": "abc-123", "request_type": "general", "justification": "wanting to know"},
        )
        assert response.status_code == 401

    def test_authenticated_returns_202_with_request_id(
        self, app_client, make_token, audit_bucket
    ) -> None:
        token = make_token(sub="abc-123")
        response = app_client.post(
            "/access-request",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "patient_id": "abc-123",
                "request_type": "general",
                "justification": "Right-to-access under PIPEDA s.8(3).",
            },
        )
        assert response.status_code == 202, response.text
        body = response.json()
        assert "request_id" in body
        assert "logged_at" in body

    def test_writes_to_audit_bucket(
        self, app_client, make_token, audit_bucket
    ) -> None:
        token = make_token(sub="abc-123")
        response = app_client.post(
            "/access-request",
            headers={"Authorization": f"Bearer {token}"},
            json={
                "patient_id": "abc-123",
                "request_type": "general",
                "justification": "Right-to-access under PIPEDA s.8(3).",
            },
        )
        assert response.status_code == 202

        # Inspect the audit bucket to confirm a key was written under
        # the access-requests/ prefix.
        s3 = boto3.client("s3", region_name="ca-central-1")
        listed = s3.list_objects_v2(Bucket=audit_bucket, Prefix="access-requests/")
        keys = [obj["Key"] for obj in listed.get("Contents", [])]
        assert len(keys) == 1, f"expected 1 access-requests object, got {keys}"
        assert keys[0].startswith("access-requests/")
        assert keys[0].endswith(".json")

        # Read the entry and validate its shape.
        got = s3.get_object(Bucket=audit_bucket, Key=keys[0])
        body = json.loads(got["Body"].read().decode("utf-8"))
        assert body["sub"] == "abc-123"
        assert body["patient_id"] == "abc-123"
        assert body["request_type"] == "general"
        assert "received_at" in body
