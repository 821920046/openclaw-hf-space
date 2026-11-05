#!/usr/bin/env python3
"""按用户消息意图把请求路由到更合适的免费模型（代理层插件，默认关闭）。

第一性原理约束：
- OpenClaw 是 agent，一轮对话会连发多次请求（工具调用、历史压缩、标题生成）且强依赖 tool calling。
  因此只在「出现新的 user 文本消息」时分类，整轮对话锁定同一模型，绝不中途换模型。
- OpenRouter 没有代码/写作能力评分，分类只能是高置信度关键词，模型选择只能是名称启发式。
- 未命中、找不到合适目标、用户显式指定了别的模型时，一律不改写请求（行为与关闭时完全一致）。
"""
import hashlib
import json
import re
import threading
import time

# 高置信度词表：宁可少命中也不误命中（误命中会换模型，代价大）。
# 中文语境下英文词前后常是汉字（如「写个Python脚本」），不能用 \b 词边界，直接子串匹配。
_CODE_RE = re.compile(
    r"代码|编程|程序|函数|报错|异常|调试|重构|正则|终端|命令行|编译|变量|堆栈|"
    r"python|javascript|typescript|traceback|stack ?trace|typeerror|bug|debug|"
    r"sql|html|css|git|npm|docker|api|code|function",
    re.I)
# 「脚本」按自媒体语境归写作（短视频脚本）；带语言名的「Python 脚本」会先命中代码类而被消解。
_WRITE_RE = re.compile(
    r"文案|文章|润色|改写|标题|小红书|公众号|朋友圈|短视频脚本|视频脚本|脚本|作文|"
    r"续写|扩写|文风|语气|读后感|广告语|推文|博客|周报|slogan|写一段|写一篇",
    re.I)
_CODER_RE = re.compile(r"coder|code", re.I)

POOL_TTL = 300  # 免费模型池缓存秒数；监测每 6 小时刷新，5 分钟缓存足够
_pool_lock = threading.Lock()
_pool_cache = {"ts": 0.0, "data": None}
_route_lock = threading.Lock()
_route_state = {"user_hash": None, "model": None}


def log(message: str) -> None:
    print(f"[Router] {message}", flush=True)


def reset_state() -> None:
    """仅供测试与显式重置使用，清空会话锁定。"""
    with _route_lock:
        _route_state.update(user_hash=None, model=None)


def _strip_provider(model_id) -> str:
    """去掉 openrouter/ 前缀，适配 OpenClaw 传裸 ID 或带 provider 前缀两种写法。"""
    mid = str(model_id or "")
    return mid[len("openrouter/"):] if mid.startswith("openrouter/") else mid


def _last_user_text(messages) -> str | None:
    """取最后一条 role=user 的纯文本消息。工具循环里它仍是本轮那条 user 消息，
    因而 hash 不变、自动沿用锁定模型；完全无 user 文本时返回 None。"""
    for m in reversed(messages or []):
        if not isinstance(m, dict) or m.get("role") != "user":
            continue
        content = m.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = [p.get("text", "") for p in content
                     if isinstance(p, dict) and p.get("type") == "text"]
            if parts:
                return "\n".join(parts)
    return None


def classify(text) -> str | None:
    """返回 code / writing / None。代码优先，用于消解「写个 Python 脚本」这类歧义。"""
    if not text:
        return None
    if _CODE_RE.search(text):
        return "code"
    if _WRITE_RE.search(text):
        return "writing"
    return None


def _load_pool(path) -> dict:
    """读取监测报告里的完整可用池与 Top 榜；读失败返回空池，让上层安全跳过路由。"""
    now = time.time()
    with _pool_lock:
        if _pool_cache["data"] is not None and now - _pool_cache["ts"] < POOL_TTL:
            return _pool_cache["data"]
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            pool = {
                "available": [m for m in data.get("available", []) if isinstance(m, dict)],
                "top": [m for m in data.get("top", []) if isinstance(m, dict)],
            }
        except Exception as e:  # noqa: BLE001 - 文件缺失/损坏/并发写都必须降级为不路由
            log(f"WARNING: 读取免费模型池失败，本次不路由: {e}")
            pool = {"available": [], "top": []}
        _pool_cache.update(ts=now, data=pool)
        return pool


def pick_model(kind: str, pool: dict) -> str | None:
    """从可用池里挑目标模型；挑不到返回 None（不改写请求）。
    只挑 tools=true 的模型，避免切到不支持工具调用的免费模型导致 agent 失效。"""
    if not kind:
        return None
    if kind == "code":
        candidates = [m for m in pool.get("available", [])
                      if m.get("tools") and _CODER_RE.search(str(m.get("id", "")))]
        candidates.sort(key=lambda m: -int(m.get("context_length") or 0))
    else:
        # 写作类没有客观能力数据，用监测 Top1 通用模型（长上下文）作代理
        candidates = [m for m in pool.get("top", [])
                      if m.get("tools") and not _CODER_RE.search(str(m.get("id", "")))]
    for m in candidates:
        mid = str(m.get("id") or "").strip()
        if mid:
            return mid
    return None


def route_body(body, enabled: bool, default_model: str, pool_path: str):
    """返回 (改写后的 body bytes 或 None, 切换说明或 None)。
    None 表示完全不改写；沿用会话锁定时说明为 None，避免工具循环刷屏。"""
    if not enabled or not body:
        return None, None
    try:
        payload = json.loads(body)
    except (ValueError, TypeError):
        return None, None
    if not isinstance(payload, dict):
        return None, None

    # 用户在控制台显式选了别的模型（如 /model）→ 尊重手动选择，不覆盖
    if default_model and _strip_provider(payload.get("model")) != _strip_provider(default_model):
        return None, None

    messages = payload.get("messages")
    if not isinstance(messages, list):
        return None, None
    text = _last_user_text(messages)

    if text is None:
        # 无 user 文本的内部请求（标题生成等）：沿用锁定模型，保持整轮一致
        with _route_lock:
            cached = _route_state["model"]
        if cached:
            payload["model"] = cached
            return json.dumps(payload, ensure_ascii=False).encode("utf-8"), None
        return None, None

    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
    with _route_lock:
        if _route_state["user_hash"] == digest and _route_state["model"]:
            cached = _route_state["model"]
            payload["model"] = cached
            return json.dumps(payload, ensure_ascii=False).encode("utf-8"), None

    kind = classify(text)
    target = pick_model(kind, _load_pool(pool_path)) if kind else None
    with _route_lock:
        _route_state.update(user_hash=digest, model=target)
    if not target:
        # 未命中或挑不到合适模型：清除锁定，后续请求回到 OpenClaw 默认模型
        return None, None
    payload["model"] = target
    return json.dumps(payload, ensure_ascii=False).encode("utf-8"), f"{kind} -> {target}"
