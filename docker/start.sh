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

# --- 1b. 部署飞书文档创建技能 ---
if [[ "${FEISHU_ENABLED}" == "true" ]]; then
  FEISHU_SKILL_DST="${OPENCLAW_HOME}/.openclaw/workspace/skills/feishu-doc"
  mkdir -p "${FEISHU_SKILL_DST}"

  # 写入 create-doc.sh（飞书文档创建脚本）
  cat > "${FEISHU_SKILL_DST}/create-doc.sh" << 'SCRIPT_EOF'
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

  # 写入 SKILL.md（Agent 调用指南）
  cat > "${FEISHU_SKILL_DST}/SKILL.md" << 'SKILLMD_EOF'
# 飞书文档创建技能

使用飞书开放平台 API 创建飞书文档。

## 前置条件
- 已在飞书开发者后台为应用开通以下权限：
  - `docx:document`（管理新版文档）
  - `drive:drive`（访问云空间）
- 容器环境已设置 `FEISHU_APP_ID` 和 `FEISHU_APP_SECRET`

## 创建文档

执行以下命令创建飞书文档：

```bash
bash ~/.openclaw/.openclaw/workspace/skills/feishu-doc/create-doc.sh "文档标题"
```

脚本成功后会输出文档的 URL（如 `https://bytedance.feishu.cn/docx/xxxxx`）。

## 带内容创建文档（两阶段）

飞书 API 不支持一步创建带内容的文档：

**Step 1: 创建空文档**
```bash
bash ~/.openclaw/.openclaw/workspace/skills/feishu-doc/create-doc.sh "文档标题"
```
记录输的 Doc ID。

**Step 2: 写入内容**
先获取 tenant_access_token：
```bash
TOKEN=$(curl -s -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "{\"app_id\":\"$FEISHU_APP_ID\",\"app_secret\":\"$FEISHU_APP_SECRET\"}" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['tenant_access_token'])")
```

再用 Python 调用 block API 写入内容：
```python
import json, requests
doc_id = "从上一步获取的 document_id"

# 读取本地 Markdown 并构建 blocks
with open("content.md", "r", encoding="utf-8") as f:
    content = f.read()

blocks = []
for para in content.split("\n\n"):
    para = para.strip()
    if not para: continue
    blocks.append({
        "block_type": 2,
        "text": {"elements": [{"text_run": {"content": para}}], "style": {}}
    })

url = f"https://open.feishu.cn/open-apis/docx/v1/documents/{doc_id}/blocks/{doc_id}/children"
headers = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json; charset=utf-8"}
resp = requests.post(url, headers=headers, json={"children": blocks, "index": -1})
print("OK" if resp.json().get("code") == 0 else f"Failed: {resp.text}")
```

## API 端点参考

| 用途 | 端点 |
|------|------|
| 获取 token | POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal |
| 创建文档 | POST https://open.feishu.cn/open-apis/docx/v1/documents |
| 写入内容 | POST https://open.feishu.cn/open-apis/docx/v1/documents/{id}/blocks/{id}/children |
SKILLMD_EOF

  chmod +x "${FEISHU_SKILL_DST}/create-doc.sh"
  echo "[feishu-doc] Skill deployed to workspace: ${FEISHU_SKILL_DST}"
fi

# --- 2b. 自动清理"坏味道"技能和插件 ---
# 强制清理持久化状态中损坏或不需要的技能/插件目录
echo "[patch] Deep cleaning broken skills and unused plugins from persistent state..."
rm -rf "${OPENCLAW_HOME}/.openclaw/workspace/skills/github-api" 2>/dev/null || true
rm -rf "${OPENCLAW_HOME}/state/npm/node_modules/@clawemail" 2>/dev/null || true
rm -rf "${OPENCLAW_HOME}/state/extensions/email" 2>/dev/null || true
find "${OPENCLAW_HOME}" -name "mail-cli" -type d -exec rm -rf {} + 2>/dev/null || true

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

# --- 3d. 邮件渠道变量解析 ---
export EMAIL_ACCOUNT="${EMAIL_ACCOUNT:-}"
export EMAIL_TOKEN="${EMAIL_TOKEN:-}"
export EMAIL_MODE="${EMAIL_MODE:-imap}"
export EMAIL_ENABLED=$([[ -n "${EMAIL_ACCOUNT}" ]] && echo "true" || echo "false")

if [[ "${EMAIL_ENABLED}" == "true" ]]; then
  echo "[email] Email channel: ENABLED"
  echo "[email] Account: ${EMAIL_ACCOUNT}"
  echo "[email] Connection mode: ${EMAIL_MODE}"
else
  echo "[email] Email channel: DISABLED (set EMAIL_ACCOUNT to enable)"
fi

