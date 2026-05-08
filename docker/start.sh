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

# --- 2. 状态恢复 ---
hf_state_enabled=0
if [[ -n "${OPENCLAW_HF_STATE_REPO:-}" && -n "${HF_TOKEN:-}" ]]; then
  hf_state_enabled=1
  python3 /app/docker/hf-state-store.py restore --reason boot --home "${OPENCLAW_HOME}" --repo-id "${OPENCLAW_HF_STATE_REPO}" --repo-type dataset || true
fi

# --- 3. 飞书变量解析 ---
export FEISHU_APP_ID="${FEISHU_APP_ID:-}"
export FEISHU_APP_SECRET="${FEISHU_APP_SECRET:-}"
export FEISHU_DOMAIN="${FEISHU_DOMAIN:-feishu}"
export FEISHU_DM_POLICY="${FEISHU_DM_POLICY:-pairing}"
export FEISHU_ENABLED=$([[ -n "${FEISHU_APP_ID}" ]] && echo "true" || echo "false")

export FEISHU_ALLOW_FROM_JSON="[]"
if [[ -n "${FEISHU_ALLOW_FROM:-}" ]]; then
  export FEISHU_ALLOW_FROM_JSON=$(node -e "console.log(JSON.stringify('${FEISHU_ALLOW_FROM}'.split(',').map(s => s.trim()).filter(Boolean)))")
fi

if [[ "${FEISHU_ENABLED}" == "true" ]]; then
  echo "[nuclear-reset] Feishu credentials detected. Purging old state..."
  # 物理清除可能导致冲突的所有配置和缓存
  rm -rf "${OPENCLAW_HOME}/openclaw.json"* 2>/dev/null || true
  rm -rf "${OPENCLAW_HOME}/gateway.db"* 2>/dev/null || true
  rm -rf "${OPENCLAW_STATE_DIR}/gateway" 2>/dev/null || true
  find "${OPENCLAW_STATE_DIR}" -name "config-meta*" -delete 2>/dev/null || true
fi

# --- 4. 配置文件生成 (集成 OpenRouter 代理) ---
echo "[config] Rendering openclaw.json..."
template_path="/app/docker/openclaw.template.json"
export BROWSER_CONTROL_TOKEN="${BROWSER_CONTROL_TOKEN:-openclaw_static_token}"
export OPENROUTER_API_KEYS="${OPENROUTER_API_KEY:-${OPENROUTER_API_KEYS:-}}"

node -e '
  const fs = require("fs");
  const template = fs.readFileSync(process.argv[1], "utf8");
  const getEnv = (key, def = "") => process.env[key] || def;

  let cfgRaw = template
    .replace(/\$\{SPACE_HOST\}/g, getEnv("SPACE_HOST"))
    .replace(/\$\{OPENCLAW_DEFAULT_MODEL\}/g, getEnv("OPENCLAW_DEFAULT_MODEL"))
    .replace(/\$\{FEISHU_ENABLED\}/g, getEnv("FEISHU_ENABLED"))
    .replace(/\$\{FEISHU_APP_ID\}/g, getEnv("FEISHU_APP_ID"))
    .replace(/\$\{FEISHU_APP_SECRET\}/g, getEnv("FEISHU_APP_SECRET"))
    .replace(/\$\{FEISHU_DOMAIN\}/g, getEnv("FEISHU_DOMAIN"))
    .replace(/\$\{FEISHU_DM_POLICY\}/g, getEnv("FEISHU_DM_POLICY"))
    .replace(/\$\{FEISHU_ALLOW_FROM_JSON\}/g, getEnv("FEISHU_ALLOW_FROM_JSON", "[]"))
    .replace(/\$\{BROWSER_CONTROL_TOKEN\}/g, getEnv("BROWSER_CONTROL_TOKEN"))
    .replace(/\$\{DASHSCOPE_API_KEY\}/g, getEnv("DASHSCOPE_API_KEY"))
    .replace(/\$\{SILICONFLOW_API_KEY\}/g, getEnv("SILICONFLOW_API_KEY"));

  let cfg = JSON.parse(cfgRaw);
  
  // 注入 OpenRouter 代理配置
  if (process.env.OPENROUTER_API_KEYS) {
    if (!cfg.models) cfg.models = { mode: "merge", providers: {} };
    cfg.models.providers["openrouter"] = {
      baseUrl: "http://127.0.0.1:18780/api/v1",
      apiKey: "dummy_proxy_key",
      api: "openai-completions",
      models: [{ id: "openrouter/free", name: "OpenRouter Free (Auto)" }]
    };
  }

  // 注入飞书完整配置
  if (process.env.FEISHU_ENABLED === "true") {
    cfg.channels = cfg.channels || {};
    cfg.channels.feishu = {
      enabled: true,
      defaultAccount: "main",
      connectionMode: "websocket",
      domain: getEnv("FEISHU_DOMAIN"),
      dmPolicy: getEnv("FEISHU_DM_POLICY"),
      allowFrom: JSON.parse(getEnv("FEISHU_ALLOW_FROM_JSON", "[]")),
      accounts: {
        main: { appId: process.env.FEISHU_APP_ID, appSecret: process.env.FEISHU_APP_SECRET, domain: getEnv("FEISHU_DOMAIN") }
      }
    };
  }
  fs.writeFileSync(process.env.OPENCLAW_CONFIG_PATH, JSON.stringify(cfg, null, 2));
