#!/usr/bin/env bash
set -euo pipefail

required_vars=(
  BASIC_AUTH_USER
  BASIC_AUTH_PASSWORD
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: ${var_name}" >&2
    exit 1
  fi
done

SPACE_HOST="${SPACE_HOST:-}"
if [[ -z "${SPACE_HOST}" && -n "${SPACE_ID:-}" ]]; then
  SPACE_HOST="${SPACE_ID//\//-}.hf.space"
fi
if [[ -z "${SPACE_HOST}" && -n "${SPACE_AUTHOR_NAME:-}" && -n "${SPACE_REPO_NAME:-}" ]]; then
  SPACE_HOST="${SPACE_AUTHOR_NAME}-${SPACE_REPO_NAME}.hf.space"
fi
if [[ -z "${SPACE_HOST}" ]]; then
  SPACE_HOST="localhost:${SPACE_APP_PORT:-7860}"
fi

export SPACE_HOST
export OPENCLAW_DEFAULT_MODEL="${OPENCLAW_DEFAULT_MODEL:-openrouter/free}"
export OPENCLAW_HOME="${OPENCLAW_HOME:-/root/.openclaw}"
export OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_HOME}/openclaw.json}"
export OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-${OPENCLAW_HOME}/state}"
export OPENCLAW_REPO_DIR="${OPENCLAW_REPO_DIR:-/app/openclaw}"
export OPENCLAW_RESET_STATE_ON_BOOT="${OPENCLAW_RESET_STATE_ON_BOOT:-0}"
export OPENCLAW_REWRITE_CONFIG_ON_BOOT="${OPENCLAW_REWRITE_CONFIG_ON_BOOT:-0}"
export OPENCLAW_CONFIG_JSON="${OPENCLAW_CONFIG_JSON:-}"
export OPENCLAW_CONFIG_JSON_B64="${OPENCLAW_CONFIG_JSON_B64:-}"
export OPENCLAW_HF_STATE_REPO="${OPENCLAW_HF_STATE_REPO:-}"
export OPENCLAW_HF_STATE_REPO_TYPE="${OPENCLAW_HF_STATE_REPO_TYPE:-dataset}"
export OPENCLAW_HF_STATE_ARCHIVE_NAME="${OPENCLAW_HF_STATE_ARCHIVE_NAME:-openclaw-home.tgz}"
export OPENCLAW_HF_STATE_METADATA_NAME="${OPENCLAW_HF_STATE_METADATA_NAME:-openclaw-state.json}"
export OPENCLAW_HF_STATE_SYNC_INTERVAL="${OPENCLAW_HF_STATE_SYNC_INTERVAL:-300}"
export OPENCLAW_HF_STATE_RESTORE_ON_BOOT="${OPENCLAW_HF_STATE_RESTORE_ON_BOOT:-1}"
export OPENCLAW_HF_STATE_PRIVATE="${OPENCLAW_HF_STATE_PRIVATE:-1}"
export OPENCLAW_HF_STATE_HASH_CACHE="${OPENCLAW_HF_STATE_HASH_CACHE:-/tmp/openclaw-hf-state.sha256}"

# 浏览器控制 Token：预设固定值防止 browser 插件自动生成 token 写入配置触发 SIGUSR1 重启循环
export BROWSER_CONTROL_TOKEN="${BROWSER_CONTROL_TOKEN:-openclaw_default_browser_token_$(hostname -s 2>/dev/null || echo static)}"


if [[ -n "${OPENROUTER_API_KEY:-}" && -z "${OPENROUTER_API_KEYS:-}" ]]; then
  export OPENROUTER_API_KEYS="${OPENROUTER_API_KEY}"
fi
export OPENROUTER_API_KEYS="${OPENROUTER_API_KEYS:-}"
export OPENROUTER_MODELS_JSON="${OPENROUTER_MODELS_JSON:-}"

mkdir -p "${OPENCLAW_HOME}" "$(dirname "${OPENCLAW_CONFIG_PATH}")" "${OPENCLAW_STATE_DIR}" /var/log/nginx /var/lib/nginx /run/nginx

hf_state_enabled=0
if [[ -n "${OPENCLAW_HF_STATE_REPO}" ]]; then
  if [[ -z "${HF_TOKEN:-}" ]]; then
    echo "OpenClaw state sync: DISABLED (OPENCLAW_HF_STATE_REPO is set but HF_TOKEN is missing)"
  else
    hf_state_enabled=1
    echo "OpenClaw state sync: ENABLED (repo=${OPENCLAW_HF_STATE_REPO}, type=${OPENCLAW_HF_STATE_REPO_TYPE}, interval=${OPENCLAW_HF_STATE_SYNC_INTERVAL}s)"
  fi
fi

