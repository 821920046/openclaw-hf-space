#!/usr/bin/env bash
set -euo pipefail

# --- 1. 基础环境配置 ---
export OPENCLAW_HOME="${OPENCLAW_HOME:-/root/.openclaw}"
export OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_HOME}/openclaw.json}"
export OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-${OPENCLAW_HOME}/state}"
export OPENCLAW_REPO_DIR="${OPENCLAW_REPO_DIR:-/app/openclaw}"
export OPENCLAW_DEFAULT_MODEL="${OPENCLAW_DEFAULT_MODEL:-google/lyria-3-pro-preview}"
export SPACE_HOST="${SPACE_HOST:-localhost:7860}"

mkdir -p "${OPENCLAW_HOME}" "${OPENCLAW_STATE_DIR}" /var/log/nginx /var/lib/nginx /run/nginx

# --- 2. 状态恢复 ---
hf_state_enabled=0
if [[ -n "${OPENCLAW_HF_STATE_REPO:-}" && -n "${HF_TOKEN:-}" ]]; then
  hf_state_enabled=1
  python3 /app/docker/hf-state-store.py restore --reason boot --home "${OPENCLAW_HOME}" --repo-id "${OPENCLAW_HF_STATE_REPO}" --repo-type dataset || true
fi

# --- 2b. 自动清理已弃用的残留 (保留用户技能) ---
# 仅清理已知会导致启动崩溃的特定临时文件
echo "[patch] Cleaning temporary build artifacts..."
rm -rf "/tmp/openclaw-build-"* 2>/dev/null || true

# --- 3. 变量解析 ---
export FEISHU_APP_ID="${FEISHU_APP_ID:-}"
export FEISHU_APP_SECRET="${FEISHU_APP_SECRET:-}"
export FEISHU_ENABLED=$([[ -n "${FEISHU_APP_ID}" ]] && echo "true" || echo "false")
export FEISHU_ALLOW_FROM_JSON="[]"
if [[ -n "${FEISHU_ALLOW_FROM:-}" ]]; then
  export FEISHU_ALLOW_FROM_JSON=$(node -e "console.log(JSON.stringify('${FEISHU_ALLOW_FROM}'.split(',').map(s => s.trim()).filter(Boolean)))")
fi

# --- 3b. 飞书 dmPolicy 自动推断 ---
# 如果用户显式设置了 FEISHU_DM_POLICY，尊重用户选择。
# 否则根据 FEISHU_ALLOW_FROM 自动决定：
#   - 有 allowFrom → allowlist（最可靠，不需要配对状态）
#   - 无 allowFrom → open（免费层不依赖持久化配对）
if [[ "${FEISHU_ENABLED}" == "true" ]]; then
  if [[ -z "${FEISHU_DM_POLICY:-}" ]]; then
    if [[ -n "${FEISHU_ALLOW_FROM:-}" ]]; then
      export FEISHU_DM_POLICY="allowlist"
      echo "[feishu] Auto-detected dmPolicy=allowlist (FEISHU_ALLOW_FROM is set)"
    else
      export FEISHU_DM_POLICY="open"
      echo "[feishu] WARNING: No FEISHU_ALLOW_FROM set. Defaulting dmPolicy=open."
      echo "[feishu]         Any Feishu user can DM the bot. For production, set FEISHU_ALLOW_FROM=<your open_id>."
    fi
  else
    echo "[feishu] Using explicit dmPolicy=${FEISHU_DM_POLICY}"
  fi
fi

# --- 3c. 部署飞书文档创建技能 (必须在 FEISHU_ENABLED 定义之后) ---
if [[ "${FEISHU_ENABLED}" == "true" ]]; then
  # 部署到 /usr/local/bin，agent 可直接用 feishu-create-doc "标题" 调用
  cat > /usr/local/bin/feishu-create-doc << 'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail
TITLE="${1:-}"
if [[ -z "${TITLE}" ]]; then
  echo "[feishu-doc] ERROR: 缺少文档标题" >&2
  exit 1
fi
APP_ID="${FEISHU_APP_ID:-}"
APP_SECRET="${FEISHU_APP_SECRET:-}"
if [[ -z "${APP_ID}" || -z "${APP_SECRET}" ]]; then
  echo "[feishu-doc] ERROR: 缺少 FEISHU_APP_ID 或 FEISHU_APP_SECRET" >&2
  exit 1
fi
echo "[feishu-doc] Getting tenant_access_token..." >&2
TOKEN_RESP=$(curl -sS --max-time 10 \
  -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "$(python3 -c "import json,os; print(json.dumps({'app_id':os.environ['APP_ID'],'app_secret':os.environ['APP_SECRET']}))")" 2>&1)
TOKEN=$(echo "${TOKEN_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tenant_access_token',''))" 2>&1) || true
if [[ -z "${TOKEN}" ]]; then
  echo "[feishu-doc] ERROR: Failed to get token. Response: ${TOKEN_RESP}" >&2
  exit 1
fi
echo "[feishu-doc] Creating document: ${TITLE}" >&2
CREATE_RESP=$(curl -sS --max-time 15 \
  -X POST "https://open.feishu.cn/open-apis/docx/v1/documents" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "$(python3 -c "import json; print(json.dumps({'title':'${TITLE}'}))")" 2>&1)
