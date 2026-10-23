#!/usr/bin/env python3
"""
OpenRouter 免费模型监测
- 数据源（均为公开接口，模型目录与榜单免鉴权）：
  1. 模型目录 GET https://openrouter.ai/api/v1/models
     → 免费标识（pricing=0）、下架日期（expiration_date）、上下文长度、能力（tools/reasoning/模态）
  2. 使用榜单 GET https://openrouter.ai/api/frontend/v1/rankings/models
     → 近 N 天全站每模型调用量（count）与 token 量，variant=free 即免费模型
  3. 可用性探测 POST https://openrouter.ai/api/v1/chat/completions（需账号池 Key）
     → max_tokens=1 探活，200 才算"还能使用"；未配置 Key 时跳过探测
- 排名规则：先硬过滤（免费/文本输出/未下架/探测可用），再按近 N 天全站调用量降序，
  并列时依次比较 token 量、上下文长度、发布时间。OpenRouter 无公开评分 API，
  全站调用量即"用脚投票"的评分代理，能力标签（工具/推理/多模态）在输出中单独展示辅助判断。
- 产物：free-models.json（供 start.sh 配置生成与 admin 控制台消费）
用法：python3 openrouter_models.py [--out PATH] [--top 5] [--days 7] [--no-probe]
"""
import argparse
import json
import os
import random
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from itertools import cycle
from pathlib import Path

import requests

CATALOG_URL = "https://openrouter.ai/api/v1/models"
RANKINGS_URL = "https://openrouter.ai/api/frontend/v1/rankings/models"
CHAT_URL = "https://openrouter.ai/api/v1/chat/completions"
HTTP_HEADERS = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) OpenClawFreeModelMonitor/1.0"}
HTTP_TIMEOUT = 20          # 目录/榜单请求超时（秒）
PROBE_TIMEOUT = 10         # 单模型探活超时（秒）
EXPIRY_WARN_DAYS = 14      # 到期前多少天起在输出中标注警告
PROBE_CANDIDATES = 15      # 只探测初排前 N 的候选，控制启动耗时
DEFAULT_OUT = Path(__file__).resolve().parent / "free-models.json"

# 内置回退列表：监测失败或结果为空时，node 配置生成用它（与历史硬编码一致）
BUILTIN_FALLBACK = [
    "nvidia/nemotron-3-super-120b-a12b:free",
    "google/gemma-4-31b-it:free",
    "google/gemma-4-26b-a4b-it:free",
    "qwen/qwen3-coder:free",
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
    "openai/gpt-oss-120b:free",
]


def log(message: str) -> None:
    print(f"[free-models] {message}", flush=True)


# ---------- 网络 ----------

def http_get_json(url: str, retries: int = 3) -> list | dict:
    """GET JSON，失败指数退避重试（AGENTS.md §5.1）"""
    last_err: Exception | None = None
    for attempt in range(retries):
        try:
            r = requests.get(url, headers=HTTP_HEADERS, timeout=HTTP_TIMEOUT)
            r.raise_for_status()
            return r.json()
        except Exception as e:  # noqa: BLE001 - 网络层任何异常都重试
            last_err = e
            if attempt < retries - 1:
                time.sleep((2 ** attempt) + random.uniform(0, 0.5))
    raise RuntimeError(f"GET {url} failed after {retries} tries: {last_err}")


def fetch_catalog() -> list[dict]:
    data = http_get_json(CATALOG_URL)
    return data.get("data", []) if isinstance(data, dict) else []


def fetch_rankings() -> list[dict]:
    data = http_get_json(RANKINGS_URL)
    return data.get("data", []) if isinstance(data, dict) else []


# ---------- 过滤 ----------

def is_free(model: dict) -> bool:
    pricing = model.get("pricing") or {}
    return str(pricing.get("prompt", "1")) == "0" and str(pricing.get("completion", "1")) == "0"


def is_chat_capable(model: dict) -> bool:
    """只保留文本进/文本出的对话模型，剔除 embedding/rerank/安全分类/音频合成等"""
    arch = model.get("architecture") or {}
    output = arch.get("output_modalities") or []
    inputs = arch.get("input_modalities") or []
    return output == ["text"] and "text" in inputs


