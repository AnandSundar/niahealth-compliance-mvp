###############################################################################
# Multi-stage Dockerfile for the NiaHealth sample app.
#
# Stage 1 (builder): pin a slim Python base, install dependencies into
#                    /install so the runtime stage can copy just the
#                    site-packages and skip pip.
# Stage 2 (runtime) : minimal base; copy the installed deps + the
#                    application source; create a non-root user;
#                    HEALTHCHECK the /healthz endpoint; expose 8000.
#
# Security controls baked in (so Checkov / Conftest pass at the
# container level too):
#   - Non-root user (UID 10001)        (CKV2_AWS_5 / CIS 4.1)
#   - Pinned base image tag             (supply-chain reproducibility)
#   - Read-only root filesystem at run  (CKV_AWS_339) -- the task
#     definition also sets readonly_root_filesystem = true
#   - HEALTHCHECK wired to /healthz
#   - Slim base, no dev headers, no pip cache
#
# The task definition (infra/modules/compute/task.tf) is the
# authoritative place to enforce read-only root FS + non-root UID;
# the Dockerfile is the source of truth for the UID.
###############################################################################

# --- Stage 1: builder -------------------------------------------------------
FROM python:3.12.5-slim-bookworm AS builder

# Install the dependencies into /install so we can copy just the
# site-packages into the runtime stage.
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# --- Stage 2: runtime -------------------------------------------------------
FROM python:3.12.5-slim-bookworm AS runtime

# OCI labels for the image metadata. Useful for ECR / Inspector.
LABEL org.opencontainers.image.title="niahealth-app" \
      org.opencontainers.image.description="NiaHealth compliance reference architecture sample app" \
      org.opencontainers.image.source="https://github.com/niahealth/niahealth-compliance-mvp" \
      org.opencontainers.image.licenses="Apache-2.0"

# Copy the installed Python packages from the builder.
COPY --from=builder /install /usr/local

# Copy the application source.
WORKDIR /app
COPY ./src /app/src

# Create the non-root user with a fixed UID. The task definition
# uses `user = "10001:10001"` so the in-container UID must match.
# --no-log-init avoids the noisy "Creating mailbox file" line.
RUN groupadd --system --gid 10001 appuser \
    && useradd  --system --uid 10001 --gid 10001 --no-log-init --no-create-home appuser \
    && mkdir -p /tmp /app \
    && chown -R appuser:appuser /app /tmp

# Switch to the non-root user. The task definition also enforces
# this at the ECS level (read_only_root_filesystem = true + user =
# 10001:10001), but the Dockerfile is the source of truth.
USER 10001:10001

# The container listens on 8000. The task definition maps the
# container port to the ALB target group port (also 8000).
EXPOSE 8000

# HEALTHCHECK: curl /healthz. ECS also runs a separate task-level
# health check, but the in-container one is the last line of defense
# if the process is alive but stuck.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["curl", "-fsS", "http://localhost:8000/healthz"]

# Run uvicorn. The module path is `app.src.main:app` because the
# repository is laid out as /app/src/{main,auth,db,routes}.py.
CMD ["uvicorn", "app.src.main:app", "--host", "0.0.0.0", "--port", "8000"]