' "${template_path}"

# --- 5. 飞书插件物理修复 & 外科手术 ---
FEISHU_DIR="/app/openclaw/dist/extensions/feishu"
if [ -d "$FEISHU_DIR" ]; then
  if [ ! -f "$FEISHU_DIR/index.js" ] && [ ! -f "$FEISHU_DIR/dist/index.js" ]; then
    echo "[patch] Downloading Tarball..."
    mkdir -p /tmp/feishu_tar
    TAR_URL=$(curl -s https://registry.npmmirror.com/@openclaw/feishu/latest | node -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(d.dist.tarball);")
    curl -L "${TAR_URL}" -o /tmp/feishu.tgz && tar -xzf /tmp/feishu.tgz -C /tmp/feishu_tar
    cp -r /tmp/feishu_tar/package/* "$FEISHU_DIR/" 2>/dev/null || true
  fi

  REAL_ENTRY=$(find "$FEISHU_DIR" -name "index.js" | head -n 1)
  if [ -f "$REAL_ENTRY" ]; then
    echo "[patch] Compatibility surgery: pruning missing SDK exports..."
    # 彻底删除导入语句中的冲突函数，防止 Node.js 静态检查失败
    sed -i "s/formatChannelProgressDraftLineForEntry,//g" "$REAL_ENTRY"
    sed -i "s/,formatChannelProgressDraftLineForEntry//g" "$REAL_ENTRY"
    # 在代码中 Mock 该函数
    sed -i "1i var formatChannelProgressDraftLineForEntry = (v) => v;" "$REAL_ENTRY"
    
    if ! grep -q "OPENCLAW_CJS_BRIDGE" "$REAL_ENTRY"; then
      echo "if (typeof __dirname === 'undefined') { global.__dirname = '$(dirname "$REAL_ENTRY")'; } // OPENCLAW_CJS_BRIDGE" > /tmp/b.js
      cat "$REAL_ENTRY" >> /tmp/b.js && mv /tmp/b.js "$REAL_ENTRY"
    fi
    chmod -R 755 "$FEISHU_DIR"
    echo "[patch] Feishu plugin surgically repaired."
  fi
fi

# --- 6. 启动进程 ---
rm -f /etc/nginx/.htpasswd
htpasswd -bc /etc/nginx/.htpasswd "${BASIC_AUTH_USER:-admin}" "${BASIC_AUTH_PASSWORD:-admin}"

python3 /app/docker/openrouter_proxy.py &
proxy_pid=$!

cd "${OPENCLAW_REPO_DIR}"
echo "Starting Gateway..."
HOME=/root node dist/index.js gateway --port 18789 --bind loopback --allow-unconfigured &
gateway_pid=$!

python3 /app/docker/admin_api.py &
nginx -g "daemon off;" &
nginx_pid=$!

cleanup() { kill "${gateway_pid}" "${nginx_pid}" "${proxy_pid}" 2>/dev/null || true; exit 0; }
trap cleanup EXIT INT TERM

wait "${gateway_pid}"