run_hf_state_store() {
  local command="$1"
  local reason="${2:-manual}"
  local args=(
    "${command}"
    --home "${OPENCLAW_HOME}"
    --repo-id "${OPENCLAW_HF_STATE_REPO}"
    --repo-type "${OPENCLAW_HF_STATE_REPO_TYPE}"
    --archive-name "${OPENCLAW_HF_STATE_ARCHIVE_NAME}"
    --metadata-name "${OPENCLAW_HF_STATE_METADATA_NAME}"
    --hash-cache "${OPENCLAW_HF_STATE_HASH_CACHE}"
    --reason "${reason}"
  )
  if [[ "${OPENCLAW_HF_STATE_PRIVATE}" == "1" ]]; then
    args+=(--private)
  fi
  HOME=/root python3 /app/docker/hf-state-store.py "${args[@]}"
}

restore_hf_state() {
  if [[ "${hf_state_enabled}" != "1" ]]; then return 0; fi
  if [[ "${OPENCLAW_HF_STATE_RESTORE_ON_BOOT}" != "1" ]]; then
    echo "OpenClaw state sync: restore on boot disabled"
    return 0
  fi
  if [[ "${OPENCLAW_RESET_STATE_ON_BOOT}" == "1" ]]; then
    echo "OpenClaw state sync: skipping restore because OPENCLAW_RESET_STATE_ON_BOOT=1"
    return 0
  fi
  if run_hf_state_store restore boot; then
    mkdir -p "${OPENCLAW_HOME}" "$(dirname "${OPENCLAW_CONFIG_PATH}")" "${OPENCLAW_STATE_DIR}"
  else
    echo "OpenClaw state sync: restore failed, continuing with local state"
  fi
}

save_hf_state() {
  local reason="${1:-manual}"
  if [[ "${hf_state_enabled}" != "1" ]]; then return 0; fi
  if run_hf_state_store save "${reason}"; then return 0; fi
  echo "OpenClaw state sync: save failed (${reason})"
  return 1
}

start_hf_state_loop() {
  if [[ "${hf_state_enabled}" != "1" ]]; then return 0; fi
  if ! [[ "${OPENCLAW_HF_STATE_SYNC_INTERVAL}" =~ ^[0-9]+$ ]]; then
    echo "OpenClaw state sync: invalid interval '${OPENCLAW_HF_STATE_SYNC_INTERVAL}', disabling periodic sync"
    return 0
  fi
  if [[ "${OPENCLAW_HF_STATE_SYNC_INTERVAL}" -le 0 ]]; then
    echo "OpenClaw state sync: periodic sync disabled"
    return 0
  fi
  (
    last_state_sum=""
    while true; do
      current_state_sum=$(find "${OPENCLAW_HOME}" -maxdepth 1 -name "*.json" -o -name "*.db" | xargs sha256sum 2>/dev/null | sha256sum)
      if [ "${current_state_sum}" != "${last_state_sum}" ]; then
        echo "Config/Database change detected, syncing to HF Dataset..."
        if save_hf_state auto; then
          last_state_sum="${current_state_sum}"
          echo "Sync successful."
        fi
      fi
      sleep 30
    done
  ) &
}

if [[ "${OPENCLAW_RESET_STATE_ON_BOOT}" == "1" ]]; then
  echo "Resetting OpenClaw runtime state for a clean session"
  rm -rf "${OPENCLAW_STATE_DIR}" "${OPENCLAW_HOME}/canvas" "${OPENCLAW_HOME}/agents"
  rm -f "${OPENCLAW_HOME}"/device*.json "${OPENCLAW_HOME}"/devices*.json "${OPENCLAW_HOME}"/pair*.json 2>/dev/null || true
  mkdir -p "${OPENCLAW_STATE_DIR}"
fi

restore_hf_state

FEISHU_APP_ID="${FEISHU_APP_ID:-}"
FEISHU_APP_SECRET="${FEISHU_APP_SECRET:-}"
FEISHU_DOMAIN="${FEISHU_DOMAIN:-feishu}"
FEISHU_DM_POLICY="${FEISHU_DM_POLICY:-}"
FEISHU_ALLOW_FROM="${FEISHU_ALLOW_FROM:-}"
FEISHU_ALLOW_FROM_JSON="[]"

if [[ -n "${FEISHU_ALLOW_FROM}" ]]; then
  FEISHU_ALLOW_FROM_JSON="$(printf '%s' "${FEISHU_ALLOW_FROM}" | node -e "
    const raw = require('node:fs').readFileSync(0, 'utf8').trim();
    const items = raw.split(',').map((s) => s.trim()).filter(Boolean);
    process.stdout.write(JSON.stringify(items));
  ")"
fi

if [[ -z "${FEISHU_DM_POLICY}" ]]; then
  if [[ "${FEISHU_ALLOW_FROM_JSON}" != "[]" ]]; then FEISHU_DM_POLICY="allowlist"; else FEISHU_DM_POLICY="pairing"; fi
