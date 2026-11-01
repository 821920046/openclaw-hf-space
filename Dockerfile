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

# --- 镜像瘦身：删除运行时用不到的纯元数据（约 -95MB）---
# 每一类都核对过引用关系，不是凭感觉删：
#   *.map   source map，只影响堆栈可读性。dist 内的 js 中 sourceMappingURL 出现次数为 0，
#           这些 map 全在 node_modules 里，纯冗余。
#   *.d.ts  TypeScript 类型声明，Node 运行时从不读取（package.json 的 types 字段只给编译器用）。
#   *.md    各依赖的 README/CHANGELOG。保留 LICENSE/COPYING/NOTICE 以满足许可证合规。
#   docs/   官方文档目录，运行时不读取。
# 刻意不动 dist/ 下的任何文件：dist/postinstall-content-inventory.json 会按 sha256+size
# 逐文件校验 dist 树（comparePackageDistContentInventory），删 dist 里的东西可能在
# 后续 package lifecycle 检查时抛 "Invalid package dist content inventory"。
RUN set -eux; \
    rm -rf "${OPENCLAW_REPO_DIR}/docs"; \
    find "${OPENCLAW_REPO_DIR}/node_modules" -type f -name "*.map" -delete; \
    find "${OPENCLAW_REPO_DIR}/node_modules" -type f -name "*.d.ts" -delete; \
    find "${OPENCLAW_REPO_DIR}/node_modules" -type f -name "*.md" \
        ! -iname "license*" ! -iname "copying*" ! -iname "notice*" -delete; \
    du -sh "${OPENCLAW_REPO_DIR}"

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

# 防御性修复行尾：在 Windows 上编辑/上传的文件可能带 CRLF，Linux 容器里会直接炸——
# start.sh 的 shebang 变成 "#!/usr/bin/env bash\r"，报 /usr/bin/env: 'bash\r': No such file or directory；
# nginx.conf 会解析失败。构建时统一去掉行尾 \r，从根上避免这类问题。
RUN sed -i 's/\r$//' /app/docker/start.sh /app/docker/*.py /etc/nginx/nginx.conf

EXPOSE 7860
CMD ["/app/docker/start.sh"]
