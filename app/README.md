# NiaHealth Sample App

A minimal but real 3-tier health-summary REST API demonstrating
end-to-end compliance controls: Cognito JWT auth, Fargate in
isolated subnets, RDS Proxy IAM auth, ALB + WAFv2 in front.

The app is intentionally small (3 protected routes + 1 health
probe) so the security boundary is easy to audit. The same
controls would apply to a 30-route application.

## Routes

| Method | Path                          | AuthN | AuthZ                        | Purpose                                      |
| ------ | ----------------------------- | ----- | ---------------------------- | -------------------------------------------- |
| GET    | `/healthz`                    | none  | n/a                          | Liveness probe (ECS + ALB target group)      |
| GET    | `/health-summary/{patient_id}`| JWT   | `sub == patient_id` OR group `clinicians` | Read a health summary                |
| POST   | `/access-request`             | JWT   | any authenticated user       | PIPEDA 4.9 / Quebec Law 25 access request    |
| POST   | `/delete-my-data`             | JWT   | `sub == patient_id` OR group `clinicians` | PHIPA s.18 / Quebec Law 25 right-to-erasure |

## Build

```bash
# from this directory
docker build -t niahealth-app:test .
```

The image is multi-stage (`builder` -> `runtime`), runs as UID
10001 (non-root), and uses a slim Debian base pinned to
`python:3.12.5-slim-bookworm`.

## Run locally

The app reads the following env vars. They are set by the ECS task
definition in production; for local dev you can use a `.env` file
or the AWS CLI profile for RDS IAM auth.

| Env var                     | Source                                | Example                                                     |
| --------------------------- | ------------------------------------- | ----------------------------------------------------------- |
| `COGNITO_USER_POOL_ID`      | task definition (plain env)           | `ca-central-1_aBcD1234`                                    |
| `COGNITO_CLIENT_ID`         | task definition (plain env)           | `5e9f...clientid`                                           |
| `COGNITO_CLIENT_SECRET`     | task definition (secrets block)       | (from Secrets Manager)                                      |
| `AWS_REGION`                | task definition (plain env)           | `ca-central-1`                                              |
| `RDS_PROXY_ENDPOINT`        | task definition (plain env)           | `niahealth-dev-rds-proxy.proxy-xxx.ca-central-1.rds.amazonaws.com` |
| `RDS_DB_NAME`               | task definition (plain env)           | `niahealth`                                                 |
| `RDS_DB_USER`               | task definition (plain env)           | `niahealth_app`                                             |
| `AUDIT_BUCKET_NAME`         | task definition (plain env)           | `niahealth-audit-dev`                                        |
| `GIT_SHA`                   | CI build (plain env)                  | `a1b2c3d4...`                                                |
| `BUILD_TIMESTAMP`           | CI build (plain env)                  | `2026-06-23T12:00:00Z`                                       |

```bash
# local dev (no live AWS):
docker run --rm -p 8000:8000 \
  -e COGNITO_USER_POOL_ID=local \
  -e COGNITO_CLIENT_ID=local \
  -e AWS_REGION=ca-central-1 \
  -e AUDIT_BUCKET_NAME=local \
  niahealth-app:test
```

## Test

```bash
# from this directory
python -m venv .venv
. .venv/Scripts/Activate.ps1   # Windows
# . .venv/bin/activate         # POSIX
pip install -r requirements.txt
pytest -v
```

The tests use `moto` to mock S3 (audit log writes) and a
hand-rolled RSA key pair to stub the Cognito JWKS endpoint. They
run without a live AWS account.

Critical test cases in `tests/test_auth.py`:

- `test_alg_none_attack_is_rejected` -- the original JWT footgun
- `test_alg_hs256_confusion_is_rejected` -- the modern variant

Both confirm the explicit `algorithms=["RS256"]` in `auth.py` holds.

## Security controls baked in

1. **Cognito JWT verification with explicit `algorithms=["RS256"]`.**
   Defends against the alg=none and HS256 confusion attacks. The
   `pyjwt` library's default `decode()` is `algorithms=["HS256"]`
   and is therefore unsafe; the explicit pin is the only safe
   configuration.

2. **`aud` and `iss` checks.** Tokens are verified for the specific
   User Pool Client ID and User Pool issuer URL. A token signed by
   a different User Pool is rejected.

3. **`leeway=60`.** Absorbs 60s of clock skew between the Cognito
   signing service and the Fargate task.

4. **JWKS cache with 10-minute TTL.** Avoids hammering the Cognito
   JWKS endpoint. Keyed by URL so a region or pool change resets
   the cache.

5. **RDS Proxy IAM auth.** The app mints a fresh IAM auth token on
   every connect (boto3 RDS client); the master password is never
   in the application. `sslmode=require` enforces TLS to the
   Proxy.

6. **`statement_timeout=5000`.** A runaway query dies after 5s. A
   stuck query would otherwise pin a Proxy backend connection.

7. **Named parameter binding.** All queries use psycopg's
   `%({name})s` syntax. No string interpolation.

8. **Audit log writes are CRITICAL.** A failure to write the
   access-request or delete-my-data audit entry returns 503 to the
   caller so the operator can retry -- we never silently drop a
   compliance event.

9. **Hard delete, not soft delete.** `delete-my-data` NULLs the
   PHI columns in the RDS row. The patient_id is retained so a
   future EMR sync doesn't re-create the same record. The audit
   log retains the deletion event for 7 years per Object Lock.

10. **Read-only root filesystem + non-root user at runtime.** The
    task definition sets `readonly_root_filesystem = true` and
    `user = "10001:10001"`; the Dockerfile creates the matching
    UID.

## Layout

```
app/
  Dockerfile
  README.md
  requirements.txt
  src/
    __init__.py
    main.py             -- FastAPI app + /healthz + middleware
    auth.py             -- Cognito JWT verification (security boundary)
    db.py               -- RDS Proxy IAM auth connection helper
    routes/
      __init__.py
      health_summary.py -- GET /health-summary/{patient_id}
      access_request.py -- POST /access-request (PIPEDA 4.9)
      delete_my_data.py -- POST /delete-my-data (PHIPA s.18)
  tests/
    __init__.py
    conftest.py         -- shared fixtures (RSA keypair, JWKS stub, TestClient)
    test_auth.py        -- JWT verification cases (incl. alg attacks)
    test_health_summary.py
    test_access_request.py
```