PARSE_RESULT=$(echo "${CREATE_RESP}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
code = d.get('code', -1)
if code == 0:
    doc = d['data']['document']
    print('OK')
    print(doc.get('document_id',''))
    print(doc.get('url',''))
    print(doc.get('title',''))
else:
    print('ERROR')
    print(f'code={code} msg={d.get(\"msg\",\"\")}')
") 2>&1
STATUS=$(echo "${PARSE_RESULT}" | head -1)
if [[ "${STATUS}" != "OK" ]]; then
  echo "[feishu-doc] ERROR: Create failed. ${PARSE_RESULT}" >&2
  exit 1
fi
DOC_ID=$(echo "${PARSE_RESULT}" | sed -n '2p')
DOC_URL=$(echo "${PARSE_RESULT}" | sed -n '3p')
DOC_TITLE=$(echo "${PARSE_RESULT}" | sed -n '4p')
cat <<OUTPUT_EOF
飞书文档创建成功！
- 标题: ${DOC_TITLE}
- 文档ID: ${DOC_ID}
- 链接: ${DOC_URL}
OUTPUT_EOF
echo "[feishu-doc] SUCCESS doc_id=${DOC_ID} url=${DOC_URL}" >&2
SCRIPT_EOF

  chmod +x /usr/local/bin/feishu-create-doc

  # 将 SKILL.md 写入 OpenClaw workspace（覆盖两个可能的路径）
  for WS_BASE in "${OPENCLAW_HOME}/workspace" "${OPENCLAW_HOME}/.openclaw/workspace"; do
    SKILL_DIR="${WS_BASE}/skills/feishu-doc"
    mkdir -p "${SKILL_DIR}"
    cat > "${SKILL_DIR}/SKILL.md" << 'SKILLMD_EOF'
# Feishu Document Creator

To create a new Feishu document, run:
```
feishu-create-doc "Document Title"
```

This creates an empty Feishu doc (title only) and returns the URL like https://bytedance.feishu.cn/docx/xxxxx.

If you need to write content into the doc after creation:
1. Use the document_id from the output
2. Get a tenant_access_token
3. POST to https://open.feishu.cn/open-apis/docx/v1/documents/{id}/blocks/{id}/children
SKILLMD_EOF
  done

  echo "[feishu-doc] feishu-create-doc deployed to /usr/local/bin/ and workspace"
fi

# --- 3e. 技能路径标准化与自动初始化 ---
# 统一使用 ${OPENCLAW_HOME}/workspace/skills 作为唯一技能目录
export OPENCLAW_SKILLS_DIR="${OPENCLAW_HOME}/workspace/skills"
mkdir -p "${OPENCLAW_SKILLS_DIR}"

# 如果旧路径 .openclaw/workspace/skills 下有内容，迁移到标准路径
OLD_SKILLS="${OPENCLAW_HOME}/.openclaw/workspace/skills"
if [ -d "$OLD_SKILLS" ] && [ "$(ls -A "$OLD_SKILLS" 2>/dev/null)" ]; then
  echo "[skills] Migrating skills from legacy path to ${OPENCLAW_SKILLS_DIR}..."
  cp -rn "$OLD_SKILLS/"* "${OPENCLAW_SKILLS_DIR}/" 2>/dev/null || true
fi

echo "[skills] Skills directory: ${OPENCLAW_SKILLS_DIR}"
echo "[skills] Scanning for skills to auto-initialize..."
export PATH="${PATH}:${OPENCLAW_SKILLS_DIR}"

# 特别针对 freeride 的初始化
FREERIDE_PATH="${OPENCLAW_SKILLS_DIR}/freeride"
if [ -d "$FREERIDE_PATH" ]; then
  echo "[skills] freeride found at ${FREERIDE_PATH}, auto-initializing..."
  rm -f /usr/local/bin/freeride 2>/dev/null || true
  (cd "$FREERIDE_PATH" && python3 -m pip install --break-system-packages -e . || echo "[skills] freeride install failed")
  ln -sf "${FREERIDE_PATH}/freeride/cli.py" /usr/local/bin/freeride || true
  chmod +x "${FREERIDE_PATH}/freeride/cli.py" 2>/dev/null || true
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    echo "[skills] OPENROUTER_API_KEY detected, auto-configuring models via freeride..."
    (cd "$FREERIDE_PATH" && freeride auto \
      --primary "openrouter/owl-alpha" \
      --fallback "google/lyra-3-pro-preview,google/lyra-3-clip-preview,google/gemma-4-26b-a4bit:free,google/gemma-4-31bit:free" \
      || echo "[skills] freeride auto-config skipped")
  fi
  export PATH="${PATH}:${FREERIDE_PATH}"
fi

# --- 3d. 智能配置保护 ---
# 不再暴力删除 openclaw.json，改为保存用户自定义段后合并。
# 保留 gateway.db 和配对文件，否则 allowlist/pairing 状态丢失。
if [[ "${OPENCLAW_REWRITE_CONFIG_ON_BOOT:-0}" == "1" ]]; then
  echo "[config] OPENCLAW_REWRITE_CONFIG_ON_BOOT=1 — 强制从模板重新生成全部配置"
  rm -f "${OPENCLAW_CONFIG_PATH}" "${OPENCLAW_CONFIG_PATH}.bak" 2>/dev/null || true
else
  # 保存现有配置，稍后与新模板合并
  if [[ -f "${OPENCLAW_CONFIG_PATH}" ]]; then
    echo "[config] 保存现有配置用于合并 (plugins/skills/memory 将被保留)..."
    cp "${OPENCLAW_CONFIG_PATH}" "${OPENCLAW_CONFIG_PATH}.pre-merge"
  else
    echo "[config] 无现有配置，将从模板全新生成"
  fi
  rm -f "${OPENCLAW_CONFIG_PATH}" 2>/dev/null || true
fi

# 全量重置（清除 gateway.db 等）仅在显式请求时执行
if [[ "${OPENCLAW_RESET_STATE_ON_BOOT:-0}" == "1" ]]; then
  echo "[reset] OPENCLAW_RESET_STATE_ON_BOOT=1 — purging ALL runtime state including gateway.db..."
  rm -rf "${OPENCLAW_HOME}/gateway.db"* 2>/dev/null || true
  rm -rf "${OPENCLAW_STATE_DIR}/gateway" 2>/dev/null || true
  find "${OPENCLAW_STATE_DIR}" -name "config-meta*" -delete 2>/dev/null || true
else
  echo "[reset] gateway.db and pairing state preserved."
fi

# --- 4. SDK 物理修补 (核心修复) ---
# OpenClaw 某些版本的 plugin-sdk/channel-streaming 缺少 formatChannelProgressDraftLineForEntry 导出，
# 飞书插件依赖此导出。
# 策略：通过 Node.js 模块解析找到实际文件路径，再精准修补。
echo "[patch] Resolving and patching openclaw/plugin-sdk/channel-streaming..."
node -e '
  const fs = require("fs");
  const path = require("path");
  const { execSync } = require("child_process");

  const EXPORT_NAME = "formatChannelProgressDraftLineForEntry";
  const STUB = "export const " + EXPORT_NAME + " = (v) => v;";
  const REPO = process.env.OPENCLAW_REPO_DIR;
  const SUBPATH = "plugin-sdk/channel-streaming";

  // 快速路径：先检查最可能的文件位置，已包含补丁则直接跳过
  const FAST_PATH = path.join(REPO, "dist", SUBPATH + ".js");
  if (fs.existsSync(FAST_PATH) && fs.readFileSync(FAST_PATH, "utf8").includes(EXPORT_NAME)) {
    console.log("[patch] Already patched (fast check). Skipping.");
    process.exit(0);
  }
  const SUFFIXES = [".js", ".mjs", ".cjs", "/index.js", "/index.mjs", "/index.cjs"];

  // === 策略 1: 解析 package.json exports 字段 ===
  function resolveFromExports() {
    const pkgPath = path.join(REPO, "package.json");
    if (!fs.existsSync(pkgPath)) return null;
    const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
    const exp = pkg.exports;
    if (!exp) return null;

    // 尝试多种 subpath 格式
    const keys = [
      "./" + SUBPATH,
      "./" + SUBPATH + ".js",
      "./" + SUBPATH + ".mjs",
      "./" + SUBPATH + "/index.js",
    ];
    for (const key of keys) {
      if (exp[key]) {
        const target = typeof exp[key] === "string" ? exp[key] : (exp[key].import || exp[key].default || exp[key].require);
        if (target) {
          const full = path.resolve(REPO, target);
          if (fs.existsSync(full)) return full;
          // 尝试加后缀
          for (const s of [".js", ".mjs", "/index.js"]) {
            if (fs.existsSync(full + s)) return full + s;
          }
        }
      }
    }
    return null;
  }

  // === 策略 2: 直接检查文件路径 ===
  function resolveFromPaths() {
    const base = path.join(REPO, SUBPATH);
    for (const s of SUFFIXES) {
      const p = base + s;
      if (fs.existsSync(p)) return p;
    }
    // 也检查 dist 目录
    const distBase = path.join(REPO, "dist", SUBPATH);
    for (const s of SUFFIXES) {
      const p = distBase + s;
      if (fs.existsSync(p)) return p;
    }
    return null;
  }

  // === 策略 3: 搜索 node_modules ===
  function resolveFromNodeModules() {
    const nm = path.join(REPO, "node_modules", "openclaw");
    if (!fs.existsSync(nm)) return null;
    // 检查 node_modules/openclaw 的 package.json exports
    const pkgPath = path.join(nm, "package.json");
    if (fs.existsSync(pkgPath)) {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
      const exp = pkg.exports;
      if (exp) {
        for (const key of ["./" + SUBPATH, "./" + SUBPATH + ".js", "./" + SUBPATH + "/index.js"]) {
          if (exp[key]) {
            const target = typeof exp[key] === "string" ? exp[key] : (exp[key].import || exp[key].default || exp[key].require);
            if (target) {
              const full = path.resolve(nm, target);
              if (fs.existsSync(full)) return full;
              for (const s of [".js", ".mjs", "/index.js"]) {
                if (fs.existsSync(full + s)) return full + s;
              }
            }
          }
        }
      }
    }
    // 直接检查路径
    const base = path.join(nm, SUBPATH);
    for (const s of SUFFIXES) {
      if (fs.existsSync(base + s)) return base + s;
    }
    return null;
  }

  // === 策略 4: 全局搜索 (最后手段) ===
  function resolveBySearch() {
    try {
      const result = execSync(
        "find " + REPO + " -path '*/plugin-sdk/channel-streaming*' -name '*.js' -o -path '*/plugin-sdk/channel-streaming*' -name '*.mjs' 2>/dev/null | head -5",
        { encoding: "utf8", timeout: 15000 }
      ).trim();
      if (result) return result.split("\n")[0];
    } catch (e) {}
    return null;
  }

  // 依次尝试
  const resolved = resolveFromExports() || resolveFromPaths() || resolveFromNodeModules() || resolveBySearch();

  if (!resolved) {
    console.log("[patch] ERROR: Could not resolve openclaw/plugin-sdk/channel-streaming");
    console.log("[patch] Tried: package.json exports, direct paths, node_modules, file search");
    // 列出 dist 目录结构帮助诊断
    try {
      const distPluginSdk = path.join(REPO, "dist", "plugin-sdk");
      if (fs.existsSync(distPluginSdk)) {
        console.log("[patch] Contents of dist/plugin-sdk/:");
        execSync("ls -la " + distPluginSdk, { stdio: "inherit" });
      } else {
        console.log("[patch] dist/plugin-sdk/ does not exist. Listing dist/ top-level:");
        execSync("ls " + path.join(REPO, "dist") + " | head -20", { stdio: "inherit" });
      }
    } catch (e) {}
    process.exit(0);
  }

  console.log("[patch] Resolved to: " + resolved);
  let src = fs.readFileSync(resolved, "utf8");

  if (src.includes(EXPORT_NAME)) {
    console.log("[patch] Already contains " + EXPORT_NAME + ". Skipping.");
    process.exit(0);
  }

  // === 修补文件 ===
  let newSrc;
  const lines = src.split("\n");

  // 找最后一个 export 语句
  let lastExportIdx = -1;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (/^\s*export\s/.test(lines[i])) {
      lastExportIdx = i;
      break;
    }
  }

  if (lastExportIdx >= 0) {
    lines.splice(lastExportIdx + 1, 0, STUB);
    newSrc = lines.join("\n");
    console.log("[patch] ESM: inserted after line " + (lastExportIdx + 1));
  } else if (src.includes("module.exports") || src.includes("exports.")) {
    newSrc = src + "\nexports." + EXPORT_NAME + " = (v) => v;\n";
    console.log("[patch] CJS: appended exports");
  } else if (src.match(/export\s*\{/)) {
    // export { a, b } 格式 — 在 } 前插入
    const match = src.match(/(export\s*\{[^}]*)(}\s*;?\s*)/);
    if (match) {
      newSrc = src.slice(0, match.index + match[1].length) + ",\n  " + EXPORT_NAME + "\n" + src.slice(match.index + match[1].length);
      console.log("[patch] ESM re-export: inserted into export block");
    }
  }

  if (!newSrc) {
    // 最终后备：追加
    newSrc = src + "\n// AUTO-PATCHED\n" + STUB + "\n";
    console.log("[patch] FALLBACK: appended to end of file");
  }

  fs.writeFileSync(resolved, newSrc);
  console.log("[patch] Successfully patched: " + resolved);
