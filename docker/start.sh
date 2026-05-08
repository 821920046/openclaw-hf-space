#!/usr/bin/env bash
set -euo pipefail

# --- 1. 基础环境配置 ---
export OPENCLAW_HOME="${OPENCLAW_HOME:-/root/.openclaw}"
export OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_HOME}/openclaw.json}"
export OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-${OPENCLAW_HOME}/state}"
export OPENCLAW_REPO_DIR="${OPENCLAW_REPO_DIR:-/app/openclaw}"
export OPENCLAW_DEFAULT_MODEL="${OPENCLAW_DEFAULT_MODEL:-openrouter/free}"
export SPACE_HOST="${SPACE_HOST:-localhost:7860}"

mkdir -p "${OPENCLAW_HOME}" "${OPENCLAW_STATE_DIR}" /var/log/nginx /var/lib/nginx /run/nginx

# --- 2. 数据恢复 (HF Dataset) ---
hf_state_enabled=0
if [[ -n "${OPENCLAW_HF_STATE_REPO:-}" && -n "${HF_TOKEN:-}" ]]; then
  hf_state_enabled=1
  echo "OpenClaw state sync: ENABLED (repo=${OPENCLAW_HF_STATE_REPO})"
  python3 /app/docker/hf-state-store.py restore boot --home "${OPENCLAW_HOME}" --repo-id "${OPENCLAW_HF_STATE_REPO}" --repo-type dataset --reason boot || true
fi

# --- 3. 彻底重置 (响应用户要求) ---
if [[ -n "${FEISHU_APP_ID:-}" ]]; then
  echo "[nuclear-reset] Feishu credentials detected. Purging old state to prevent conflicts..."
  rm -rf "${OPENCLAW_HOME}/openclaw.json"* 2>/dev/null || true
  rm -rf "${OPENCLAW_HOME}/gateway.db"* 2>/dev/null || true
  rm -rf "${OPENCLAW_STATE_DIR}/gateway" 2>/dev/null || true
  find "${OPENCLAW_STATE_DIR}" -name "config-meta*" -delete 2>/dev/null || true
fi

# --- 4. 配置文件生成 ---
echo "[config] Rendering openclaw.json from template..."
template_path="/app/docker/openclaw.template.json"
FEISHU_ENABLED=$([[ -n "${FEISHU_APP_ID:-}" ]] && echo "true" || echo "false")

node -e '
  const fs = require("fs");
  const template = fs.readFileSync(process.argv[1], "utf8");
  let cfg = JSON.parse(template
    .replace(/\$\{SPACE_HOST\}/g, process.env.SPACE_HOST)
    .replace(/\$\{OPENCLAW_DEFAULT_MODEL\}/g, process.env.OPENCLAW_DEFAULT_MODEL)
    .replace(/\$\{FEISHU_ENABLED\}/g, process.env.FEISHU_ENABLED)
    .replace(/\$\{FEISHU_APP_ID\}/g, process.env.FEISHU_APP_ID || "")
    .replace(/\$\{FEISHU_APP_SECRET\}/g, process.env.FEISHU_APP_SECRET || "")
  );

  // 注入飞书完整配置
  if (process.env.FEISHU_ENABLED === "true") {
    cfg.channels = cfg.channels || {};
    cfg.channels.feishu = {
      enabled: true,
      defaultAccount: "main",
      connectionMode: "websocket",
      accounts: {
        main: {
          appId: process.env.FEISHU_APP_ID,
          appSecret: process.env.FEISHU_APP_SECRET,
          domain: process.env.FEISHU_DOMAIN || "feishu"
        }
      }
    };
  } else if (cfg.channels) {
    delete cfg.channels.feishu;
  }
  
  fs.writeFileSync(process.env.OPENCLAW_CONFIG_PATH, JSON.stringify(cfg, null, 2));
' "${template_path}"

# --- 5. 飞书插件补全 (解决 index.js 缺失) ---
FEISHU_DIR="/app/openclaw/dist/extensions/feishu"
if [ -d "$FEISHU_DIR" ] && [ ! -f "$FEISHU_DIR/index.js" ]; then
  echo "[patch] Feishu runtime missing. Installing @openclaw/feishu..."
  mkdir -p /tmp/feishu_install
  npm install --no-save --prefix /tmp/feishu_install @openclaw/feishu --registry=https://registry.npmmirror.com > /tmp/npm.log 2>&1 || true
  
  SRC="/tmp/feishu_install/node_modules/@openclaw/feishu"
  if [ -f "$SRC/index.js" ] || [ -f "$SRC/index.mjs" ]; then
    cp -r "$SRC"/* "$FEISHU_DIR/"
    [ -f "$FEISHU_DIR/index.mjs" ] && mv "$FEISHU_DIR/index.mjs" "$FEISHU_DIR/index.js"
    # 注入 CJS 桥接
    echo "if (typeof __dirname === 'undefined') { global.__dirname = '$FEISHU_DIR'; } // BRIDGE" > /tmp/b.js
    cat "$FEISHU_DIR/index.js" >> /tmp/b.js
    mv /tmp/b.js "$FEISHU_DIR/index.js"
    chmod -R 755 "$FEISHU_DIR"
    echo "[patch] Feishu plugin restored successfully."
  else
    echo "[patch] ERROR: Could not install feishu. Log:"
    cat /tmp/npm.log
  fi
fi

# --- 6. 启动进程 ---
rm -f /etc/nginx/.htpasswd
htpasswd -bc /etc/nginx/.htpasswd "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASSWORD}"

cd "${OPENCLAW_REPO_DIR}"
echo "Starting Gateway..."
HOME=/root node dist/index.js gateway --port 18789 --bind loopback --allow-unconfigured &
gateway_pid=$!

echo "Starting Admin API & Nginx..."
python3 /app/docker/admin_api.py &
nginx -g "daemon off;" &
nginx_pid=$!

# 状态同步循环
if [[ "${hf_state_enabled}" == "1" ]]; then
  (
    while true; do
      sleep 300
      python3 /app/docker/hf-state-store.py save auto --home "${OPENCLAW_HOME}" --repo-id "${OPENCLAW_HF_STATE_REPO}" --repo-type dataset || true
    done
  ) &
fi

wait "${gateway_pid}"