# --- 3c. 清理旧配置，保护配对状态 ---
# 从 HF 状态仓库恢复的 openclaw.json 可能包含旧版配置，与新模板冲突。
# 必须在配置生成（第 5 步）之前清除，让模板重新生成。
# 但保留 gateway.db 和配对文件，否则 allowlist/pairing 状态丢失。
echo "[reset] Clearing stale openclaw.json (will be regenerated from template)..."
rm -f "${OPENCLAW_HOME}/openclaw.json" "${OPENCLAW_HOME}/openclaw.json.bak" 2>/dev/null || true

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
    .replace(/\$\{FEISHU_DOMAIN\}/g, getEnv("FEISHU_DOMAIN", "feishu"))
    .replace(/\$\{FEISHU_DM_POLICY\}/g, getEnv("FEISHU_DM_POLICY", "pairing"))
    .replace(/\$\{FEISHU_ALLOW_FROM_JSON\}/g, getEnv("FEISHU_ALLOW_FROM_JSON", "[]"))
    .replace(/\$\{BROWSER_CONTROL_TOKEN\}/g, getEnv("BROWSER_CONTROL_TOKEN"))
    .replace(/\$\{DASHSCOPE_API_KEY\}/g, getEnv("DASHSCOPE_API_KEY"))
    .replace(/\$\{SILICONFLOW_API_KEY\}/g, getEnv("SILICONFLOW_API_KEY"))
    .replace(/\$\{EMAIL_ENABLED\}/g, getEnv("EMAIL_ENABLED"))
    .replace(/\$\{EMAIL_ACCOUNT\}/g, getEnv("EMAIL_ACCOUNT"))
    .replace(/\$\{EMAIL_TOKEN\}/g, getEnv("EMAIL_TOKEN"))
    .replace(/\$\{EMAIL_MODE\}/g, getEnv("EMAIL_MODE", "imap"));
  let cfg = JSON.parse(cfgRaw);
  if (process.env.OPENROUTER_API_KEYS) {
    if (!cfg.models) cfg.models = { mode: "merge", providers: {} };
    cfg.models.providers["openrouter"] = {
      baseUrl: "http://127.0.0.1:18780/api/v1",
      apiKey: "dummy_proxy_key",
      api: "openai-completions",
      models: [{ id: "openrouter/free", name: "OpenRouter Free (Auto)" }]
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
    // EMAIL 未启用时，删除模板中的占位配置，避免 schema 校验失败
    if (cfg.channels && cfg.channels.email) {
      delete cfg.channels.email;
    }
  }
  fs.writeFileSync(process.env.OPENCLAW_CONFIG_PATH, JSON.stringify(cfg, null, 2));
' "${template_path}"

# --- 6. 飞书插件补全 ---
FEISHU_DIR="/app/openclaw/dist/extensions/feishu"
if [ -d "$FEISHU_DIR" ] && [[ ! -f "$FEISHU_DIR/index.js" && ! -f "$FEISHU_DIR/dist/index.js" ]]; then
  echo "[patch] Feishu index.js not found, attempting download from npmmirror..."
  mkdir -p /tmp/feishu_tar
  TAR_URL=$(curl -s --max-time 15 https://registry.npmmirror.com/@openclaw/feishu/latest | node -e "try{const d=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log(d.dist.tarball)}catch(e){}" || true)
  if [[ -n "${TAR_URL}" ]]; then
    curl -L --max-time 30 "${TAR_URL}" -o /tmp/feishu.tgz && tar -xzf /tmp/feishu.tgz -C /tmp/feishu_tar
    cp -r /tmp/feishu_tar/package/* "$FEISHU_DIR/" 2>/dev/null || true
    echo "[patch] Feishu plugin downloaded successfully."
  else
    echo "[patch] WARNING: Could not fetch feishu tarball URL. Plugin may not be available."
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

# --- 6b. 邮件插件补全 ---
EMAIL_DIR="/app/openclaw/dist/extensions/email"
if [[ "${EMAIL_ENABLED}" == "true" ]]; then
  if [ ! -d "$EMAIL_DIR" ] || [[ ! -f "$EMAIL_DIR/index.js" && ! -f "$EMAIL_DIR/dist/index.js" ]]; then
    echo "[patch] Email plugin not found, installing @clawemail/email..."
    mkdir -p "$EMAIL_DIR"
    # 从 npm 下载插件包
    npm pack @clawemail/email --pack-destination /tmp 2>/dev/null
    EMAIL_TAR=$(ls /tmp/clawemail-email-*.tgz 2>/dev/null | head -n 1 || true)
    if [[ -n "${EMAIL_TAR}" ]]; then
      tar -xzf "${EMAIL_TAR}" -C /tmp/email_plugin 2>/dev/null && \
        cp -r /tmp/email_plugin/package/* "$EMAIL_DIR/" 2>/dev/null || true
      rm -rf /tmp/email_plugin /tmp/clawemail-email-*.tgz 2>/dev/null || true
      echo "[patch] Email plugin installed to: $EMAIL_DIR"
    else
      echo "[patch] WARNING: Failed to download @clawemail/email. Email channel may not work."
    fi
  else
    echo "[patch] Email plugin already present at: $EMAIL_DIR"
  fi
fi

# --- 7. 启动进程 ---
rm -f /etc/nginx/.htpasswd
htpasswd -bc /etc/nginx/.htpasswd "${BASIC_AUTH_USER:-admin}" "${BASIC_AUTH_PASSWORD:-admin}"
python3 /app/docker/openrouter_proxy.py &
proxy_pid=$!
cd "${OPENCLAW_REPO_DIR}"
echo "Starting Gateway..."
HOME=/root node dist/index.js gateway --port 18789 --bind loopback --allow-unconfigured &
gateway_pid=$!
python3 /app/docker/admin_api.py &
python3 /app/docker/backup_api.py &
nginx -g "daemon off;" &
nginx_pid=$!

cleanup() { kill "${gateway_pid}" "${nginx_pid}" "${proxy_pid}" 2>/dev/null || true; exit 0; }
trap cleanup EXIT INT TERM
wait "${gateway_pid}"