def is_router_entry(model: dict) -> bool:
    """openrouter/free 是随机路由入口，不是具体模型"""
    return model.get("id") == "openrouter/free" or model.get("canonical_slug") == "openrouter/free"


def days_until_expiry(model: dict, today: datetime) -> int | None:
    """距下架天数；None 表示未公布下架日期；负值表示已下架"""
    raw = model.get("expiration_date")
    if not raw:
        return None
    try:
        exp = datetime.strptime(str(raw)[:10], "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return (exp - today).days


# ---------- 使用量聚合 ----------

def aggregate_usage(records: list[dict], days: int, today: datetime) -> dict[str, dict]:
    """把榜单日记录聚合成 {canonical_slug: {requests, tokens}}，仅统计最近 days 天的免费变体"""
    cutoff = today.timestamp() - days * 86400
    usage: dict[str, dict] = {}
    for rec in records:
        if rec.get("variant") != "free":
            continue
        slug = rec.get("model_permaslug")
        if not slug:
            continue
        try:
            ts = datetime.strptime(str(rec.get("date", ""))[:10], "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
        if ts < cutoff:
            continue
        slot = usage.setdefault(slug, {"requests": 0, "tokens": 0})
        slot["requests"] += int(rec.get("count") or 0)
        slot["tokens"] += int(rec.get("total_prompt_tokens") or 0) + int(rec.get("total_completion_tokens") or 0)
    return usage


# ---------- 探活 ----------

def classify_probe(status: int, body: str) -> str:
    """把探测响应分类为 alive / dead / unknown"""
    if status == 200:
        return "alive"
    if status == 404:
        return "dead"
    if status == 400:
        low = body.lower()
        if "not a valid model" in low or "model not found" in low or "does not exist" in low:
            return "dead"
        return "unknown"  # 参数类错误与模型是否存在无关
    # 429=账号池限流，401/403=Key 问题，5xx=上游繁忙：都与"模型是否下架"无关
    return "unknown"


def probe_model(model_id: str, keys: list[str]) -> tuple[str, str]:
    """用账号池 Key 发 1 token 请求探活；每把 Key 最多试一次，返回 (结论, 详情)"""
    body = json.dumps({
        "model": model_id,
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 1,
    }).encode("utf-8")
    last_detail = "no attempt"
    tried: set[str] = set()
    for key in cycle(keys):
        if key in tried:
            break  # 账号池已轮完一圈
        tried.add(key)
        try:
            r = requests.post(
                CHAT_URL, data=body,
                headers={**HTTP_HEADERS, "Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                timeout=PROBE_TIMEOUT,
            )
        except requests.RequestException as e:
            last_detail = f"network: {type(e).__name__}"
            continue
        verdict = classify_probe(r.status_code, r.text[:300])
        if verdict == "alive":
            return "alive", f"HTTP {r.status_code}"
        if verdict == "dead":
            return "dead", f"HTTP {r.status_code}: {r.text[:120]}"
        last_detail = f"HTTP {r.status_code}"
        if r.status_code in (401, 403):
            continue  # Key 失效，换下一把
        break  # 429/5xx 等与模型下架无关，不再重试
    return "unknown", last_detail


# ---------- 报告 ----------

def usage_sort_key(m: dict, usage: dict[str, dict]) -> tuple:
    """统一排序键：调用量 → token → 上下文 → 发布时间（与 build_report 一致）"""
    u = usage.get(m.get("canonical_slug") or "", {"requests": 0, "tokens": 0})
    return (-u["requests"], -u["tokens"], -int(m.get("context_length") or 0), -(m.get("created") or 0))

def primary_status(catalog: list[dict], primary_id: str, today: datetime) -> str:
    """判定主模型可用性。仅依据目录事实（是否免费/是否过期/是否除名），不依赖探测结果——
    探测可能因限流等瞬时原因失败，若据此重启会造成重启循环。
    返回值：ok / expired / delisted / not_configured"""
    pid = (primary_id or "").strip()
    if not pid or pid in ("free", "auto"):
        return "not_configured"  # 未配置或随机路由入口，无从判定也无需切换
    for m in catalog:
        if m.get("id") == pid:
            if not is_free(m):
                return "delisted"  # 已转为付费
            remain = days_until_expiry(m, today)
            if remain is not None and remain < 0:
                return "expired"  # 已过官方下架日
            return "ok"
    return "delisted"  # 目录中已除名


def build_report(catalog: list[dict], usage: dict[str, dict], probe_results: dict[str, tuple[str, str]],
                 top_n: int, days: int, today: datetime, probed: bool,
                 primary_id: str = "") -> dict:
    candidates: list[dict] = []
    excluded: list[dict] = []
    for m in catalog:
        mid = m.get("id", "")
        if not mid:
            continue
        if not is_free(m):
            continue
        if is_router_entry(m):
            excluded.append({"id": mid, "reason": "随机路由入口，非具体模型"})
            continue
        if not is_chat_capable(m):
            excluded.append({"id": mid, "reason": f"非对话模态: {(m.get('architecture') or {}).get('modality')}"})
            continue
        remain = days_until_expiry(m, today)
        if remain is not None and remain < 0:
            excluded.append({"id": mid, "reason": f"已到下架日期 {m.get('expiration_date')}"})
            continue
        slug = m.get("canonical_slug") or ""
        u = usage.get(slug, {"requests": 0, "tokens": 0})
        candidates.append({
            "id": mid,
            "name": m.get("name") or mid,
            "canonical_slug": slug,
            "requests": u["requests"],
            "tokens": u["tokens"],
            "context_length": int(m.get("context_length") or 0),
            "tools": "tools" in (m.get("supported_parameters") or []),
            "reasoning": bool((m.get("reasoning") or {}).get("default_enabled") or (m.get("reasoning") or {}).get("mandatory")),
            "multimodal_input": len((m.get("architecture") or {}).get("input_modalities") or []) > 1,
            "expires_in_days": remain,
            "created": m.get("created") or 0,
        })

    # 初排：调用量 → token → 上下文 → 发布时间（新者优先）
    candidates.sort(key=lambda c: (-c["requests"], -c["tokens"], -c["context_length"], -(c["created"] or 0)))
    # 探测：仅对初排前 PROBE_CANDIDATES 个候选执行
    final: list[dict] = []
    for idx, c in enumerate(candidates):
        if probed and idx < PROBE_CANDIDATES:
            verdict, detail = probe_results.get(c["id"], ("unknown", "not probed"))
            c["probe"] = verdict
            c["probe_detail"] = detail
            if verdict == "dead":
                excluded.append({"id": c["id"], "reason": f"探测不可用: {detail}"})
                continue
        else:
            c["probe"] = "skipped" if not probed else "unknown"
            c["probe_detail"] = "未配置 Key 跳过探测" if not probed else "超出探测候选范围"
        final.append(c)

    for rank, c in enumerate(final[:top_n], 1):
        c["rank"] = rank

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "window_days": days,
        "probed": probed,
        "primary": primary_id or None,
        "primary_status": primary_status(catalog, primary_id, today),
        "top": final[:top_n],
        "excluded": excluded,
        "stats": {
            "free_in_catalog": sum(1 for m in catalog if is_free(m)),
            "chat_candidates": len(candidates),
            "probed": sum(1 for c in candidates[:PROBE_CANDIDATES] if probed),
            "excluded": len(excluded),
        },
    }


def print_report(report: dict) -> None:
    top = report["top"]
    log(f"窗口 {report['window_days']} 天 | 目录免费模型 {report['stats']['free_in_catalog']} 个 | "
        f"对话候选 {report['stats']['chat_candidates']} 个 | 探测 {report['stats']['probed']} 个 | "
        f"排除 {report['stats']['excluded']} 个")
    pstat = report.get("primary_status", "not_configured")
    if pstat != "not_configured":
        log(f"主模型 {report.get('primary')} 状态: {pstat}"
            + ("（已下线，需切换）" if pstat in ("delisted", "expired") else ""))
    if not top:
        log("未得到可用模型（详见 excluded）")
        return
    log(f"{'排名':<4}{'模型 ID':<52}{'近窗调用':>12}{'token':>10}{'上下文':>8}{'工具':>5}{'到期':>6}  探测")
    for c in top:
        exp = f"{c['expires_in_days']}d" if c["expires_in_days"] is not None else "-"
        tok = f"{c['tokens'] / 1e9:.1f}B" if c["tokens"] >= 1e9 else f"{c['tokens'] / 1e6:.1f}M"
        log(f"{c['rank']:<4}{c['id']:<52}{c['requests']:>12,}{tok:>10}"
            f"{c['context_length'] // 1024:>7}K{'✓' if c['tools'] else '✗':>5}{exp:>6}  {c['probe']}")


# ---------- 对外接口（admin_api 复用） ----------

_result_lock = __import__("threading").Lock()


def load_result(path: Path) -> dict | None:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def run_check(out_path: Path, top_n: int = 5, days: int = 7, use_probe: bool | None = None,
              primary_id: str = "") -> dict:
    """完整流程：目录 → 榜单 → 过滤 → 探活 → 排名 → 落盘。供 CLI 与 admin API 共用。"""
    today = datetime.now(timezone.utc)
    keys = [k.strip() for k in os.environ.get("OPENROUTER_API_KEYS", os.environ.get("OPENROUTER_API_KEY", "")).split(",") if k.strip()]
    if use_probe is None:
        use_probe = bool(keys)

    log("拉取模型目录 ...")
    catalog = fetch_catalog()
    log(f"目录共 {len(catalog)} 个模型")
    log("拉取使用榜单 ...")
    usage = aggregate_usage(fetch_rankings(), days, today)
    log(f"近 {days} 天有调用记录的免费模型 {len(usage)} 个")

    # 先做一轮轻量初排以决定探测对象（与 build_report 内部排序保持一致）
    prelim = [m for m in catalog if is_free(m) and not is_router_entry(m) and is_chat_capable(m)]
    prelim.sort(key=lambda m: usage_sort_key(m, usage))
    probe_targets = [m.get("id") for m in prelim[:PROBE_CANDIDATES]]

    probe_results: dict[str, tuple[str, str]] = {}
    if use_probe and probe_targets:
        log(f"探测 Top{len(probe_targets)} 候选可用性（{len(keys)} 把 Key）...")
        with ThreadPoolExecutor(max_workers=min(8, len(probe_targets))) as pool:
            futures = {pool.submit(probe_model, mid, keys): mid for mid in probe_targets}
            for fut in as_completed(futures):
                mid = futures[fut]
                try:
                    probe_results[mid] = fut.result()
                except Exception as e:  # noqa: BLE001 - 单模型探测失败不影响整体
                    probe_results[mid] = ("unknown", f"probe error: {e}")

    report = build_report(catalog, usage, probe_results, top_n, days, today, probed=use_probe,
                          primary_id=primary_id)
    print_report(report)

    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    os.replace(tmp, out_path)
    log(f"结果已写入 {out_path}")
    return report


def get_cached_result(out_path: Path, max_age: int = 600, force: bool = False, top_n: int = 5, days: int = 7) -> dict:
    """带缓存的读取：max_age 秒内直接返回磁盘缓存，否则重跑（admin API 用）"""
    with _result_lock:
        if not force:
            cached = load_result(out_path)
            if cached:
                try:
                    age = datetime.now(timezone.utc).timestamp() - datetime.fromisoformat(cached["generated_at"]).timestamp()
                    if age < max_age:
                        return cached
                except Exception:
                    pass
        return run_check(out_path, top_n=top_n, days=days)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="OpenRouter 免费模型监测：按近 N 天全站调用量输出可用免费模型 Top N")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="结果 JSON 输出路径")
    parser.add_argument("--top", type=int, default=5, help="输出前 N 个模型（默认 5）")
    parser.add_argument("--days", type=int, default=7, help="统计最近 N 天调用量（默认 7）")
    parser.add_argument("--no-probe", action="store_true", help="跳过探活（未配置 Key 时自动跳过）")
    parser.add_argument("--primary", default="", help="当前主模型 ID（openrouter/ 前缀可省略），用于判定是否已下线")
    args = parser.parse_args(argv)
    try:
        run_check(args.out, top_n=args.top, days=args.days, use_probe=False if args.no_probe else None,
                  primary_id=args.primary)
    except Exception as e:  # noqa: BLE001 - 顶层兜底：启动脚本依赖退出码决定是否回退
        log(f"ERROR: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
