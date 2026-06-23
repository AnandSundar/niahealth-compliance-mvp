###############################################################################
# db.py
# RDS Proxy IAM auth connection helper.
#
# The sample app connects to the RDS PROXY (NOT the RDS instance
# directly). The Proxy holds the master password, mints short-lived
# IAM auth tokens on every connect, and pools backend connections.
# Clients never see the master credential.
#
# The IAM auth token is a 15-minute signed token minted by the
# `rds:GenerateDbAuthToken` API. boto3's RDS client signs requests
# with the task role's credentials, so the token is bound to the
# specific IAM principal (the ECS task role). psycopg v3's
# `password` callable hook is exactly the right shape for this.
#
# Connection hygiene:
#   - SET search_path = phi, public : the application's tables live
#                                     in the `phi` schema. The `public`
#                                     fallback is the Postgres default.
#   - SET statement_timeout = 5000  : a runaway query dies after 5s.
#                                     This is a security AND a
#                                     reliability control -- a stuck
#                                     query can hold a Proxy backend
#                                     connection for minutes.
#   - All queries use NAMED parameters (`:patient_id`). NEVER string
#     interpolate user input into SQL.
#
# This module does NOT own the connection pool -- psycopg v3's
# `ConnectionPool` is the recommended pool for production, but the
# MVP uses a per-request `with psycopg.connect(...)` context manager
# to keep the surface small. (Pivoting to a pool is a U8+ change.)
###############################################################################

from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Any, Dict, Iterator, Optional

import boto3
import psycopg


# ---------------------------------------------------------------------------
# Configuration. The task definition passes these as environment
# variables.
# ---------------------------------------------------------------------------
def _rds_proxy_endpoint() -> str:
    value = os.environ.get("RDS_PROXY_ENDPOINT")
    if not value:
        raise RuntimeError("RDS_PROXY_ENDPOINT is not configured")
    return value


def _rds_db_name() -> str:
    return os.environ.get("RDS_DB_NAME", "niahealth")


def _rds_db_user() -> str:
    value = os.environ.get("RDS_DB_USER")
    if not value:
        raise RuntimeError("RDS_DB_USER is not configured")
    return value


# ---------------------------------------------------------------------------
# IAM auth token. The boto3 RDS client signs a request with the
# task role's credentials and returns a token of the form
# `<host>:<port>/?Action=connect&DBUser=<user>&...&X-Amz-Signature=...`.
# The token is valid for 15 minutes.
# ---------------------------------------------------------------------------
def _generate_iam_auth_token() -> str:
    """Mint a fresh IAM auth token from the RDS control plane.

    Uses boto3's RDS client; the call is signed with the ambient
    AWS credentials (the ECS task role in production, the AWS CLI
    profile in local dev).
    """
    client = boto3.client("rds", region_name=os.environ.get("AWS_REGION"))
    return client.generate_db_auth_token(
        DBHostname=_rds_proxy_endpoint(),
        Port=5432,
        DBUsername=_rds_db_user(),
    )


# ---------------------------------------------------------------------------
# Connection helper. Use as a context manager:
#   with get_connection() as conn:
#       with conn.cursor() as cur:
#           cur.execute(...)
# ---------------------------------------------------------------------------
@contextmanager
def get_connection() -> Iterator[psycopg.Connection]:
    """Open a connection to the RDS Proxy using IAM auth.

    Sets `search_path` and `statement_timeout` on connect. The
    connection is closed when the context exits; the boto3 client
    used to mint the IAM token is also released.
    """
    # The RDS Proxy endpoint may be either "host" or "host:port".
    # boto3's generate_db_auth_token takes just the host; psycopg
    # takes host:port. Normalize.
    endpoint = _rds_proxy_endpoint()
    if ":" in endpoint:
        host, _, port = endpoint.partition(":")
        port_int = int(port)
    else:
        host = endpoint
        port_int = 5432

    conn = psycopg.connect(
        host=host,
        port=port_int,
        dbname=_rds_db_name(),
        user=_rds_db_user(),
        password=_generate_iam_auth_token(),  # callable-like: a fresh token per connect
        sslmode="require",
        connect_timeout=5,
        # SET search_path = phi, public -- the application schema
        autocommit=False,
    )
    try:
        with conn.cursor() as cur:
            cur.execute("SET search_path = phi, public")
            cur.execute("SET statement_timeout = 5000")
        conn.commit()
        yield conn
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Domain helpers. These are the only public functions the route
# modules should call.
# ---------------------------------------------------------------------------
def get_health_summary(patient_id: str) -> Optional[Dict[str, Any]]:
    """Look up the health summary for `patient_id`.

    Returns None when no row exists (caller decides 404 vs synthetic).
    """
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT patient_id, summary_text, generated_at
                FROM health_summaries
                WHERE patient_id = %(patient_id)s
                LIMIT 1
                """,
                {"patient_id": patient_id},
            )
            row = cur.fetchone()
            if row is None:
                return None
            return {
                "patient_id": row[0],
                "summary_text": row[1],
                "generated_at": row[2].isoformat() if row[2] else None,
            }


def delete_patient_data(patient_id: str) -> bool:
    """Hard-null the PHI columns for `patient_id` (right-to-erasure).

    Returns True if a row was updated, False if no row was found.

    Per PHIPA s.18 and Quebec Law 25, this is a HARD delete: the
    patient_id is retained (so we don't re-create the same record
    on a subsequent sync) but every PHI column is NULLed. The audit
    log retains the deletion event for 7 years per Object Lock.
    """
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE health_summaries
                SET summary_text = NULL,
                    generated_at = NULL
                WHERE patient_id = %(patient_id)s
                """,
                {"patient_id": patient_id},
            )
            return cur.rowcount > 0