fi

if [[ -n "${FEISHU_APP_ID}" && -n "${FEISHU_APP_SECRET}" ]]; then
  FEISHU_ENABLED="true"
else
  FEISHU_ENABLED="false"
fi
export FEISHU_ENABLED FEISHU_APP_ID FEISHU_APP_SECRET FEISHU_DOMAIN FEISHU_DM_POLICY FEISHU_ALLOW_FROM_JSON
echo "Feishu channel env: ${FEISHU_ENABLED^^}"
echo "Feishu dmPolicy env: ${FEISHU_DM_POLICY}"
echo "Feishu allowFrom env count: $(printf '%s' "${FEISHU_ALLOW_FROM_JSON}" | node -e 'const fs=require("node:fs"); const raw=fs.readFileSync(0,"utf8") || "[]"; let v=[]; try { v=JSON.parse(raw); } catch {} process.stdout.write(String(Array.isArray(v) ? v.length : 0));')"

inline_config_provided=0
if [[ -n "${OPENCLAW_CONFIG_JSON_B64}" || -n "${OPENCLAW_CONFIG_JSON}" ]]; then inline_config_provided=1; fi

config_preserved=0
config_source="template"
# 如果飞书凭据已配置，强制重写配置，防止 HF Dataset 恢复的旧配置（无飞书）被保留
if [[ -n "${FEISHU_APP_ID}" && -n "${FEISHU_APP_SECRET}" ]]; then
  echo "Feishu credentials detected — forcing config rewrite to ensure Feishu channel is present."
  config_preserved=0
  config_source="template"
elif [[ -f "${OPENCLAW_CONFIG_PATH}" && "${OPENCLAW_REWRITE_CONFIG_ON_BOOT}" != "1" && "${inline_config_provided}" != "1" ]]; then
  config_preserved=1
  config_source="preserved"
  echo "Preserving existing OpenClaw config at ${OPENCLAW_CONFIG_PATH}"
fi

if [[ "${config_preserved}" != "1" ]]; then
  if [[ -n "${OPENCLAW_CONFIG_JSON_B64}" ]]; then
    config_source="OPENCLAW_CONFIG_JSON_B64"
    config_template="$(printf '%s' "${OPENCLAW_CONFIG_JSON_B64}" | base64 -d)"
  elif [[ -n "${OPENCLAW_CONFIG_JSON}" ]]; then
    config_source="OPENCLAW_CONFIG_JSON"
    config_template="${OPENCLAW_CONFIG_JSON}"
  else
    config_source="template"
    template_path="/app/docker/openclaw.template.json"
    config_template="$(cat "${template_path}")"
    config_template="${config_template//\$\{SPACE_HOST\}/${SPACE_HOST}}"
    config_template="${config_template//\$\{OPENCLAW_DEFAULT_MODEL\}/${OPENCLAW_DEFAULT_MODEL}}"
    config_template="${config_template//\$\{DASHSCOPE_API_KEY\}/${DASHSCOPE_API_KEY:-}}"
    config_template="${config_template//\$\{SILICONFLOW_API_KEY\}/${SILICONFLOW_API_KEY:-}}"
    config_template="${config_template//\$\{FEISHU_ENABLED\}/${FEISHU_ENABLED}}"
    config_template="${config_template//\$\{FEISHU_APP_ID\}/${FEISHU_APP_ID}}"
    config_template="${config_template//\$\{FEISHU_APP_SECRET\}/${FEISHU_APP_SECRET}}"
    config_template="${config_template//\$\{FEISHU_DOMAIN\}/${FEISHU_DOMAIN}}"
    config_template="${config_template//\$\{FEISHU_DM_POLICY\}/${FEISHU_DM_POLICY}}"
    config_template="${config_template//\$\{FEISHU_ALLOW_FROM_JSON\}/${FEISHU_ALLOW_FROM_JSON}}"
    config_template="${config_template//\$\{BROWSER_CONTROL_TOKEN\}/${BROWSER_CONTROL_TOKEN}}"

    config_template="$(node -e '
      const cfg = JSON.parse(process.argv[1]);
      const keysStr = process.env.OPENROUTER_API_KEYS || "";
      const modelsJson = process.env.OPENROUTER_MODELS_JSON || "";
      const keys = keysStr.split(",").map(k => k.trim()).filter(Boolean);
      let customModels = [];
      try { if (modelsJson) customModels = JSON.parse(modelsJson); } catch (e) {}

      if (customModels.length === 0) {
        customModels = [{ id: "openrouter/free", name: "OpenRouter Free (Auto)" }];
      } else {
        customModels = customModels.map(m => { const { thinking, ...rest } = m; return rest; });
      }



      if (keys.length > 0) {
        if (!cfg.models) cfg.models = { mode: "merge", providers: {} };
        if (!cfg.models.providers) cfg.models.providers = {};
        cfg.models.providers["openrouter"] = {
          baseUrl: "http://127.0.0.1:18780/api/v1",
          apiKey: "dummy_proxy_key",
          api: "openai-completions",
          models: customModels
        };
      }
      if (process.env.FEISHU_ENABLED === "false" && cfg.channels) delete cfg.channels.feishu;
      process.stdout.write(JSON.stringify(cfg, null, 2));
    ' "${config_template}")"
  fi
  printf '%s\n' "${config_template}" > "${OPENCLAW_CONFIG_PATH}"
  chmod 600 "${OPENCLAW_CONFIG_PATH}"
  echo "Config written to ${OPENCLAW_CONFIG_PATH}"
