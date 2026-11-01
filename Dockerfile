FROM node:24-bookworm-slim

# OpenClaw 安装方式：npm 官方预构建包。
# 相比源码构建（git clone + pnpm install + tsdown 打包，约 30-40 分钟），
# 这种方式约 2-5 分钟，镜像体积也明显更小。
# 取值："latest" 自动解析 npm 最新稳定版；也可指定具体版本号（如 2026.10.9）用于回滚。
ARG OPENCLAW_NPM_VERSION="latest"

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

# 安装常用 Python 库（全部为纯 Python wheel，无需编译链；
# 因此镜像中刻意不安装 build-essential / python3-dev，节省约 250MB）
RUN python3 -m pip install --break-system-packages --no-cache-dir \
    huggingface_hub==1.7.1 \
    requests==2.31.0 \
    pydantic \
    httpx

# 解压 npm 包到 OPENCLAW_REPO_DIR 并安装运行时依赖（仅 prod，不含 devDependencies）。
# .openclaw-build-ref 记录实际安装版本，start.sh 用它匹配飞书插件版本、并在控制台展示。
RUN set -eux; \
    version="${OPENCLAW_NPM_VERSION}"; \
    if [ "${version}" = "latest" ]; then version="$(npm view openclaw version --silent 2>/dev/null)"; fi; \
    echo "Installing OpenClaw ${version}"; \
    tarball="$(npm view "openclaw@${version}" dist.tarball --silent 2>/dev/null)"; \
    mkdir -p "${OPENCLAW_REPO_DIR}"; \
    curl -fsSL "${tarball}" | tar -xz --strip-components=1 -C "${OPENCLAW_REPO_DIR}"; \
    cd "${OPENCLAW_REPO_DIR}"; \
    npm install --omit=dev --no-audit --no-fund --engine-strict=false --legacy-peer-deps; \
    printf '%s\n' "${version}" > "${OPENCLAW_REPO_DIR}/.openclaw-build-ref"; \
    npm cache clean --force

WORKDIR /app
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/start.sh /app/docker/start.sh
COPY docker/openclaw.template.json /app/docker/openclaw.template.json
COPY docker/hf-state-store.py /app/docker/hf-state-store.py
COPY docker/backup_api.py /app/docker/backup_api.py
COPY docker/openrouter_proxy.py /app/docker/openrouter_proxy.py
COPY docker/openrouter_models.py /app/docker/openrouter_models.py
COPY docker/admin_api.py /app/docker/admin_api.py

RUN chmod +x /app/docker/start.sh /app/docker/hf-state-store.py /app/docker/backup_api.py /app/docker/openrouter_proxy.py /app/docker/openrouter_models.py /app/docker/admin_api.py \
    && mkdir -p /root/.openclaw/workspace/skills /var/lib/nginx /var/log/nginx /run/nginx \
    && chmod -R 777 /root/.openclaw

EXPOSE 7860
CMD ["/app/docker/start.sh"]