'

# --- 5. 配置文件生成 ---
echo "[config] Rendering openclaw.json from template..."
template_path="/app/docker/openclaw.template.json"
export BROWSER_CONTROL_TOKEN="${BROWSER_CONTROL_TOKEN:-openclaw_static_token}"
export OPENROUTER_API_KEYS="${OPENROUTER_API_KEY:-${OPENROUTER_API_KEYS:-}}"

node -e '
  const fs = require("fs");
  const path = require("path");
  const template = fs.readFileSync(process.argv[1], "utf8");
  const getEnv = (key, def = "") => process.env[key] || def;
  const configPath = process.env.OPENCLAW_CONFIG_PATH;
  const preMergePath = configPath + ".pre-merge";

  // --- 渲染模板 ---
  let cfgRaw = template
    .replace(/\$\{SPACE_HOST\}/g, getEnv("SPACE_HOST"))
    .replace(/\$\{OPENCLAW_DEFAULT_MODEL\}/g, getEnv("OPENCLAW_DEFAULT_MODEL"))
    .replace(/\$\{FEISHU_ENABLED\}/g, getEnv("FEISHU_ENABLED"))
    .replace(/\$\{FEISHU_APP_ID\}/g, getEnv("FEISHU_APP_ID"))
    .replace(/\$\{FEISHU_APP_SECRET\}/g, getEnv("FEISHU_APP_SECRET"))
    .replace(/\$\{FEISHU_DOMAIN\}/g, getEnv("FEISHU_DOMAIN", "feishu"))
    .replace(/\$\{FEISHU_DM_POLICY\}/g, getEnv("FEISHU_DM_POLICY", "pairing"))
    .replace(/\$\{FEISHU_ALLOW_FROM_JSON\}/g, getEnv("FEISHU_ALLOW_FROM_JSON", "[]"))
    .replace(/\$\{BROWSER_CONTROL_TOKEN\}/g, getEnv("BROWSER_CONTROL_TOKEN"))
    .replace(/\$\{DASHSCOPE_API_KEY\}/g, getEnv("DASHSCOPE_API_KEY"))
    .replace(/\$\{SILICONFLOW_API_KEY\}/g, getEnv("SILICONFLOW_API_KEY"))
    .replace(/\$\{EMAIL_ENABLED\}/g, getEnv("EMAIL_ENABLED", "false"))
    .replace(/\$\{EMAIL_ACCOUNT\}/g, getEnv("EMAIL_ACCOUNT"))
    .replace(/\$\{EMAIL_TOKEN\}/g, getEnv("EMAIL_TOKEN"))
    .replace(/\$\{EMAIL_MODE\}/g, getEnv("EMAIL_MODE", "imap"));
  let cfg = JSON.parse(cfgRaw);

  // --- 基础设施段（始终从环境变量/模板生成）---
  if (process.env.OPENROUTER_API_KEYS) {
    if (!cfg.models) cfg.models = { mode: "merge", providers: {} };
    cfg.models.providers["openrouter"] = {
      baseUrl: "http://127.0.0.1:18780/api/v1",
      apiKey: "dummy_proxy_key",
      api: "openai-completions",
      models: [
        { id: "google/lyria-3-pro-preview", name: "Google Lyria 3 Pro (Free, 1M ctx)", params: { thinking: "off" } },
        { id: "deepseek/deepseek-v4-flash:free", name: "DeepSeek V4 Flash (Free, 1M ctx)", params: { thinking: "off" } },
        { id: "google/lyria-3-clip-preview", name: "Google Lyria 3 Clip (Free, 1M ctx)", params: { thinking: "off" } },
        { id: "google/gemma-4-31b-it:free", name: "Google Gemma 4 31B (Free, 262K ctx)", params: { thinking: "off" } },
        { id: "google/gemma-4-26b-a4b-it:free", name: "Google Gemma 4 26B A4B (Free, 262K ctx)", params: { thinking: "off" } },
        { id: "arcee-ai/trinity-large-thinking:free", name: "Arcee Trinity Thinking (Free, 262K ctx)", params: { thinking: "off" } },
        { id: "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free", name: "NVIDIA Nemotron 3 Nano Reasoning (Free, 256K ctx)", params: { thinking: "off" } },
        { id: "openrouter/owl-alpha", name: "Owl Alpha (Free, 1M ctx)", params: { thinking: "off" } }
      ]
    };
  }
  if (process.env.FEISHU_ENABLED === "true") {
    cfg.channels = cfg.channels || {};
    cfg.channels.feishu = {
      enabled: true,
      defaultAccount: "main",
      connectionMode: "websocket",
      domain: getEnv("FEISHU_DOMAIN", "feishu"),
      dmPolicy: getEnv("FEISHU_DM_POLICY", "pairing"),
      allowFrom: JSON.parse(getEnv("FEISHU_ALLOW_FROM_JSON", "[]")),
      accounts: {
        main: { appId: process.env.FEISHU_APP_ID, appSecret: process.env.FEISHU_APP_SECRET, domain: getEnv("FEISHU_DOMAIN", "feishu") }
      }
    };
  }
  if (process.env.EMAIL_ENABLED === "true") {
    cfg.channels = cfg.channels || {};
    cfg.channels.email = {
      enabled: true,
      allowFrom: ["*"],
      replyMode: "complete",
      replyTo: "sender",
      accounts: {
        "default": {
          email: process.env.EMAIL_ACCOUNT,
          password: process.env.EMAIL_TOKEN,
          transport: getEnv("EMAIL_MODE", "imap")
        }
      }
    };
  } else {
    if (cfg.channels && cfg.channels.email) {
      delete cfg.channels.email;
    }
  }

  // --- 智能合并：从旧配置恢复用户自定义段 ---
  if (fs.existsSync(preMergePath)) {
    try {
      const old = JSON.parse(fs.readFileSync(preMergePath, "utf8"));
      // 保留的用户自定义段列表
      const PRESERVE_KEYS = ["plugins", "skills", "memory", "extensions"];
      let merged = 0;
      for (const key of PRESERVE_KEYS) {
        if (old[key] && Object.keys(old[key]).length > 0) {
          // 深合并：新配置中该段不存在则直接采用旧的，存在则合并
          if (!cfg[key] || Object.keys(cfg[key]).length === 0) {
            cfg[key] = old[key];
          } else {
            cfg[key] = { ...old[key], ...cfg[key] };
          }
          merged++;
          console.log("[config] Preserved user section: " + key);
        }
      }
      // agents 段特殊处理：保留 custom agents，但 defaults 由模板控制
      if (old.agents) {
        cfg.agents = cfg.agents || {};
        for (const ak of Object.keys(old.agents)) {
          if (ak !== "defaults") {
            cfg.agents[ak] = old.agents[ak];
            merged++;
            console.log("[config] Preserved agent config: " + ak);
          }
        }
      }
      console.log("[config] Smart merge complete: " + merged + " user sections preserved.");
    } catch (e) {
      console.log("[config] WARNING: Failed to merge old config: " + e.message);
    }
    // 清理临时文件
    try { fs.unlinkSync(preMergePath); } catch(e) {}
  }

  // --- 强制关闭 thinking (飞书卡片空内容 #272) ---
  // root cause: 飞书 onPartialReply 用 stripReasoningTagsFromText mode=strict
  // 把 thinking 块连同内容全剥掉，卡片永远不更新内容。
  // Gateway 解析优先级: agents.defaults.models[x].params.thinking
  //   → agents.defaults.thinkingDefault → 自动推断 → fallback "medium"
  // 所以正确的 key 是 agents.defaults.thinkingDefault，不是 model.thinking。
  if (!cfg.agents) cfg.agents = {};
  if (!cfg.agents.defaults) cfg.agents.defaults = {};
  cfg.agents.defaults.thinkingDefault = "off";
  // 同时递归清理所有 per-model thinking 配置，防止覆盖全局设置
  (function forceThinkingOff(obj) {
    if (!obj || typeof obj !== "object") return;
    if (Array.isArray(obj)) { obj.forEach(forceThinkingOff); return; }
    for (const key of Object.keys(obj)) {
      if (key === "thinking" || key === "thinkingDefault") { obj[key] = "off"; continue; }
      forceThinkingOff(obj[key]);
    }
  })(cfg);
  console.log("[config] thinking forced to 'off' (thinkingDefault + recursive clean).");

  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2));
  console.log("[config] Written to " + configPath);