fi
echo "Config source: ${config_source}"

# 配置清理与预注入（兼容从 HF Dataset 恢复的旧配置）
# 1. 移除已废弃的 plugins.browser 键
# 2. 预设 gateway.auth.token 防止 browser 插件自动生成 token 触发 SIGUSR1 重启
if [[ -f "${OPENCLAW_CONFIG_PATH}" ]]; then
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const token = process.env.BROWSER_CONTROL_TOKEN || "openclaw_static_browser_token";
    const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
    let dirty = false;

    // 移除已废弃的 plugins.browser 键
    if (cfg.plugins && cfg.plugins.browser) {
      delete cfg.plugins.browser;
      if (Object.keys(cfg.plugins).length === 0) delete cfg.plugins;
      dirty = true;
      console.log("Config sanitized: removed deprecated plugins.browser key");
    }

    // 预设 gateway.auth.token，防止 browser 插件自动生成并写入配置触发重启
    if (!cfg.gateway) cfg.gateway = {};
    const trustedProxies = Array.isArray(cfg.gateway.trustedProxies)
      ? cfg.gateway.trustedProxies.filter((value) => typeof value === "string" && value.length > 0)
      : [];
    for (const proxy of ["127.0.0.1", "::1"]) {
      if (!trustedProxies.includes(proxy)) trustedProxies.push(proxy);
    }
    if (JSON.stringify(cfg.gateway.trustedProxies || []) !== JSON.stringify(trustedProxies)) {
      cfg.gateway.trustedProxies = trustedProxies;
      dirty = true;
      console.log("Config sanitized: trusted local Nginx proxy addresses");
    }

    if (!cfg.gateway.auth) cfg.gateway.auth = {};
    if (!cfg.gateway.auth.token) {
      cfg.gateway.auth.token = token;
      dirty = true;
      console.log("Config sanitized: pre-set gateway.auth.token to prevent browser plugin restart loop");
    }

    if (process.env.FEISHU_ENABLED === "true") {
      if (!cfg.channels || typeof cfg.channels !== "object" || Array.isArray(cfg.channels)) {
        cfg.channels = {};
        dirty = true;
      }
      if (!cfg.channels.feishu || typeof cfg.channels.feishu !== "object" || Array.isArray(cfg.channels.feishu)) {
        cfg.channels.feishu = {};
        dirty = true;
      }
      const feishuEnv = cfg.channels.feishu;
      const accountName = feishuEnv.defaultAccount || "main";
      let allowFrom = [];
      try {
        const parsed = JSON.parse(process.env.FEISHU_ALLOW_FROM_JSON || "[]");
        if (Array.isArray(parsed)) allowFrom = parsed;
      } catch {}
      if (feishuEnv.enabled !== true) {
        feishuEnv.enabled = true;
        dirty = true;
      }
      if (feishuEnv.defaultAccount !== accountName) {
        feishuEnv.defaultAccount = accountName;
        dirty = true;
      }
      if (!feishuEnv.connectionMode) {
        feishuEnv.connectionMode = "websocket";
        dirty = true;
      }
      if (feishuEnv.domain !== (process.env.FEISHU_DOMAIN || "feishu")) {
        feishuEnv.domain = process.env.FEISHU_DOMAIN || "feishu";
        dirty = true;
      }
      if (feishuEnv.dmPolicy !== (process.env.FEISHU_DM_POLICY || "pairing")) {
        feishuEnv.dmPolicy = process.env.FEISHU_DM_POLICY || "pairing";
        dirty = true;
      }
      if (JSON.stringify(feishuEnv.allowFrom || []) !== JSON.stringify(allowFrom)) {
        feishuEnv.allowFrom = allowFrom;
        dirty = true;
      }
      if (!feishuEnv.accounts || typeof feishuEnv.accounts !== "object" || Array.isArray(feishuEnv.accounts)) {
        feishuEnv.accounts = {};
        dirty = true;
      }
      if (!feishuEnv.accounts[accountName] || typeof feishuEnv.accounts[accountName] !== "object") {
        feishuEnv.accounts[accountName] = {};
        dirty = true;
      }
      const accountEnv = feishuEnv.accounts[accountName];
      const envAccount = {
        appId: process.env.FEISHU_APP_ID || "",
        appSecret: process.env.FEISHU_APP_SECRET || "",
        domain: process.env.FEISHU_DOMAIN || "feishu",
      };
      for (const [key, value] of Object.entries(envAccount)) {
        if (accountEnv[key] !== value) {
          accountEnv[key] = value;
          dirty = true;
        }
      }
      for (const key of ["appId", "appSecret"]) {
        if (Object.prototype.hasOwnProperty.call(feishuEnv, key)) {
          delete feishuEnv[key];
          dirty = true;
        }
      }
      if (dirty) console.log("Config sanitized: applied Feishu env override");
    }

    const feishu = cfg.channels && cfg.channels.feishu;
    if (feishu && feishu.enabled !== false) {
      let feishuDirty = false;
      if (!feishu.defaultAccount) {
        feishu.defaultAccount = "main";
        feishuDirty = true;
      }
      if (!feishu.connectionMode) {
        feishu.connectionMode = "websocket";
        feishuDirty = true;
      }
      if (!feishu.accounts || typeof feishu.accounts !== "object" || Array.isArray(feishu.accounts)) {
        feishu.accounts = {};
        feishuDirty = true;
      }
      const accountName = feishu.defaultAccount || "main";
      if (!feishu.accounts[accountName] || typeof feishu.accounts[accountName] !== "object") {
        feishu.accounts[accountName] = {};
        feishuDirty = true;
      }
      const account = feishu.accounts[accountName];
      if (!account.appId && feishu.appId) {
        account.appId = feishu.appId;
        feishuDirty = true;
      }
      if (!account.appSecret && feishu.appSecret) {
        account.appSecret = feishu.appSecret;
        feishuDirty = true;
      }
      if (!account.domain && feishu.domain) {
        account.domain = feishu.domain;
        feishuDirty = true;
      }
      if (Object.prototype.hasOwnProperty.call(feishu, "appId")) {
        delete feishu.appId;
        feishuDirty = true;
      }
      if (Object.prototype.hasOwnProperty.call(feishu, "appSecret")) {
        delete feishu.appSecret;
        feishuDirty = true;
      }
      if (feishuDirty) {
        dirty = true;
        console.log("Config sanitized: normalized Feishu account configuration");
      }
    }

    if (dirty) {
      fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
    }

    const finalFeishu = cfg.channels && cfg.channels.feishu;
    const finalAccountName = finalFeishu && (finalFeishu.defaultAccount || "main");
    const finalAccount = finalFeishu && finalFeishu.accounts && finalAccountName
      ? finalFeishu.accounts[finalAccountName]
      : undefined;
    const appId = finalAccount && typeof finalAccount.appId === "string" ? finalAccount.appId : "";
    const appIdSafe = appId ? `${appId.slice(0, 8)}...${appId.slice(-4)}` : "missing";
    const allowFrom = finalFeishu && Array.isArray(finalFeishu.allowFrom) ? finalFeishu.allowFrom : [];
    console.log(`Feishu config actual: present=${Boolean(finalFeishu)} enabled=${finalFeishu ? finalFeishu.enabled !== false : false} account=${finalAccountName || "none"} appId=${appIdSafe} appSecret=${finalAccount && finalAccount.appSecret ? "set" : "missing"} domain=${finalFeishu ? finalFeishu.domain || "feishu" : "n/a"} dmPolicy=${finalFeishu ? finalFeishu.dmPolicy || "pairing" : "n/a"} allowFromCount=${allowFrom.length}`);
    if (process.env.FEISHU_ENABLED === "true" && (!finalFeishu || finalFeishu.enabled === false || !finalAccount || !finalAccount.appId || !finalAccount.appSecret)) {
      console.error("Config warning: FEISHU_APP_ID/FEISHU_APP_SECRET are set, but runtime channels.feishu is incomplete.");
    }
  ' "${OPENCLAW_CONFIG_PATH}"
