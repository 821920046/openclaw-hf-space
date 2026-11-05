#!/usr/bin/env python3
"""
OpenRouter 多 Key 负载均衡代理
- 使用 ThreadingHTTPServer 支持并发请求
- 请求超时保护，防止无限挂起
- Key 健康状态追踪（429/401/403 自动标记）
- /health 健康检查端点
"""
import http.server
import socketserver
import requests
import os
import json
import time
import threading
from itertools import cycle

import model_router

PORT = 18780
CONNECT_TIMEOUT = 10   # 连接超时（秒）
READ_TIMEOUT = 120     # 读取超时（秒）
KEY_COOLDOWN = 60      # Key 被 429 后的冷却时间（秒）

# 从环境变量获取 Key 列表
keys_env = os.environ.get("OPENROUTER_API_KEYS", "")
if not keys_env:
    keys_env = os.environ.get("OPENROUTER_API_KEY", "")
KEYS = [k.strip() for k in keys_env.split(",") if k.strip()]

if not KEYS:
    print("[Proxy] Warning: No OpenRouter API keys found. Proxy will fail.")
    KEYS = ["invalid_key"]

# Key 健康状态追踪
key_status: dict[str, dict] = {k: {"healthy": True, "cooldown_until": 0.0} for k in KEYS}
key_lock = threading.Lock()
key_index = 0


def get_next_healthy_key() -> str | None:
    """获取下一个健康的 Key（线程安全轮换）"""
    global key_index
    now = time.time()
    with key_lock:
        for _ in range(len(KEYS)):
            key = KEYS[key_index % len(KEYS)]
            key_index += 1
            status = key_status[key]
            # 冷却期结束后自动恢复
            if not status["healthy"] and now > status["cooldown_until"]:
                status["healthy"] = True
            if status["healthy"]:
                return key
    # 所有 Key 都不健康，强制返回第一个（可能已冷却完毕）
    return KEYS[0]


def mark_key_unhealthy(key: str, reason: str, cooldown: float = KEY_COOLDOWN) -> None:
    """标记 Key 为不健康状态"""
    with key_lock:
        key_status[key]["healthy"] = False
        key_status[key]["cooldown_until"] = time.time() + cooldown
    print(f"[Proxy] Key {key[:8]}... marked unhealthy: {reason} (cooldown {cooldown}s)")


