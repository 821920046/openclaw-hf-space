
## 模型升级 & 故障排查（2026-06-30 补充）

### 四个 provider 的「最优免费模型」

| Provider | 推荐主力模型 | 上下文 | 说明 |
|---|---|---|---|
| Groq | `openai/gpt-oss-120b`（工具调用强）或 `qwen/qwen3-32b`（更快） | 30K TPM | scout 工具调用弱，不建议做主力 |
| Gemini | `gemini-2.5-flash` | 大 | 免费档 RPM/TPM 小，易 429，宜做兜底而非首选 |
| SiliconFlow | `Qwen/Qwen3-8B`（已从 Qwen2-7B 升级） | 131K | 永久免费，30 RPM / 60K TPM |
| OpenRouter | `openrouter/owl-alpha` | 1M | 实测唯一稳定扛 40–60K 大请求的免费模型，推荐做主模型 |

SiliconFlow 模型列表已更新为：`Qwen/Qwen3-8B`、`deepseek-ai/DeepSeek-R1-Distill-Qwen-7B`、`THUDM/GLM-Z1-9B-0414`（均为永久免费）。

### SiliconFlow 403 排查

日志若出现 `provider=siliconflow ... rawError=403 ... reason=auth`，**不是额度问题，是鉴权失败**：
1. 检查 HF Space Secrets 是否配了 `SILICONFLOW_API_KEY`；
2. 去 https://cloud.siliconflow.cn/account/ak 重新生成 key；
3. 确认调用的是免费模型（如 `Qwen/Qwen3-8B`）。

SiliconFlow 免费额度：①一批永久免费模型（Qwen3-8B 等，仅受速率限制）；②新用户注册赠送额度（用于调用付费大模型）。

### 关于「多设几个免费模型做轮询」

OpenClaw 的 `fallbacks` 是**顺序故障转移（sequential failover）**，不是真正的负载均衡轮询——只有当前一个模型报错（限流/鉴权/超时）才会切到下一个。因此：
- 多加 1–2 个**大上下文**免费模型（如 `openrouter/deepseek-v4-flash:free`）做更深兜底，能提升**冗余度**，值得做；
- 但它**不会降低单次请求的 token 体积**，治不了 413 膨胀根因——根治仍靠裁上下文（`OPENCLAW_MAX_HISTORY_MESSAGES` + 禁 `memory-core`）；
- OpenRouter 这一层已有**真正的轮询**：`openrouter_proxy.py` 会在 `OPENROUTER_API_KEYS`（多个 key 逗号分隔）之间轮转，可借此放大 OpenRouter 免费配额。

推荐用 `OPENCLAW_FALLBACKS` 自定义链，例如：
`OPENCLAW_FALLBACKS=openrouter/owl-alpha, groq/openai/gpt-oss-120b, openrouter/deepseek-v4-flash:free, gemini/gemini-2.5-flash, siliconflow/Qwen/Qwen3-8B`

## ⚠️ 重要更正（2026-06-30）：上下文护栏变量已废弃

实测发现：向 `agents.defaults` 注入 `context` / `historyLimit` 等非 schema 键，会导致 OpenClaw 网关以
`Gateway failed to start: Invalid config ... agents.defaults: Invalid input` **启动失败**，并被 watchdog 反复重启（崩溃循环）。

因此以下两个变量**已从 start.sh 移除，请勿再设置**：
- ~~`OPENCLAW_MAX_HISTORY_MESSAGES`~~（废弃）
- ~~`OPENCLAW_MAX_CONTEXT_TOKENS`~~（废弃）

**上下文控制的正确（schema 合法）手段：**
1. `OPENCLAW_DISABLE_PLUGINS=file-transfer,talk-voice,memory-core` — 禁 memory-core 是压上下文的最大杠杆；
2. `OPENCLAW_DEFAULT_MODEL=openrouter/owl-alpha` — 1M 上下文，实测扛大请求；
3. 必要时临时设 `OPENCLAW_RESET_STATE_ON_BOOT=1` 启动一次清掉会话历史，再改回 0。

> 修复后的 start.sh 启动日志不再出现 `context guardrail set`，`agents.defaults` 仅含合法的 `model` + `thinkingDefault`。