fi

rm -f /etc/nginx/.htpasswd
htpasswd -bc /etc/nginx/.htpasswd "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASSWORD}"

# --- 飞书插件入口修复 (动态安装版) ---
FEISHU_DIR="/app/openclaw/dist/extensions/feishu"
FEISHU_NM_DIR="/app/openclaw/node_modules/@openclaw/extension-feishu"

if [ -d "$FEISHU_DIR" ]; then
  echo "[patch] Checking feishu entry points..."
  
  # 1. 尝试从 node_modules 恢复 (某些版本安装在这里)
  if [ ! -f "$FEISHU_DIR/index.js" ] && [ -d "$FEISHU_NM_DIR" ]; then
    echo "[patch] Found feishu in node_modules. Recovering to extensions..."
    cp -r "$FEISHU_NM_DIR"/* "$FEISHU_DIR/" 2>/dev/null || true
  fi

  # 2. 如果依然没有，尝试通过 openclaw 命令安装 (需要联网)
  if [ ! -f "$FEISHU_DIR/index.js" ]; then
    echo "[patch] Feishu index.js STILL missing. Attempting internal install..."
    # 尝试使用 openclaw 命令行工具（如果存在）
    if command -v openclaw &>/dev/null; then
      openclaw extension install feishu --force || true
    fi
  fi

  # 3. 再次对齐 index.js
  if [ ! -f "$FEISHU_DIR/index.js" ]; then
    [ -f "$FEISHU_DIR/index.mjs" ] && mv "$FEISHU_DIR/index.mjs" "$FEISHU_DIR/index.js"
    [ -f "$FEISHU_DIR/index.cjs" ] && mv "$FEISHU_DIR/index.cjs" "$FEISHU_DIR/index.js"
  fi

  # 4. 强制重构 package.json
  node -e '
    const fs = require("fs");
    const p = "/app/openclaw/dist/extensions/feishu/package.json";
    let pkg = { name: "@openclaw/extension-feishu", version: "1.0.0", main: "index.js" };
    try { if (fs.existsSync(p)) { 
      const old = JSON.parse(fs.readFileSync(p, "utf8"));
      pkg = { ...old, ...pkg }; 
    }} catch(e) {}
    pkg.main = "index.js";
    delete pkg.type;
    fs.writeFileSync(p, JSON.stringify(pkg, null, 2));
  '

  # 5. 桥接与权限
  if [ -f "$FEISHU_DIR/index.js" ]; then
    if ! grep -q "OPENCLAW_CJS_BRIDGE" "$FEISHU_DIR/index.js"; then
      echo "// OPENCLAW_CJS_BRIDGE" > /tmp/feishu-cjs.js
      echo "if (typeof __dirname === 'undefined') { global.__dirname = '$FEISHU_DIR'; }" >> /tmp/feishu-cjs.js
      cat "$FEISHU_DIR/index.js" >> /tmp/feishu-cjs.js
      mv /tmp/feishu-cjs.js "$FEISHU_DIR/index.js"
    fi
    chmod -R 755 "$FEISHU_DIR"
    echo "[patch] Feishu plugin patched."
  else
    echo "[patch] CRITICAL: Feishu runtime file NOT FOUND even after recovery attempts."
  fi
fi

# --- 预设设备身份防止浏览器插件报错 ---
# 修复日志中的 "device identity required" 错误
DEVICE_ID_FILE="${OPENCLAW_HOME}/device.json"
if [ ! -f "${DEVICE_ID_FILE}" ]; then
  echo '{"id":"default-hf-space-device","name":"HuggingFace Space","trusted":true}' > "${DEVICE_ID_FILE}"
  echo "Pre-generated device identity to bypass auth errors."
fi

# --- 阻止 Gateway config-overwrite（增强版）---
# Gateway 启动时会比较 config meta 与 "last-good" 备份。
# 若 meta 不匹配，Gateway 会用旧备份覆写新配置。
# 彻底清除所有可能触发 overwrite 的文件，包括 Gateway SQLite DB 中的 config 快照表。
rm -f "${OPENCLAW_CONFIG_PATH}.bak" 2>/dev/null || true
rm -f "${OPENCLAW_HOME}/openclaw.json.bak" 2>/dev/null || true
# 清除 state 目录中的 config 元数据（含子目录，深度扩展到 8 层）
find "${OPENCLAW_STATE_DIR}" -maxdepth 8 \( \
  -name "config-meta*" -o \
  -name "*.config-hash" -o \
  -name "last-good-config*" -o \
  -name "config.bak" -o \
  -name "*.json.bak" -o \
  -name "config-snapshot*" \
\) -delete 2>/dev/null || true
# 清除 home 目录顶层的隐藏 config 状态文件
find "${OPENCLAW_HOME}" -maxdepth 1 \( -name ".config-*" -o -name ".last-good*" \) -delete 2>/dev/null || true
# 如果存在 gateway 的内部 config store (SQLite/JSON)，清除其中的 config 快照
if [ -d "${OPENCLAW_STATE_DIR}/gateway" ]; then
  rm -f "${OPENCLAW_STATE_DIR}/gateway/config-snapshot"* 2>/dev/null || true
  rm -f "${OPENCLAW_STATE_DIR}/gateway/last-good"* 2>/dev/null || true
fi
# 飞书凭据存在时：删除 Gateway SQLite 数据库中可能存储的旧 config 快照
# （gateway.db 是已知的 Gateway 状态存储，删除后 Gateway 将使用磁盘上的 JSON 配置）
if [[ -n "${FEISHU_APP_ID}" && -n "${FEISHU_APP_SECRET}" ]]; then
  for db_path in \
    "${OPENCLAW_STATE_DIR}/gateway.db" \
    "${OPENCLAW_STATE_DIR}/gateway/gateway.db" \
    "${OPENCLAW_HOME}/gateway.db" \
    "${OPENCLAW_STATE_DIR}/config.db" \
    "${OPENCLAW_STATE_DIR}/openclaw.db"; do
    if [ -f "${db_path}" ]; then
      echo "[config-clean] Removing Gateway DB to prevent config overwrite: ${db_path}"
      rm -f "${db_path}" 2>/dev/null || true
    fi
  done
  # 如果安装了 sqlite3，则只清除 config 相关表而不是整个 DB
  for db_path in \
    "${OPENCLAW_STATE_DIR}/gateway.db" \
    "${OPENCLAW_STATE_DIR}/gateway/gateway.db" \
    "${OPENCLAW_HOME}/gateway.db"; do
    if [ -f "${db_path}" ] && command -v sqlite3 &>/dev/null; then
      echo "[config-clean] Wiping config tables in ${db_path}"
      sqlite3 "${db_path}" "DELETE FROM config_snapshots;" 2>/dev/null || true
      sqlite3 "${db_path}" "DELETE FROM last_good_config;" 2>/dev/null || true
      sqlite3 "${db_path}" "DROP TABLE IF EXISTS config_snapshots;" 2>/dev/null || true
      sqlite3 "${db_path}" "DROP TABLE IF EXISTS last_good_config;" 2>/dev/null || true
    fi
  done
fi
echo "Config meta/backup cleaned to prevent gateway overwrite"

# 启动前验证飞书配置完整性
node -e '
  const cfg = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const f = cfg.channels && cfg.channels.feishu;
  const acct = f && f.accounts && f.accounts[f.defaultAccount || "main"];
  console.log("Pre-gateway feishu verify: enabled=" + (f ? f.enabled : "MISSING") +
    " mode=" + (f ? f.connectionMode : "n/a") +
    " appId=" + (acct && acct.appId ? acct.appId.slice(0,8) + "..." : "MISSING") +
    " dmPolicy=" + (f ? f.dmPolicy : "n/a"));
' "${OPENCLAW_CONFIG_PATH}" 2>/dev/null || echo "Pre-gateway feishu verify: FAILED to read config"

cd "${OPENCLAW_REPO_DIR}"
echo "Starting OpenClaw gateway on 127.0.0.1:18789"
HOME=/root node dist/index.js gateway --port 18789 --bind loopback --allow-unconfigured --verbose &
gateway_pid=$!

cleanup() {
  trap - EXIT INT TERM
  kill "${gateway_pid}" "${nginx_pid}" 2>/dev/null || true
  save_hf_state shutdown || true
  exit 0
}
trap cleanup EXIT INT TERM

echo "Waiting for OpenClaw gateway to become ready..."
for i in $(seq 1 60); do
  if bash -c 'exec 3<>/dev/tcp/127.0.0.1/18789' 2>/dev/null; then break; fi
  sleep 1
done

# --- 飞书配置热修复（增强版）---
# Gateway 的 config overwrite 会用内部 last-good 覆盖模板配置（changedPaths=76）。
# 策略：
# 1. 等 Gateway 就绪（overwrite 已完成，通常在启动后 5s 内）
# 2. 检查飞书配置是否被抹除
# 3. 如果被抹除，清除 Gateway DB（防止再次 overwrite）+ 重新注入 + 重启
# 4. 第二次重启后再次验证，若仍失败记录警告但不阻塞启动
if [[ "${FEISHU_ENABLED}" == "true" ]]; then
  sleep 5  # 等待 Gateway 完全稳定（config overwrite 通常在 starting... 后 2-4s 内完成）

  _feishu_check() {
    node -e '
      const cfg = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const f = cfg.channels && cfg.channels.feishu;
      const acct = f && f.accounts && f.accounts[f.defaultAccount || "main"];
      const ok = f && f.enabled === true && acct && acct.appId && acct.appSecret;
      console.log(ok ? "OK" : "MISSING");
    ' "${OPENCLAW_CONFIG_PATH}" 2>/dev/null || echo "ERROR"
  }

  _feishu_inject() {
    node -e '
      const fs = require("fs"), p = process.argv[1];
      const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
      if (!cfg.channels) cfg.channels = {};
      cfg.channels.feishu = {
        enabled: true,
        defaultAccount: "main",
        connectionMode: "websocket",
        domain: process.env.FEISHU_DOMAIN || "feishu",
        dmPolicy: process.env.FEISHU_DM_POLICY || "pairing",
        allowFrom: JSON.parse(process.env.FEISHU_ALLOW_FROM_JSON || "[]"),
        accounts: {
          main: {
            appId: process.env.FEISHU_APP_ID,
            appSecret: process.env.FEISHU_APP_SECRET,
            domain: process.env.FEISHU_DOMAIN || "feishu"
          }
        }
      };
      fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
      console.log("[feishu-hotfix] Feishu config injected.");
    ' "${OPENCLAW_CONFIG_PATH}"
  }

  _purge_gateway_db() {
    echo "[feishu-hotfix] Purging Gateway DB to prevent future overwrite..."
    for db_path in \
      "${OPENCLAW_STATE_DIR}/gateway.db" \
      "${OPENCLAW_STATE_DIR}/gateway/gateway.db" \
      "${OPENCLAW_HOME}/gateway.db" \
      "${OPENCLAW_STATE_DIR}/config.db" \
      "${OPENCLAW_STATE_DIR}/openclaw.db"; do
      [ -f "${db_path}" ] && rm -f "${db_path}" 2>/dev/null && echo "[feishu-hotfix] Removed: ${db_path}" || true
    done
    find "${OPENCLAW_STATE_DIR}" -maxdepth 8 -name "*.db" -delete 2>/dev/null || true
  }

  feishu_ok=$(_feishu_check)

  if [[ "${feishu_ok}" != "OK" ]]; then
    echo "[feishu-hotfix] Config overwrite removed Feishu config (status=${feishu_ok}). Starting hotfix..."

    # 先清除 Gateway DB，再注入，防止 Gateway 重启后再次从 DB 恢复旧配置
    kill "${gateway_pid}" 2>/dev/null || true
    sleep 2
    _purge_gateway_db
    _feishu_inject

    # 重启 Gateway 以加载新注入的飞书配置
    echo "[feishu-hotfix] Restarting Gateway to load Feishu channel..."
    cd "${OPENCLAW_REPO_DIR}"
    HOME=/root node dist/index.js gateway --port 18789 --bind loopback --allow-unconfigured --verbose &
    gateway_pid=$!

    # 等待重启后的 Gateway 就绪
    for i in $(seq 1 90); do
      if bash -c 'exec 3<>/dev/tcp/127.0.0.1/18789' 2>/dev/null; then break; fi
      sleep 1
    done

    # 再次等待 overwrite 完成后验证
    sleep 5
    feishu_ok2=$(_feishu_check)
    if [[ "${feishu_ok2}" != "OK" ]]; then
      echo "[feishu-hotfix] Second overwrite detected! Performing final emergency re-injection..."
      _purge_gateway_db
      _feishu_inject
      # 最后一次重启
      kill "${gateway_pid}" 2>/dev/null || true
      sleep 2
      cd "${OPENCLAW_REPO_DIR}"
      HOME=/root node dist/index.js gateway --port 18789 --bind loopback --allow-unconfigured --verbose &
      gateway_pid=$!
      for i in $(seq 1 90); do
        if bash -c 'exec 3<>/dev/tcp/127.0.0.1/18789' 2>/dev/null; then break; fi
        sleep 1
      done
      echo "[feishu-hotfix] Emergency re-injection complete."
    else
      echo "[feishu-hotfix] Feishu config verified OK after hotfix restart."
    fi
  else
    echo "[feishu-hotfix] Feishu config intact after gateway startup. No hotfix needed."
  fi
fi

echo "Starting Nginx..."
nginx -g 'daemon off;' &
nginx_pid=$!

[[ "${hf_state_enabled}" == "1" ]] && (python3 /app/docker/backup_api.py &)
python3 /app/docker/admin_api.py &
[[ -n "${OPENROUTER_API_KEYS}" ]] && (python3 /app/docker/openrouter_proxy.py &)

start_hf_state_loop

# 增强的守护逻辑：只要端口还在，即使 PID 变了（重启中）也继续运行
while true; do
  # 检查 Nginx 必须存活
  if ! kill -0 "${nginx_pid}" 2>/dev/null; then
    echo "Nginx exited. Terminating..."
    cleanup
  fi
  # 检查 Gateway 端口，允许短暂消失（重启中，最长等待 30s）
  if ! bash -c 'exec 3<>/dev/tcp/127.0.0.1/18789' 2>/dev/null; then
    echo "Gateway port 18789 not responding, waiting up to 30s for recovery..."
    recovered=0
    for retry in $(seq 1 6); do
      sleep 5
      if bash -c 'exec 3<>/dev/tcp/127.0.0.1/18789' 2>/dev/null; then
        echo "Gateway recovered after $((retry * 5))s"
        recovered=1
        break
      fi
    done
    if [[ "${recovered}" != "1" ]]; then
      echo "Gateway failed to recover after 30s. Terminating..."
      cleanup
    fi
  fi
  sleep 10
done