' "${template_path}"

# --- 6. 飞书插件补全 ---
FEISHU_DIR="/app/openclaw/dist/extensions/feishu"
if [ -d "$FEISHU_DIR" ] && [[ ! -f "$FEISHU_DIR/index.js" && ! -f "$FEISHU_DIR/dist/index.js" ]]; then
  # 读取 Docker 构建时写入的版本 ref，匹配对应的飞书插件版本
  BUILD_REF=$(cat /app/openclaw/.openclaw-build-ref 2>/dev/null || echo "")
  NPM_VERSION="${BUILD_REF#v}"                           # v2026.5.3-1 → 2026.5.3-1
  NPM_VERSION_BASE="${NPM_VERSION%-*}"                   # 2026.5.3-1 → 2026.5.3

  # 先检查本地缓存（持久化在 OPENCLAW_HOME 中，通过 hf-state 跨重启保留）
  FEISHU_CACHE_DIR="${OPENCLAW_HOME}/cache/feishu-plugin"
  FEISHU_CACHE_VER=""
  if [ -d "$FEISHU_CACHE_DIR" ]; then
    FEISHU_CACHE_VER=$(cat "${FEISHU_CACHE_DIR}/.version" 2>/dev/null || echo "")
  fi

  DOWNLOAD_NEEDED=1
  for TRY_VER in "${NPM_VERSION_BASE}" "${NPM_VERSION}"; do
    if [[ -z "${TRY_VER}" ]]; then continue; fi
    # 缓存命中：版本匹配且入口文件存在
    if [[ "${FEISHU_CACHE_VER}" == "${TRY_VER}" ]] && [ -f "${FEISHU_CACHE_DIR}/index.js" ]; then
      echo "[patch] Feishu plugin cache hit (version ${TRY_VER}), copying from cache..."
      cp -r "${FEISHU_CACHE_DIR}/"* "$FEISHU_DIR/" 2>/dev/null || true
      DOWNLOAD_NEEDED=0
      break
    fi
  done

  if [ "${DOWNLOAD_NEEDED}" == "1" ]; then
    echo "[patch] Feishu index.js not found, attempting download from npmmirror..."

    mkdir -p /tmp/feishu_tar
    TAR_URL=""

    # 优先下载版本匹配的插件
    for TRY_VER in "${NPM_VERSION}" "${NPM_VERSION_BASE}"; do
      if [[ -z "${TRY_VER}" ]]; then continue; fi
      echo "[patch] Trying version-matched feishu: ${TRY_VER}..."
      TAR_URL=$(curl -s --max-time 15 "https://registry.npmmirror.com/@openclaw/feishu/${TRY_VER}" | node -e "try{const d=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log(d.dist.tarball)}catch(e){}" || true)
      if [[ -n "${TAR_URL}" ]]; then
        echo "[patch] Version match succeeded: ${TRY_VER}"
        break
      fi
    done

    if [[ -z "${TAR_URL}" ]]; then
      echo "[patch] Version match failed, falling back to latest..."
      TAR_URL=$(curl -s --max-time 15 https://registry.npmmirror.com/@openclaw/feishu/latest | node -e "try{const d=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log(d.dist.tarball)}catch(e){}" || true)
    fi

    if [[ -n "${TAR_URL}" ]]; then
      echo "[patch] Downloading: ${TAR_URL}"
      curl -L --max-time 30 "${TAR_URL}" -o /tmp/feishu.tgz && tar -xzf /tmp/feishu.tgz -C /tmp/feishu_tar
      cp -r /tmp/feishu_tar/package/* "$FEISHU_DIR/" 2>/dev/null || true
      echo "[patch] Feishu plugin downloaded successfully."

      # 写入本地缓存，下次重启直接用
      MATCHED_VER="${TAR_URL##*feishu-}"  # 从 URL 提取版本号 feishu-2026.5.3.tgz → 2026.5.3.tgz
      MATCHED_VER="${MATCHED_VER%.tgz}"
      mkdir -p "$FEISHU_CACHE_DIR"
      cp -r "$FEISHU_DIR/"* "$FEISHU_CACHE_DIR/" 2>/dev/null || true
      echo "${MATCHED_VER}" > "${FEISHU_CACHE_DIR}/.version"
      echo "[patch] Cached feishu plugin (version ${MATCHED_VER}) to ${FEISHU_CACHE_DIR}"
    else
      echo "[patch] WARNING: Could not fetch feishu tarball URL. Plugin may not be available."
    fi
  fi
fi

REAL_ENTRY=$(find "$FEISHU_DIR" -name "index.js" 2>/dev/null | head -n 1 || true)
if [ -f "$REAL_ENTRY" ]; then
  if ! grep -q "OPENCLAW_CJS_BRIDGE" "$REAL_ENTRY"; then
    echo "if (typeof __dirname === 'undefined') { global.__dirname = '$(dirname "$REAL_ENTRY")'; } // BRIDGE" > /tmp/b.js
    cat "$REAL_ENTRY" >> /tmp/b.js && mv /tmp/b.js "$REAL_ENTRY"
  fi
  chmod -R 755 "$FEISHU_DIR"
fi

# --- 修补飞书插件: stripReasoningTagsFromText mode=strict → preserve ---
# root cause: strict 模式把 thinking 块连同内容全部剥光，导致飞书卡片永远收不到内容更新。
# 改为 preserve 模式后，thinking 内容作为引用块正常显示在卡片中。
echo "[patch] Patching Feishu plugin to preserve reasoning content in streaming cards..."
for f in $(find "$FEISHU_DIR" -name "*.js" -type f 2>/dev/null); do
  if grep -q 'mode: "strict"' "$f" 2>/dev/null; then
    sed -i 's/mode: "strict"/mode: "preserve"/g' "$f"
    echo "[patch] Fixed stripReasoningTagsFromText mode in $(basename "$f")"
  fi
done

# 强制修复飞书插件 require('root-alias.cjs/...') 子路径问题
# 旧版飞书插件不仅 require('root-alias.cjs')，还访问子模块如 root-alias.cjs/channel-message。
# 若插件引用子模块 → root-alias.cjs 必须是目录（含 package.json + 软链接）
# 若插件不引用子模块（版本匹配的常见情况）→ 简单重导出文件即可
PLUGIN_SDK_DIR="/app/openclaw/dist/plugin-sdk"
if [ -d "$PLUGIN_SDK_DIR" ]; then
  # 清理旧格式：文件、软链接、目录
  rm -rf "$PLUGIN_SDK_DIR/root-alias.cjs" 2>/dev/null || true
  rm -rf "$PLUGIN_SDK_DIR/root-alias.js" 2>/dev/null || true

  # 先扫描飞书插件，判断是否需要目录结构
  NEED_CJS_DIR=0
  NEED_JS_DIR=0
  if [ -d "$FEISHU_DIR" ]; then
    if grep -rq 'root-alias\.cjs/[a-zA-Z0-9_-]*' "$FEISHU_DIR" 2>/dev/null; then
      NEED_CJS_DIR=1
    fi
    if grep -rq 'root-alias\.js/[a-zA-Z0-9_-]*' "$FEISHU_DIR" 2>/dev/null; then
      NEED_JS_DIR=1
    fi
  fi

  # ---- root-alias.cjs ----
  if [ "${NEED_CJS_DIR}" == "1" ]; then
    echo "[patch] Plugin references root-alias.cjs/sub-modules — creating directory with symlinks..."
    mkdir -p "$PLUGIN_SDK_DIR/root-alias.cjs"
    cat > "$PLUGIN_SDK_DIR/root-alias.cjs/package.json" << 'PKGJSON'
{"type": "commonjs", "main": "./index.js"}
PKGJSON
    if [ -f "$PLUGIN_SDK_DIR/index.cjs" ]; then
      printf 'module.exports = require("../index.cjs");\n' > "$PLUGIN_SDK_DIR/root-alias.cjs/index.js"
    elif [ -f "$PLUGIN_SDK_DIR/index.js" ]; then
      printf 'module.exports = require("../index.js");\n' > "$PLUGIN_SDK_DIR/root-alias.cjs/index.js"
    fi
    for item in "$PLUGIN_SDK_DIR"/*; do
      base=$(basename "$item")
      case "$base" in root-alias*) continue ;; esac
      ln -sf "../${base}" "$PLUGIN_SDK_DIR/root-alias.cjs/${base}" 2>/dev/null || true
    done
    find "$PLUGIN_SDK_DIR/root-alias.cjs/" -maxdepth 1 -name "*.cjs" | while read -r f; do
      base=$(basename "$f" .cjs)
      [ ! -e "$PLUGIN_SDK_DIR/root-alias.cjs/${base}.js" ] && ln -sf "${base}.cjs" "$PLUGIN_SDK_DIR/root-alias.cjs/${base}.js" 2>/dev/null || true
    done
    echo "[patch] Created root-alias.cjs/ directory with symlinks"
  else
    # 简单重导出文件
    if [ -f "$PLUGIN_SDK_DIR/index.cjs" ]; then
      printf 'module.exports = require("./index.cjs");\n' > "$PLUGIN_SDK_DIR/root-alias.cjs"
    elif [ -f "$PLUGIN_SDK_DIR/index.js" ]; then
      printf 'module.exports = require("./index.js");\n' > "$PLUGIN_SDK_DIR/root-alias.cjs"
    fi
    echo "[patch] Created root-alias.cjs (simple re-export file)"
  fi

  # ---- root-alias.js ----
  if [ "${NEED_JS_DIR}" == "1" ]; then
    echo "[patch] Plugin references root-alias.js/sub-modules — creating directory with symlinks..."
    mkdir -p "$PLUGIN_SDK_DIR/root-alias.js"
    cat > "$PLUGIN_SDK_DIR/root-alias.js/package.json" << 'PKGJSON2'
{"type": "module", "main": "./index.js"}
PKGJSON2
    if [ -f "$PLUGIN_SDK_DIR/index.mjs" ]; then
      printf 'export * from "../index.mjs";\n' > "$PLUGIN_SDK_DIR/root-alias.js/index.js"
    elif [ -f "$PLUGIN_SDK_DIR/index.js" ]; then
      printf 'export * from "../index.js";\n' > "$PLUGIN_SDK_DIR/root-alias.js/index.js"
    fi
    for item in "$PLUGIN_SDK_DIR"/*; do
      base=$(basename "$item")
      case "$base" in root-alias*) continue ;; esac
      ln -sf "../${base}" "$PLUGIN_SDK_DIR/root-alias.js/${base}" 2>/dev/null || true
    done
    echo "[patch] Created root-alias.js/ directory with symlinks"
  else
    if [ -f "$PLUGIN_SDK_DIR/index.mjs" ]; then
      printf 'export * from "./index.mjs";\n' > "$PLUGIN_SDK_DIR/root-alias.js"
    elif [ -f "$PLUGIN_SDK_DIR/index.js" ]; then
      printf 'export * from "./index.js";\n' > "$PLUGIN_SDK_DIR/root-alias.js"
    fi
    echo "[patch] Created root-alias.js (simple re-export file)"
  fi

  # 安全网：若插件引用了 root-alias.cjs/ 子模块但父目录中没有，补齐 stub
  if [ "${NEED_CJS_DIR}" == "1" ]; then
    echo "[patch] Scanning feishu plugin for missing root-alias.cjs/ sub-modules..."
    SCAN_REFS=$(grep -roh 'root-alias\.cjs/[a-zA-Z0-9_-]*' "$FEISHU_DIR" 2>/dev/null || true)
    if [ -n "${SCAN_REFS}" ]; then
      echo "${SCAN_REFS}" | sort -u | while read -r ref; do
        sub=$(echo "$ref" | sed 's|root-alias\.cjs/||')
        js_target="$PLUGIN_SDK_DIR/root-alias.cjs/${sub}.js"
        cjs_target="$PLUGIN_SDK_DIR/root-alias.cjs/${sub}.cjs"
        [ -e "$js_target" ] || [ -e "$cjs_target" ] && continue
        if [ -f "$PLUGIN_SDK_DIR/${sub}.js" ]; then
          ln -sf "../${sub}.js" "$js_target" 2>/dev/null || true
          echo "[patch]   Linked ${sub}.js"
        elif [ -f "$PLUGIN_SDK_DIR/${sub}.cjs" ]; then
          printf 'module.exports = require("../%s.cjs");\n' "$sub" > "$js_target"
          echo "[patch]   Created stub ${sub}.js -> ../${sub}.cjs"
        else
          cat > "$js_target" << 'PROXYEOF'
module.exports = new Proxy({}, { get(t,p) { return (...a) => {}; } });
PROXYEOF
          echo "[patch]   Created proxy stub: ${sub}.js"
        fi
      done
    fi
    echo "[patch] root-alias.cjs/ sub-module scan complete"
  fi
fi

# --- 7. 启动进程（带 Watchdog 监控）---
rm -f /etc/nginx/.htpasswd
htpasswd -bc /etc/nginx/.htpasswd "${BASIC_AUTH_USER:-admin}" "${BASIC_AUTH_PASSWORD:-admin}"

# 日志目录（供 admin_api 读取）
mkdir -p /tmp/openclaw
# 保留最近 5 个日志文件，删除旧的
OLD_LOGS=$(ls -1t /tmp/openclaw/openclaw-*.log 2>/dev/null || true)
if [ -n "$OLD_LOGS" ]; then
  echo "$OLD_LOGS" | tail -n +6 | while read -r f; do rm -f "$f" 2>/dev/null || true; done
fi
LOG_FILE="/tmp/openclaw/openclaw-$(date +%Y%m%d-%H%M%S).log"

# 启动所有服务并记录 PID
python3 /app/docker/openrouter_proxy.py &
proxy_pid=$!
echo "[startup] openrouter_proxy started (PID: ${proxy_pid})"

cd "${OPENCLAW_REPO_DIR}"
echo "[startup] Starting Gateway..."
# 使用进程替换 >(tee) 而非管道 | tee：进程替换不影响 $! 的 PID 捕获，
# 确保 Watchdog 拿到的是 node 进程 PID 而非 tee 的 PID。
HOME=/root node dist/index.js gateway --port 18789 --bind loopback --allow-unconfigured > >(tee -a "${LOG_FILE}") 2>&1 &
gateway_pid=$!
echo "[startup] Gateway started (PID: ${gateway_pid})"

python3 /app/docker/admin_api.py &
admin_pid=$!
echo "[startup] admin_api started (PID: ${admin_pid})"

python3 /app/docker/backup_api.py &
backup_pid=$!
echo "[startup] backup_api started (PID: ${backup_pid})"

nginx -g "daemon off;" &
nginx_pid=$!
echo "[startup] nginx started (PID: ${nginx_pid})"

# 优雅关闭：清理所有子进程
cleanup() {
  echo "[shutdown] Cleaning up all processes..."
  # 关闭前执行状态同步
  if [[ "${hf_state_enabled}" == "1" ]]; then
    echo "[shutdown] Performing final state sync..."
    python3 /app/docker/hf-state-store.py save \
      --reason shutdown \
      --home "${OPENCLAW_HOME}" \
      --repo-id "${OPENCLAW_HF_STATE_REPO}" \
      --repo-type "${OPENCLAW_HF_STATE_REPO_TYPE:-dataset}" || true
  fi
  kill "${gateway_pid}" "${nginx_pid}" "${proxy_pid}" "${admin_pid}" "${backup_pid}" 2>/dev/null || true
  exit 0
}
trap cleanup EXIT INT TERM

# --- Watchdog：监控子进程健康，自动重启崩溃的服务 ---
echo "[watchdog] Process monitoring started (interval: 30s)"
while true; do
  sleep 30

  # 检查 Gateway（核心进程，崩溃则退出容器让 HF 重启）
  if ! kill -0 "${gateway_pid}" 2>/dev/null; then
    echo "[watchdog] CRITICAL: Gateway (PID: ${gateway_pid}) died! Exiting for container restart."
    cleanup
  fi

  # 检查 OpenRouter Proxy（可恢复）
  if ! kill -0 "${proxy_pid}" 2>/dev/null; then
    echo "[watchdog] openrouter_proxy died, restarting..."
    python3 /app/docker/openrouter_proxy.py &
    proxy_pid=$!
    echo "[watchdog] openrouter_proxy restarted (PID: ${proxy_pid})"
  fi

  # 检查 Admin API（可恢复）
  if ! kill -0 "${admin_pid}" 2>/dev/null; then
    echo "[watchdog] admin_api died, restarting..."
    python3 /app/docker/admin_api.py &
    admin_pid=$!
  fi

  # 检查 Backup API（可恢复）
  if ! kill -0 "${backup_pid}" 2>/dev/null; then
    echo "[watchdog] backup_api died, restarting..."
    python3 /app/docker/backup_api.py &
    backup_pid=$!
  fi

  # 检查 Nginx（关键，但通常不会崩溃）
  if ! kill -0 "${nginx_pid}" 2>/dev/null; then
    echo "[watchdog] nginx died, restarting..."
    nginx -g "daemon off;" &
    nginx_pid=$!
  fi
done
