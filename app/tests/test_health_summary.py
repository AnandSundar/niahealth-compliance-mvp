###############################################################################
# tests/test_health_summary.py
# GET /health-summary/{patient_id} tests.
#
# These tests stub out the DB layer (no live Postgres) and focus on
# the auth + authz model:
#   - unauthenticated -> 401
#   - patient-self    -> 200
#   - patient-other   -> 403
#   - clinician-any   -> 200
#   - empty DB        -> 200 with source: "synthetic"
###############################################################################

from __future__ import annotations

from typing import Any, Dict, Optional

import pytest


class TestHealthSummary:
    def test_unauthenticated_returns_401(self, app_client) -> None:
        response = app_client.get("/health-summary/abc-123")
        assert response.status_code == 401

    def test_patient_self_returns_200(self, app_client, make_token, stub_db) -> None:
        token = make_token(sub="abc-123")
        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["patient_id"] == "abc-123"
        assert body["source"] == "synthetic"  # stub_db returns None

    def test_patient_other_returns_403(self, app_client, make_token, stub_db) -> None:
        token = make_token(sub="abc-123")
        response = app_client.get(
            "/health-summary/xyz-789",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 403
        assert response.json()["error"]["detail"]["reason"] == "not_authorized_for_patient"

    def test_clinician_any_returns_200(self, app_client, make_token, stub_db) -> None:
        token = make_token(sub="dr-1", groups=["clinicians"])
        response = app_client.get(
            "/health-summary/any-patient-id",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["patient_id"] == "any-patient-id"

    def test_synthetic_when_empty_db(self, app_client, make_token, stub_db) -> None:
        stub_db.health_summary = None
        token = make_token(sub="abc-123")
        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200
        body = response.json()
        assert body["source"] == "synthetic"

    def test_db_row_when_populated(self, app_client, make_token, stub_db) -> None:
        stub_db.health_summary = {
            "patient_id": "abc-123",
            "summary_text": "real record from db",
            "generated_at": "2026-01-15T12:00:00+00:00",
        }
        token = make_token(sub="abc-123")
        response = app_client.get(
            "/health-summary/abc-123",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200
        body = response.json()
        assert body["source"] == "db"
        assert body["summary_text"] == "real record from db"
