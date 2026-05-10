#!/usr/bin/env bash
# create-doc.sh — 创建飞书文档
# 用法: create-doc.sh "文档标题"
# 环境变量: FEISHU_APP_ID, FEISHU_APP_SECRET
set -euo pipefail

TITLE="${1:-}"

if [[ -z "${TITLE}" ]]; then
  echo "[feishu-doc] ERROR: 缺少文档标题" >&2
  echo "用法: create-doc.sh \"文档标题\"" >&2
  exit 1
fi

APP_ID="${FEISHU_APP_ID:-}"
APP_SECRET="${FEISHU_APP_SECRET:-}"

if [[ -z "${APP_ID}" || -z "${APP_SECRET}" ]]; then
  echo "[feishu-doc] ERROR: 缺少 FEISHU_APP_ID 或 FEISHU_APP_SECRET 环境变量" >&2
  exit 1
fi

# --- Step 1: 获取 tenant_access_token ---
echo "[feishu-doc] 正在获取 tenant_access_token..." >&2

TOKEN_RESP=$(curl -sS --max-time 10 \
  -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "$(python3 -c "
import json, os
body = {'app_id': os.environ['APP_ID'], 'app_secret': os.environ['APP_SECRET']}
print(json.dumps(body, ensure_ascii=False))
")" 2>&1)

TOKEN=$(echo "${TOKEN_RESP}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    t = d.get('tenant_access_token', '')
    print(t, end='')
except:
    sys.exit(1)
" 2>&1) || true

if [[ -z "${TOKEN}" ]]; then
  echo "[feishu-doc] ERROR: 无法获取 tenant_access_token" >&2
  echo "[feishu-doc] API 响应: ${TOKEN_RESP}" >&2
  exit 1
fi
echo "[feishu-doc] Token 获取成功" >&2

# --- Step 2: 创建文档 ---
echo "[feishu-doc] 正在创建飞书文档: ${TITLE}" >&2

CREATE_RESP=$(curl -sS --max-time 15 \
  -X POST "https://open.feishu.cn/open-apis/docx/v1/documents" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "$(python3 -c "
import json
print(json.dumps({'title': '${TITLE}'}))
")" 2>&1)

# 用 python3 解析响应
PARSE_RESULT=$(echo "${CREATE_RESP}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    code = d.get('code', -1)
    msg = d.get('msg', '')
    if code == 0:
        doc = d['data']['document']
        print('OK')
        print(doc.get('document_id', ''))
        print(doc.get('url', ''))
        print(doc.get('title', ''))
    else:
        print('ERROR')
        print(f'code={code} msg={msg}', file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print('ERROR')
    print(f'Parse error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1)

STATUS=$(echo "${PARSE_RESULT}" | head -1)

if [[ "${STATUS}" != "OK" ]]; then
  echo "[feishu-doc] ERROR: 创建文档失败" >&2
  echo "[feishu-doc] 详情: ${PARSE_RESULT}" >&2
  exit 1
fi

DOC_ID=$(echo "${PARSE_RESULT}" | sed -n '2p')
DOC_URL=$(echo "${PARSE_RESULT}" | sed -n '3p')
DOC_TITLE=$(echo "${PARSE_RESULT}" | sed -n '4p')

cat <<EOF
飞书文档创建成功！
- 标题: ${DOC_TITLE}
- 文档ID: ${DOC_ID}
- 链接: ${DOC_URL}
EOF

echo "[feishu-doc] 文档创建成功! ID=${DOC_ID}" >&2
echo "[feishu-doc] URL: ${DOC_URL}" >&2
