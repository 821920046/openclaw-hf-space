---
title: OpenClaw HF Space
sdk: docker
app_port: 7860
base_path: /openclaw
startup_duration_timeout: 30m
---

# OpenClaw on Hugging Face Spaces

本仓库将 [OpenClaw](https://github.com/openclaw/openclaw) 打包为一个公开的 Hugging Face Docker Space，并在边缘层集成了 Nginx `Basic Auth` 基础认证，而 OpenClaw 本身在容器内部仅绑定到回环地址（loopback）。

该项目旨在适配 Hugging Face 的免费 Docker 层级：应用可公开访问、空闲时会自动进入休眠，且默认不提供持久化磁盘。

## 部署内容

- OpenClaw 网关绑定在 `127.0.0.1:18789`
- 启用 OpenClaw 控制台 UI
- Nginx 监听端口 `7860`
- 支持 WebSocket 的 Nginx 到 OpenClaw 反向代理
- 基于 Hugging Face Secrets 运行时生成的配置

## 部署模式

此 Hugging Face 变体将 OpenClaw 保留在 `127.0.0.1`，并且**不使用** `gateway.auth.mode: "trusted-proxy"`。
OpenClaw 官方文档允许在受信任的仅回环环境中显式使用 `gateway.auth.mode: "none"`，这种模式更适合 Spaces，因为 Hugging Face 会在你的容器前插入额外的反向代理。

## 重要安全提示

- OpenClaw 的控制台 UI 是管理界面。由于公开的 Space 暴露风险较高，此部署方案有意增加了 Nginx `Basic Auth`。
- 本模板还启用了 `gateway.controlUi.dangerouslyDisableDeviceAuth`，以便远程浏览器无需手动配对确认即可连接。这是针对免费版 Spaces 限制所做的安全性折中。
- 请勿使用弱密码。
- 如果你需要持久化、始终在线的网关或即时通讯频道集成，请将其迁移到 VPS 或其他私人主机。

## 必需的 Hugging Face Secrets

在 Space 的 `Settings -> Variables and secrets` 中创建以下项：

- `BASIC_AUTH_USER`
- `BASIC_AUTH_PASSWORD`
- 一个或多个供应商 Secrets：
  - `OPENROUTER_API_KEY`
  - `NVIDIA_API_KEY`
  - `DASHSCOPE_API_KEY`
  - `SILICONFLOW_API_KEY`

可选变量：

- `SPACE_HOST`
  - 如果未设置，启动脚本会尝试从 Hugging Face 变量中自动推导。
- `OPENCLAW_DEFAULT_MODEL`
  - 默认为 `openrouter/free`
- `OPENCLAW_USE_TRUSTED_PROXY_AUTH`
  - 本模板默认为 `0`，在 Hugging Face Spaces 上应保持关闭状态。
- `FEISHU_APP_ID`
  - 通过 Hugging Face 凭据持久化飞书凭据，而不是仅保存在控制台 UI 中。
- `FEISHU_APP_SECRET`
  - 通过 Hugging Face 凭据持久化飞书凭据，而不是仅保存在控制台 UI 中。
- `FEISHU_DOMAIN`
  - 默认为 `feishu`
- `FEISHU_DM_POLICY`
  - 可选。若未设置，当 `FEISHU_ALLOW_FROM` 已设置时启动脚本会自动使用 `allowlist`，否则回退到 `pairing`。
- `FEISHU_ALLOW_FROM`
  - 逗号分隔的飞书 open_id 白名单。例如：`ou_abc123,ou_def456`
- `OPENCLAW_RESET_STATE_ON_BOOT`
  - 默认为 `0`。仅当你希望每次启动都清空运行时状态时才设置为 `1`。
- `OPENCLAW_REWRITE_CONFIG_ON_BOOT`
  - 默认为 `0`。如果你希望启动时的 secrets 每次都覆盖现有的配置文件，请设置为 `1`。
- `OPENCLAW_CONFIG_JSON_B64`
  - 可选的高级选项，将完整的 `openclaw.json` 以 Base64 编码形式存储在 Hugging Face secret 中。
- `OPENCLAW_REPO`
  - 默认为 `https://github.com/openclaw/openclaw.git`
- `OPENCLAW_HF_STATE_REPO`
  - 可选的 Hugging Face 仓库，用于状态备份和恢复。建议格式：`<用户名>/<仓库名>`。
- `OPENCLAW_HF_STATE_REPO_TYPE`
  - 默认为 `dataset`
- `OPENCLAW_HF_STATE_SYNC_INTERVAL`
  - 默认为 `300` 秒。设置为 `0` 则禁用定期上传，仅在停机时同步。
- `OPENCLAW_HF_STATE_RESTORE_ON_BOOT`
  - 默认为 `1`
- `OPENCLAW_HF_STATE_PRIVATE`
  - 默认为 `1`，确保自动创建的仓库是私有的。
- `HF_TOKEN`
  - 如果启用了 `OPENCLAW_HF_STATE_REPO` 则为必需项。请使用具有写入权限的 Hugging Face Token。

## 飞书配置设置

如果你希望飞书私聊能稳定工作而无需脆弱的运行时配对，请在 Hugging Face Spaces 上使用此流程：

1. 在飞书开发者后台，创建或打开你的机器人应用。
2. 为应用启用长连接事件订阅模式。
3. 在 Hugging Face Space 的 `Settings -> Variables and secrets` 中设置：
   - `FEISHU_APP_ID=<你的应用ID>`
   - `FEISHU_APP_SECRET=<你的应用密钥>`
   - `FEISHU_DOMAIN=feishu`
   - `FEISHU_ALLOW_FROM=<你的open_id>`
4. （可选）显式设置 `FEISHU_DM_POLICY=allowlist`。如果省略，当 `FEISHU_ALLOW_FROM` 存在时，模板会自动切换到 `allowlist`。
5. 设置 `OPENCLAW_DEFAULT_MODEL=openrouter/free`，除非你已确认供应商账号支持其他模型 ID。
6. 重新构建或重启 Space。
7. 启动后，确认日志包含：
   - `Feishu channel: ENABLED`
   - `Feishu dmPolicy: allowlist`
   - `Feishu allowFrom: ["ou_..."]`
8. 在飞书中给机器人发送私聊。它应当直接回答，而无需等待配对批准。

要查找你的飞书 `open_id`，你可以临时给机器人发送一条私聊，并检查类似以下的运行时日志：

```text
[feishu] feishu[default]: received message from ou_xxx... in oc_xxx... (p2p)
```

`ou_xxx...` 的值就是你应该填入 `FEISHU_ALLOW_FROM` 的发送者 `open_id`。

如果你希望允许任何飞书用户发送私聊，请设置 `FEISHU_DM_POLICY=open` 并保留 `FEISHU_ALLOW_FROM` 为空，但这比 `allowlist` 限制更少。

## 免费版 Spaces 的状态持久化

Hugging Face 免费 Docker Spaces 不提供持久化的本地磁盘，因此 `/root/.openclaw` 内部的运行时更改可能会在重启、重新构建或主机迁移后消失。
本模板现支持可选的备份与恢复功能，可将状态同步至 Hugging Face Hub 仓库，从而使你的 OpenClaw 主目录在重启后依然可用。

建议设置步骤：

1. 创建一个私有的 Hugging Face Dataset 仓库来存放状态存档。
2. 创建一个具有写入权限的 Hugging Face Token。
3. 在 `Settings -> Variables and secrets` 中添加：
   - `HF_TOKEN=<你的HF写入Token>`
   - `OPENCLAW_HF_STATE_REPO=<用户名>/<状态仓库名称>`
   - 可选：`OPENCLAW_HF_STATE_SYNC_INTERVAL=300`
4. 重新构建 Space。
5. 确认启动日志中包含如下行：
   - `OpenClaw state sync: ENABLED (repo=..., type=dataset, interval=300s)`
6. 更改配置、安装技能或更新记忆后，等待下一个同步间隔，或正常重启 Space 以触发关机同步上传最新状态。

持久化的内容包括：

- `openclaw.json`
- `~/.openclaw/state` 下的新人会话和状态
- `~/.openclaw` 下的设备和配对文件
- 在 `~/.openclaw` 内部创建的其他运行文件

权衡说明：

- 如果从保存的状态存档恢复，恢复后的 `openclaw.json` 默认会被保留。
- 如果以后更改了 Hugging Face 环境变量并需要它们覆盖恢复出的配置，请在重启时临时设置 `OPENCLAW_REWRITE_CONFIG_ON_BOOT=1`。

## 部署步骤

1. 创建一个新的 Hugging Face Space。
2. 选择 `Docker` 作为 SDK。
3. 将此仓库的内容上传到 Space 仓库根目录。
4. 添加必需的 secrets。
5. 等待镜像构建完成。
6. 打开 Space URL 并通过 `Basic Auth` 验证。
7. 在 `/openclaw/` 路径访问控制台 UI。
8. 发送测试消息，确认供应商返回响应。

Space 根路径 `/` 保留用于 Hugging Face 健康检查，应返回纯文本 `ok`。

对于飞书，在免费版层级上请不要仅依赖在控制台 UI 中更改频道。除非凭据同时也存在于 Space secrets 或付费持久化存储中，否则网关重启或容器重构可能会丢失运行时更改。
由于 Hugging Face Spaces 位于平台代理之后，即使 Nginx 经过精心配置，较新版本的 OpenClaw 仍可能因 `trusted_proxy_loopback_source` 拒绝 `trusted-proxy` 认证。因此，本模板使用了 OpenClaw 配置文档中最简单可靠的模式：保持 `gateway.bind: "loopback"`，设置 `gateway.auth.mode: "none"`，让 Nginx 的 Basic Auth 成为唯一的准入关口。
在免费版 Spaces 上，运行时配对批准也不是永久的。对于飞书，最可靠的设置是提供 `FEISHU_ALLOW_FROM=<你的open_id>`。当该变量存在时，本模板会自动将私聊策略切换为 `allowlist`，这样机器人可以立即响应，而无需等待稍纵即逝的配对批准状态。

## Hugging Face 检查清单

在第一次重新构建前创建以下项：

- **必需项**
  - `BASIC_AUTH_USER`
  - `BASIC_AUTH_PASSWORD`
  - 至少一个供应商密钥：`OPENROUTER_API_KEY` 或 `NVIDIA_API_KEY` 或 `DASHSCOPE_API_KEY` 或 `SILICONFLOW_API_KEY`
- **飞书集成强烈建议**
  - `FEISHU_APP_ID`
  - `FEISHU_APP_SECRET`
  - `FEISHU_DOMAIN=feishu`
  - `FEISHU_DM_POLICY=allowlist`
  - `FEISHU_ALLOW_FROM=ou_89367e9cb5938513d24cac7bb3c0c5a7`
- **推荐的行为标志**
  - `OPENCLAW_RESET_STATE_ON_BOOT=0`
  - `OPENCLAW_REWRITE_CONFIG_ON_BOOT=0`
  - `OPENCLAW_DEFAULT_MODEL=openrouter/free`
- **免费版持久化建议**
  - `HF_TOKEN=<你的HF写入Token>`
  - `OPENCLAW_HF_STATE_REPO=<用户名>/<状态仓库名称>`
  - `OPENCLAW_HF_STATE_REPO_TYPE=dataset`
  - `OPENCLAW_HF_STATE_SYNC_INTERVAL=300`
- **其它可选**
  - `SPACE_HOST`
  - `OPENCLAW_CONFIG_JSON_B64`（当你希望将完整的 OpenClaw 配置作为 secret 存储时）

推送仓库更新后，打开 Space 设置，确认上述 secrets，并触发重新构建。然后检查启动日志中的 `Installed OpenClaw ref:` 行，以确认容器确实在运行指定的版本。

如果你更喜欢使用 Git 而非网页上传器：

```bash
git init
git remote add origin https://huggingface.co/spaces/<用户名>/<Space名称>
git add .
git commit -m "feat: 增加 OpenClaw HF Docker 部署支持"
git push origin main
```

## 本地构建

在上传之前，你可以在本地构建容器：

```bash
docker build -t openclaw-hf-space .
docker run --rm -p 7860:7860 \
  -e BASIC_AUTH_USER=admin \
  -e BASIC_AUTH_PASSWORD=change-me \
  -e OPENROUTER_API_KEY=sk-or-... \
  -e SPACE_HOST=localhost:7860 \
  openclaw-hf-space
```

然后访问 `http://localhost:7860/openclaw/`。

## 文件说明

- `Dockerfile`: OpenClaw 多阶段构建及运行镜像
- `docker/nginx.conf`: 边缘认证 + 反向代理 + WebSocket 支持
- `docker/start.sh`: 运行时校验、配置生成、进程启动
- `docker/openclaw.template.json`: 适配 Space 的 OpenClaw 配置模板

## 上游版本策略

Docker 构建过程会从 GitHub 克隆 OpenClaw，检出指定的稳定标签，并按照镜像所需的顺序进行构建：`pnpm install`, `pnpm build`, `pnpm ui:build`。较新的 OpenClaw 将控制台 UI 放在仓库根目录的 `ui/` 下，因此镜像最后通过根目录脚本运行 `ui:build`，确保 `dist/control-ui/` 存在于最终运行镜像中，供 `node dist/index.js gateway` 使用。

本模板默认使用：

- 仓库：`https://github.com/openclaw/openclaw.git`
- 引用策略：默认固定到已知可构建的稳定标签（`OPENCLAW_REF=v2026.5.3-1`）
- 缓存刷新提示：`ARG OPENCLAW_STABLE_REFRESH=2026-05-05`

此处的“稳定版”指如下格式的标签：

- `v2026.5.3-1`
- `v2026.4.2`
- `v2026.3.24`

不包括预发行标签，如：

- `v2026.4.2-beta.1`
- `v2026.4.2-rc.1`

本仓库目前在 `Dockerfile` 中默认使用 `ARG OPENCLAW_REF="v2026.5.3-1"`。这样可以避免 `stable` 自动跳到刚发布的上游标签后，被 pnpm 的 `minimumReleaseAge` 策略或新依赖变更打断构建。

如果你以后想更改版本，请修改 `Dockerfile` 中的 `ARG OPENCLAW_REF=...` 为你想要的准确标签。

重要提示：`stable` 仅在 Docker 镜像构建期间解析。Docker 层缓存可能导致 Hugging Face 在上游发布新标签后仍然使用旧的已解析标签。发生这种情况时：

- 要固定某个准确版本，请在 `Dockerfile` 中设置 `ARG OPENCLAW_REF=v2026.x.y`。
- 要刷新最新稳定标签的选择，请保持 `OPENCLAW_REF=stable` 并更改 `ARG OPENCLAW_STABLE_REFRESH=...` 的值，然后重新构建 Space。
- 选定的引用（ref）和提交 ID（commit）会被写入镜像内的 `.openclaw-build-ref` 和 `.openclaw-build-commit` 中，并在启动时打印以便调试。镜像不再运行单独的 `pnpm ui:install` 步骤。

## 故障排除

- `git clone` 期间构建失败
  - 检查构建环境是否可以访问 GitHub。
- 选择标签时构建失败
  - OpenClaw 可能更改了标签命名规则，或者仓库暂时没有可抓取的标签。
- `pnpm install` 或 `pnpm build` 期间构建失败
  - OpenClaw 可能更改了工作区或构建脚本；如有需要，请回退到已知的正常版本。
- 应用返回 `502 Bad Gateway`
  - OpenClaw 可能在 Nginx 能够代理之前就退出了。检查 Space 运行时日志中的 Node 进程。
- UI 加载但无法连接
  - 确认浏览器使用的是 `https://<space>.hf.space/openclaw/`。
  - 如果看到手动的 WebSocket/Token 连接表单，说明你访问了错误的页面，或者旧的部署仍在运行之前的 UI。
- 连接后发送消息失败
  - 核实 `OPENROUTER_API_KEY` 是否有效且具有模型访问权限。
- 飞书私聊不断提示配对，或重启后配对批准消失
  - 设置 `FEISHU_ALLOW_FROM=<你的open_id>`。本模板将自动切换为 `allowlist` 模式，或者你也可以显式设置 `FEISHU_DM_POLICY=allowlist`。
- 重启后运行时状态消失
  - 配置 `HF_TOKEN` 和 `OPENCLAW_HF_STATE_REPO`，以便模板将 `~/.openclaw` 备份到私有的 Hugging Face 数据集仓库，并在下次启动时恢复。

## 预期局限性

- 除非添加付费持久化存储，否则全量重启后不保留持久化状态。
- 免费版 Space 在无活动后会进入休眠。
- 在免费层级上，仅通过 OpenClaw UI 进行的运行时配置更改不是永久性的，除非这些更改也被编码进 Hugging Face secrets 或持久化存储中。
- 不适用于 WhatsApp、Telegram、Discord 或其他长连接频道会话。
- 不适用于无人看管的、始终在线的网关用途。

## 额外的供应商 Secrets

你可以选择性地添加以下 Hugging Face secrets 来启用更多供应商支持：

- `NVIDIA_API_KEY`
  - 通过 OpenClaw 内置的 NVIDIA 供应商启用 NVIDIA 托管的 NIM 模型。NVIDIA Build 宣传为开发提供免费推理，但具体免费模型的可用性随模型和时间而变化。
- `DASHSCOPE_API_KEY`
  - 通过具有 OpenAI 兼容路径的端点启用阿里灵积（DashScope）。这通常依赖于新客免费额度或促销额度，而非永久无限次免费使用。
- `SILICONFLOW_API_KEY`
  - 通过其 OpenAI 兼容端点启用硅基流动（SiliconFlow）。SiliconFlow 提供了一系列免费模型，但列表和限制可能随时间更改。

## 支持的默认模型

你可以通过设置 Hugging Face 变量 `OPENCLAW_DEFAULT_MODEL` 来切换默认模型。

常用值：

- `openrouter/free`
  - 使用 OpenRouter 的免费路由，是本模板最安全的默认值。
- `dashscope/qwen-turbo`
  - 若存在 `DASHSCOPE_API_KEY`，则使用通义千问 Turbo 版本。
- `dashscope/qwen-plus`
  - 如果额度允许，这是能力更强的通义千问选项。
- `siliconflow/Qwen/Qwen2-7B-Instruct`
  - 若存在 `SILICONFLOW_API_KEY`，则使用 SiliconFlow 的 Qwen2-7B。
- `siliconflow/Qwen/Qwen2-1.5B-Instruct`
  - SiliconFlow 较小的免费模型选项。
- `siliconflow/THUDM/glm-4-9b-chat`
  - SiliconFlow 免费模型示例中常见的另一个选项。

