# 飞书文档创建技能

使用飞书开放平台 API 创建飞书文档。

## 前置条件
- 已在飞书开发者后台为应用开通以下权限：
  - `docx:document` (管理新版文档)
  - `drive:drive` (访问云空间)
- 容器环境已设置 `FEISHU_APP_ID` 和 `FEISHU_APP_SECRET`

## 创建文档

执行以下命令创建飞书文档：

```bash
bash ~/.openclaw/.openclaw/workspace/skills/feishu-doc/create-doc.sh "文档标题"
```

脚本成功后会输出文档的 URL（如 `https://bytedance.feishu.cn/docx/xxxxx`）。

## 带内容创建文档（两阶段）

飞书 API 不支持一步创建带内容的文档，需分两步：

**Step 1: 创建空文档并获取 doc_id**
```bash
bash ~/.openclaw/.openclaw/workspace/skills/feishu-doc/create-doc.sh "文档标题"
```
记录输出的 URL 和日志中的 `Doc ID`。

**Step 2: 将 Markdown 文件导入到已创建的文档**
将 Markdown 内容写入本地 .md 文件后，用 Python 脚本调用飞书 block API 写入内容：

```python
import json, requests, os

doc_id = "从Step1获取的document_id"
token = "从auth接口获取的tenant_access_token"

# 读取本地 Markdown 文件
with open("文档内容.md", "r", encoding="utf-8") as f:
    content = f.read()

# 按段落拆分并构建 blocks
blocks = []
for para in content.split("\n\n"):
    para = para.strip()
    if not para:
        continue
    blocks.append({
        "block_type": 2,  # text block
        "text": {
            "elements": [{"text_run": {"content": para}}],
            "style": {}
        }
    })

url = f"https://open.feishu.cn/open-apis/docx/v1/documents/{doc_id}/blocks/{doc_id}/children"
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"}
resp = requests.post(url, headers=headers, json={"children": blocks, "index": -1})
if resp.json().get("code") == 0:
    print(f"内容写入成功: https://bytedance.feishu.cn/docx/{doc_id}")
else:
    print(f"内容写入失败: {resp.text}")
```

## 权限确认检查清单

如果创建失败，请按以下顺序排查：
1. 飞书应用后台 → 权限管理 → 确认 `docx:document` 和 `drive:drive` 已开通
2. 确认 `FEISHU_APP_ID` 和 `FEISHU_APP_SECRET` 环境变量正确
3. 查看脚本的 stderr 输出获取具体 API 错误信息
4. API 频率限制：3 次/秒/应用，避免短时间大量创建

## API 端点参考

| 用途 | 端点 |
|------|------|
| 获取 token | POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal |
| 创建文档 | POST https://open.feishu.cn/open-apis/docx/v1/documents |
| 写入内容 | POST https://open.feishu.cn/open-apis/docx/v1/documents/{id}/blocks/{id}/children |
