FROM node:24-bookworm AS builder

ARG OPENCLAW_REPO="https://github.com/openclaw/openclaw.git"
ARG OPENCLAW_REF="v2026.5.3-1"
ARG OPENCLAW_STABLE_REFRESH="2026-05-05"

ENV DEBIAN_FRONTEND=noninteractive
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
ENV PATH="/root/.bun/bin:/src/openclaw/node_modules/.bin:${PATH}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        openssl \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable

WORKDIR /tmp
RUN curl -fsSL https://bun.sh/install | bash

WORKDIR /src
RUN if [ "${OPENCLAW_REF}" = "stable" ]; then \
        echo "Resolving latest stable tag (refresh hint: ${OPENCLAW_STABLE_REFRESH})"; \
        resolved_ref="$(git ls-remote --tags --refs "${OPENCLAW_REPO}" \
          | awk '{print $2}' \
          | sed 's#refs/tags/##' \
          | grep -E '^v[0-9]+(\.[0-9]+)*(-[0-9]+)?$' \
          | sort -rV \
          | head -n 1)"; \
      else \
        resolved_ref="${OPENCLAW_REF}"; \
      fi \
    && test -n "${resolved_ref}" \
    && echo "Checking out OpenClaw ref: ${resolved_ref}" \
    && git clone --depth 1 --branch "${resolved_ref}" "${OPENCLAW_REPO}" openclaw \
    && printf '%s\n' "${resolved_ref}" > /tmp/openclaw-build-ref \
    && git -C openclaw rev-parse HEAD > /tmp/openclaw-build-commit

WORKDIR /src/openclaw
RUN cp /tmp/openclaw-build-ref .openclaw-build-ref \
    && cp /tmp/openclaw-build-commit .openclaw-build-commit

RUN MAKEFLAGS="-j1" PNPM_CHILD_CONCURRENCY=1 pnpm install \
    --no-frozen-lockfile \
    --no-engine-strict \
    --network-concurrency 1 \
    && pnpm store prune

RUN pnpm rebuild esbuild sharp

# OpenClaw v2026.5.x keeps the control UI in the repository-level ui/ directory.
# Build the gateway first, then build UI last so dist/control-ui survives dist cleanup.
RUN test -d ui
RUN NODE_OPTIONS="--max-old-space-size=4096" pnpm build
RUN OPENCLAW_CONTROL_UI_BASE_PATH=/openclaw/ NODE_OPTIONS="--max-old-space-size=4096" sh -c '\
      if pnpm run | grep -q "ui:build"; then \
        pnpm ui:build; \
      else \
        cd ui && pnpm build; \
      fi \
    '


FROM node:24-bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_ENV=production
ENV OPENCLAW_HOME=/root/.openclaw
ENV OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json
ENV OPENCLAW_STATE_DIR=/root/.openclaw/state
ENV OPENCLAW_REPO_DIR=/app/openclaw
ENV OPENCLAW_DEFAULT_MODEL=openrouter/free
ENV SPACE_APP_PORT=7860

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apache2-utils \
        ca-certificates \
        nginx \
        openssl \
        python3 \
        python3-pip \
        curl \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf

RUN python3 -m pip install --break-system-packages --no-cache-dir huggingface_hub==1.7.1 requests==2.31.0

WORKDIR /app
COPY --from=builder /src/openclaw /app/openclaw
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/start.sh /app/docker/start.sh
COPY docker/openclaw.template.json /app/docker/openclaw.template.json
COPY docker/hf-state-store.py /app/docker/hf-state-store.py
COPY docker/backup_api.py /app/docker/backup_api.py
COPY docker/openrouter_proxy.py /app/docker/openrouter_proxy.py
COPY docker/admin_api.py /app/docker/admin_api.py

RUN chmod +x /app/docker/start.sh /app/docker/hf-state-store.py /app/docker/backup_api.py /app/docker/openrouter_proxy.py /app/docker/admin_api.py \
    && mkdir -p /root/.openclaw/.openclaw/skills /var/lib/nginx /var/log/nginx /run/nginx \
    && chmod -R 777 /root/.openclaw

EXPOSE 7860
CMD ["/app/docker/start.sh"]