def compact_chat_messages(body_bytes: bytes, max_history: int = 16) -> bytes:
    """对多轮对话进行滑动窗口压缩：
    保留开头系统指令与最新的 max_history 条消息，防止 Token 滚雪球导致 429 限流或首字卡顿。
    """
    if not body_bytes or max_history <= 0:
        return body_bytes
    try:
        data = json.loads(body_bytes.decode("utf-8"))
        messages = data.get("messages")
        if not isinstance(messages, list) or len(messages) <= max_history:
            return body_bytes

        # 提取开头的 system 消息（定义 Agent 设定与工具）
        system_msgs = []
        for m in messages:
            if isinstance(m, dict) and m.get("role") == "system":
                system_msgs.append(m)
            else:
                break

        # 截取尾部最新的 max_history 条消息
        recent_msgs = messages[-max_history:]
        recent_ids = {id(m) for m in recent_msgs}
        final_system = [m for m in system_msgs if id(m) not in recent_ids]

        omitted = len(messages) - len(final_system) - len(recent_msgs)
        if omitted > 0:
            notice = {
                "role": "system",
                "content": f"[上下文智能保护：为确保响应速度与避免超出模型配额，已自动压缩归档早期 {omitted} 条历史消息]"
            }
            data["messages"] = final_system + [notice] + recent_msgs
            print(f"[Proxy] Context compacted: {len(messages)} -> {len(data['messages'])} messages (omitted {omitted})")
            return json.dumps(data, ensure_ascii=False).encode("utf-8")
    except Exception as exc:
        print(f"[Proxy] Context compaction skipped due to parse error: {exc}")
    return body_bytes


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    # 抑制默认日志（太嘈杂）
    def log_message(self, format, *args):
        pass

    def proxy_request(self, method: str) -> None:
        # 健康检查端点
        if self.path == "/health":
            with key_lock:
                healthy_count = sum(1 for s in key_status.values() if s["healthy"])
            data = json.dumps({
                "status": "ok" if healthy_count > 0 else "degraded",
                "total_keys": len(KEYS),
                "healthy_keys": healthy_count,
            })
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data.encode("utf-8"))
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else None

        # 按用户消息意图路由到更合适的免费模型（默认关闭；仅作用于对话补全请求）。
        # 改写后 body 长度会变，但转发时排除了 Content-Length 头，requests 会自动重算。
        if method == "POST" and "/chat/completions" in self.path:
            routed, note = model_router.route_body(
                body,
                enabled=os.environ.get("OPENCLAW_MODEL_ROUTING", "0") == "1",
                default_model=os.environ.get("OPENCLAW_DEFAULT_MODEL", ""),
                pool_path=os.environ.get("OPENROUTER_FREE_MODELS_FILE", "/app/docker/free-models.json"),
            )
            if routed is not None:
                body = routed
            if note:
                model_router.log(note)

            # 长上下文智能滑动窗口压缩（防 429 限流与首字卡顿，默认保留 16 条）
            try:
                max_ctx = int(os.environ.get("OPENCLAW_MAX_CONTEXT_MESSAGES", "16"))
            except ValueError:
                max_ctx = 16
            if max_ctx > 0 and body:
                body = compact_chat_messages(body, max_history=max_ctx)

        # 转发到 OpenRouter
        url = "https://openrouter.ai" + self.path

        headers = {}
        for k, v in self.headers.items():
            if k.lower() not in ("host", "authorization", "connection", "content-length", "accept-encoding"):
                headers[k] = v

        max_retries = min(len(KEYS), 3)  # 最多重试 3 次
        for attempt in range(max_retries):
            key = get_next_healthy_key()
            if not key:
                break
            headers["Authorization"] = f"Bearer {key}"

            try:
                with requests.request(
                    method, url, data=body, headers=headers,
                    stream=True,
                    timeout=(CONNECT_TIMEOUT, READ_TIMEOUT),
                ) as r:
                    # Key 被限流，标记后重试
                    if r.status_code == 429:
                        mark_key_unhealthy(key, "rate_limited_429")
                        continue

                    # Key 失效（认证错误），标记后重试
                    if r.status_code in (401, 403):
                        mark_key_unhealthy(key, f"auth_error_{r.status_code}", cooldown=300)
                        continue

                    # 上游提供商临时过载或网关超时（如 503 Overloaded），换下一个 Key 快速重试
                    if r.status_code in (502, 503, 504):
                        mark_key_unhealthy(key, f"upstream_overload_{r.status_code}", cooldown=30)
                        continue

                    self.send_response(r.status_code)
                    for hk, hv in r.headers.items():
                        if hk.lower() not in ("transfer-encoding", "content-encoding", "connection"):
                            self.send_header(hk, hv)
                    self.end_headers()

                    # 流式转发响应
                    for chunk in r.iter_content(chunk_size=4096):
                        if chunk:
                            try:
                                self.wfile.write(chunk)
                                self.wfile.flush()
                            except (BrokenPipeError, ConnectionResetError):
                                break
                    return

            except requests.exceptions.Timeout:
                print(f"[Proxy] Timeout on {method} {self.path} with key {key[:8]}...")
                mark_key_unhealthy(key, "timeout", cooldown=30)
                continue
            except requests.exceptions.RequestException as e:
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": {"message": f"Proxy error: {e}"}}).encode("utf-8"))
                return

        # 所有 Key 用尽
        self.send_response(429)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        error_msg = json.dumps({
            "error": {
                "message": "All configured OpenRouter API keys are currently unavailable. Please wait and try again later."
            }
        })
        self.wfile.write(error_msg.encode("utf-8"))

    def do_POST(self):
        self.proxy_request("POST")

    def do_GET(self):
        self.proxy_request("GET")

    def do_OPTIONS(self):
        self.proxy_request("OPTIONS")


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with ThreadedHTTPServer(("127.0.0.1", PORT), ProxyHandler) as httpd:
        print(f"[Proxy] OpenRouter Threaded Proxy on 127.0.0.1:{PORT} | {len(KEYS)} keys | timeout {CONNECT_TIMEOUT}s/{READ_TIMEOUT}s")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
