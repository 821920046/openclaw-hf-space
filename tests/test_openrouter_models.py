"""openrouter_models.py 离线单元测试：过滤/聚合/排序/探测分类/Key 轮换（mock 网络）"""
import importlib.util
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "orm", Path(__file__).resolve().parent.parent / "docker" / "openrouter_models.py")
orm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(orm)

NOW = datetime(2026, 10, 23, tzinfo=timezone.utc)


def mk_model(mid, prompt="0", completion="0", modality="text->text", inputs=None,
             outputs=None, canonical=None, expiry=None, ctx=128000, created=1790000000,
             params=None, router=False):
    return {
        "id": mid, "name": mid.split("/")[-1],
        "canonical_slug": canonical or mid.replace(":free", ""),
        "expiration_date": expiry, "context_length": ctx, "created": created,
        "pricing": {"prompt": prompt, "completion": completion},
        "architecture": {"modality": modality,
                         "input_modalities": inputs or ["text"],
                         "output_modalities": outputs or ["text"]},
        "supported_parameters": params if params is not None else ["tools", "temperature"],
        "reasoning": {},
    }


# ---------- 1. classify_probe ----------
cases = [
    (200, "ok", "alive"),
    (404, "not found", "dead"),
    (400, "is not a valid model ID", "dead"),
    (400, "model not found", "dead"),
    (400, "invalid temperature", "unknown"),   # 参数错误与模型存在性无关
    (429, "rate limited", "unknown"),          # 限流是 Key 问题
    (401, "no auth", "unknown"),               # Key 失效
    (503, "overloaded", "unknown"),            # 上游繁忙
]
for status, body, expect in cases:
    got = orm.classify_probe(status, body)
    assert got == expect, f"classify_probe({status}, {body!r}) = {got}, expect {expect}"
print("T1 classify_probe: 8/8 PASS")

# ---------- 2. 过滤函数 ----------
assert orm.is_free(mk_model("a/b:free")) is True
assert orm.is_free(mk_model("a/b", prompt="0.000001")) is False
assert orm.is_free(mk_model("a/b", prompt="0", completion="0.000001")) is False
assert orm.is_chat_capable(mk_model("a/b:free")) is True
assert orm.is_chat_capable(mk_model("a/b:free", modality="text+image->text+audio",
                                    inputs=["text", "image"], outputs=["text", "audio"])) is False
assert orm.is_chat_capable(mk_model("a/b:free", modality="text->embedding",
                                    inputs=["text"], outputs=["embedding"])) is False
assert orm.is_router_entry(mk_model("openrouter/free")) is True
assert orm.is_router_entry(mk_model("openrouter/auto")) is False
assert orm.days_until_expiry(mk_model("a/b:free", expiry="2026-10-30"), NOW) == 7
assert orm.days_until_expiry(mk_model("a/b:free", expiry="2026-10-01"), NOW) == -22
assert orm.days_until_expiry(mk_model("a/b:free"), NOW) is None
print("T2 filters: PASS")

# ---------- 3. aggregate_usage ----------
records = [
    {"variant": "free", "model_permaslug": "a/b-20260101", "date": "2026-10-22 00:00:00",
     "count": 100, "total_prompt_tokens": 1000, "total_completion_tokens": 500},
    {"variant": "free", "model_permaslug": "a/b-20260101", "date": "2026-10-21 00:00:00",
     "count": 50, "total_prompt_tokens": 400, "total_completion_tokens": 100},
    {"variant": "standard", "model_permaslug": "a/b-20260101", "date": "2026-10-22 00:00:00",
     "count": 99999, "total_prompt_tokens": 0, "total_completion_tokens": 0},  # 付费变体不计入
    {"variant": "free", "model_permaslug": "a/b-20260101", "date": "2026-10-01 00:00:00",
     "count": 88888, "total_prompt_tokens": 0, "total_completion_tokens": 0},  # 超出窗口
    {"variant": "free", "model_permaslug": "c/d-20260101", "date": "2026-10-22 00:00:00",
     "count": 200, "total_prompt_tokens": 0, "total_completion_tokens": 0},
]
usage = orm.aggregate_usage(records, days=7, today=NOW)
assert usage == {"a/b-20260101": {"requests": 150, "tokens": 2000},
                 "c/d-20260101": {"requests": 200, "tokens": 0}}, usage
print("T3 aggregate_usage: PASS（窗口/variant/多日聚合均正确）")

# ---------- 4. build_report：过期排除 + 探测排除 + 排序 + top_n ----------
catalog = [
    mk_model("hot/model:free", canonical="hot/model-20260101", ctx=1000000),   # 调用量最高
    mk_model("dead/model:free", canonical="dead/model-20260101", ctx=1000000),  # 探测不可用应排除
    mk_model("expired/model:free", canonical="expired/model-20260101", expiry="2026-10-20"),  # 已下架
    mk_model("expiring/model:free", canonical="expiring/model-20260101", expiry="2026-10-27", ctx=256000),
    mk_model("mid/model:free", canonical="mid/model-20260101", ctx=512000),
    mk_model("zero/model:free", canonical="zero/model-20260101", ctx=64000),    # 无调用记录排最后
    mk_model("openrouter/free", canonical="openrouter/free"),                  # 路由入口（id 需精确匹配）
    mk_model("audio/lyria", canonical="audio/lyria-20260101", modality="text->text+audio",
             inputs=["text"], outputs=["text", "audio"]),                      # 音频输出
    mk_model("paid/model", canonical="paid/model-20260101", prompt="0.000001"),  # 已转付费
]
usage2 = {
    "hot/model-20260101": {"requests": 5000, "tokens": 900},
    "dead/model-20260101": {"requests": 4000, "tokens": 800},
    "expired/model-20260101": {"requests": 99999, "tokens": 99999},
    "expiring/model-20260101": {"requests": 3000, "tokens": 700},
    "mid/model-20260101": {"requests": 1000, "tokens": 600},
}
# 注意：probe_results 的 key 是模型 id（与 build_report 内部 c["id"] 一致），不是 canonical_slug
probe = {"hot/model:free": ("alive", "200"), "dead/model:free": ("dead", "404"),
         "expiring/model:free": ("alive", "200"), "mid/model:free": ("alive", "200")}
rep = orm.build_report(catalog, usage2, probe, top_n=5, days=7, today=NOW, probed=True)
ids = [c["id"] for c in rep["top"]]
assert ids == ["hot/model:free", "expiring/model:free", "mid/model:free", "zero/model:free"], ids
assert rep["top"][0]["rank"] == 1 and rep["top"][3]["rank"] == 4
assert rep["top"][1]["expires_in_days"] == 4  # 临期标记
excl = {e["id"]: e["reason"] for e in rep["excluded"]}
assert "expired/model:free" in excl and "已到下架日期" in excl["expired/model:free"]
assert "dead/model:free" in excl and "探测不可用" in excl["dead/model:free"]
assert "openrouter/free" in excl and "audio/lyria" in excl
assert "paid/model" not in [c["id"] for c in rep["top"]]  # 付费模型根本不在候选
assert rep["top"][3]["probe"] == "unknown"  # 超出探测候选范围的标记
print("T4 build_report: PASS（过期/探测不可用/路由入口/非对话/付费全部正确排除，排序正确）")

# ---------- 5. probe_model：Key 轮换与有限重试（mock 网络） ----------
class FakeResp:
    def __init__(self, status, text=""):
        self.status_code, self.text = status, text

with mock.patch.object(orm.requests, "post") as mp:
    # 场景 A：第一把 Key 401，第二把 200 → alive
    mp.side_effect = [FakeResp(401, "no auth"), FakeResp(200, "ok")]
    v, d = orm.probe_model("hot/model:free", ["key1", "key2"])
    assert (v, d) == ("alive", "HTTP 200"), (v, d)
    assert mp.call_count == 2
    # 场景 B：单 Key + 401 → 必须终止（修复前的死循环），unknown
    mp.reset_mock(); mp.side_effect = [FakeResp(401, "no auth")]
    v, d = orm.probe_model("hot/model:free", ["only-key"])
    assert v == "unknown" and mp.call_count == 1, (v, mp.call_count)
    # 场景 C：429 → 不重试直接 unknown
    mp.reset_mock(); mp.side_effect = [FakeResp(429, "slow down")]
    v, d = orm.probe_model("hot/model:free", ["k1", "k2"])
    assert v == "unknown" and mp.call_count == 1
    # 场景 D：两把 Key 都 401 → 轮完一圈退出
    mp.reset_mock(); mp.side_effect = [FakeResp(401), FakeResp(403)]
    v, d = orm.probe_model("hot/model:free", ["k1", "k2"])
    assert v == "unknown" and mp.call_count == 2, (v, mp.call_count)
    # 场景 E：网络异常 → unknown 不崩溃
    import requests as _rq
    mp.reset_mock(); mp.side_effect = _rq.exceptions.ConnectTimeout("boom")
    v, d = orm.probe_model("hot/model:free", ["k1"])
    assert v == "unknown" and "network" in d
print("T5 probe_model: PASS（401 换 Key、单 Key 不死循环、429 不重试、轮完即退、异常兜底）")

# ---------- 6. usage_sort_key 与 build_report 内部排序一致 ----------
m1, m2 = mk_model("x/a:free", canonical="x/a-20260101"), mk_model("x/b:free", canonical="x/b-20260101")
u = {"x/a-20260101": {"requests": 10, "tokens": 10}, "x/b-20260101": {"requests": 20, "tokens": 5}}
assert orm.usage_sort_key(m2, u) < orm.usage_sort_key(m1, u)  # b 调用量高排前
u["x/a-20260101"] = {"requests": 20, "tokens": 99}           # 并列时比 token
assert orm.usage_sort_key(m1, u) < orm.usage_sort_key(m2, u)
print("T6 usage_sort_key: PASS")

# ---------- 7. primary_status：主模型下线判定（只依据目录事实，不依赖探测） ----------
from datetime import timedelta
past = (NOW - timedelta(days=1)).strftime("%Y-%m-%dT00:00:00Z")
future = (NOW + timedelta(days=30)).strftime("%Y-%m-%dT00:00:00Z")
cat = [
    mk_model("vendor/alive:free", canonical="vendor/alive-20260101"),
    mk_model("vendor/paid", canonical="vendor/paid-20260101", prompt="0.000001"),
    mk_model("vendor/expired:free", canonical="vendor/expired-20260101", expiry=past),
    mk_model("vendor/okexp:free", canonical="vendor/okexp-20260101", expiry=future),
]
assert orm.primary_status(cat, "vendor/alive:free", NOW) == "ok"
assert orm.primary_status(cat, "vendor/paid", NOW) == "delisted"          # 已转付费
assert orm.primary_status(cat, "vendor/expired:free", NOW) == "expired"   # 已过下架日
assert orm.primary_status(cat, "vendor/okexp:free", NOW) == "ok"          # 未到下架日
assert orm.primary_status(cat, "vendor/gone:free", NOW) == "delisted"     # 目录除名
assert orm.primary_status(cat, "", NOW) == "not_configured"
assert orm.primary_status(cat, "free", NOW) == "not_configured"           # 随机路由入口
assert orm.primary_status(cat, "auto", NOW) == "not_configured"
# build_report 带上 primary 时输出 primary/primary_status 字段
rep = orm.build_report(cat, {}, {}, top_n=5, days=7, today=NOW, probed=False,
                       primary_id="vendor/paid")
assert rep["primary"] == "vendor/paid" and rep["primary_status"] == "delisted", rep
rep2 = orm.build_report(cat, {}, {}, top_n=5, days=7, today=NOW, probed=False)
assert rep2["primary"] is None and rep2["primary_status"] == "not_configured"
print("T7 primary_status: PASS（转付费/过期/除名/路由入口/未配置全部正确）")

# ---------- 8. primary_probe：探活结论只作观察，绝不改变切换判定 ----------
cat8 = [
    mk_model("vendor/alive:free", canonical="vendor/alive-20260101"),
    mk_model("vendor/other:free", canonical="vendor/other-20260101"),
]
# 目录仍标记可用 + 探活失败 = "悄悄下线"场景：必须能告警，但绝不能触发切换/重启
r8 = orm.build_report(cat8, {}, {"vendor/alive:free": ("dead", "404")},
                      top_n=5, days=7, today=NOW, probed=True,
                      primary_id="vendor/alive:free")
assert r8["primary_probe"] == "dead", r8["primary_probe"]
assert r8["primary_status"] == "ok", "探活失败绝不能触发切换/重启判定"
r8b = orm.build_report(cat8, {}, {"vendor/alive:free": ("alive", "200")},
                       top_n=5, days=7, today=NOW, probed=True,
                       primary_id="vendor/alive:free")
assert r8b["primary_probe"] == "alive"
r8c = orm.build_report(cat8, {}, {}, top_n=5, days=7, today=NOW, probed=False,
                       primary_id="vendor/alive:free")
assert r8c["primary_probe"] == "skipped"          # 未配置 Key
r8d = orm.build_report(cat8, {}, {}, top_n=5, days=7, today=NOW, probed=True)
assert r8d["primary_probe"] is None                # 未配置主模型
r8e = orm.build_report(cat8, {}, {}, top_n=5, days=7, today=NOW, probed=True,
                       primary_id="vendor/other:free")
assert r8e["primary_probe"] == "unknown"           # 主模型不在探测结果里，不能崩
print("T8 primary_probe: PASS（dead 只告警不切换；alive/skipped/None/unknown 全部正确）")

# ---------- 9. run_check 补探主模型 + 强制重跑继承 primary ----------
import tempfile
# 20 个免费候选，主模型 m19 调用量为 0，必然排在探测候选（前 15）之外
cat9 = [mk_model(f"v/m{i}:free", canonical=f"v/m{i}-20260101") for i in range(20)]
usage9 = {f"v/m{i}-20260101": {"requests": 100 - i, "tokens": 0} for i in range(15)}
# 注入 Key 模拟真实容器：get_cached_result 强制重跑时 use_probe 取自环境变量
with mock.patch.object(orm, "fetch_catalog", return_value=cat9), \
     mock.patch.object(orm, "fetch_rankings", return_value=[]), \
     mock.patch.object(orm, "aggregate_usage", return_value=usage9), \
     mock.patch.dict("os.environ", {"OPENROUTER_API_KEYS": "test-key"}), \
     mock.patch.object(orm, "probe_model", return_value=("alive", "HTTP 200")) as mp9:
    with tempfile.TemporaryDirectory() as td:
        out9 = Path(td) / "free-models.json"
        rep9 = orm.run_check(out9, top_n=5, days=7, use_probe=True, primary_id="v/m19:free")
        probed_ids = {c.args[0] for c in mp9.call_args_list}
        assert "v/m19:free" in probed_ids, "主模型即使在 15 名外也必须单独补探"
        assert len(probed_ids) == 16, len(probed_ids)
        assert rep9["primary_probe"] == "alive"
        assert rep9["primary_status"] == "ok"
        assert rep9["stats"]["probed"] == 16
        # 控制台「重新检测」不传 primary_id，必须从上次报告继承，否则主模型状态/告警会消失
        rep9b = orm.get_cached_result(out9, max_age=600, force=True)
        assert rep9b["primary"] == "v/m19:free", rep9b["primary"]
        assert rep9b["primary_status"] == "ok"
        assert rep9b["primary_probe"] == "alive"
print("T9 run_check/get_cached_result: PASS（15 名外补探、统计准确、强制重跑继承主模型）")

# ---------- 10. available：完整可用池，供意图路由挑 Top5 之外的 coder 模型 ----------
rep10 = orm.build_report(cat9, usage9, {}, top_n=5, days=7, today=NOW, probed=False)
assert len(rep10["top"]) == 5
assert len(rep10["available"]) == 20, len(rep10["available"])
ids10 = {m["id"] for m in rep10["available"]}
assert "v/m19:free" in ids10, "Top5 之外的模型必须也在池里，否则代码类找不到 coder"
assert all(set(m) == {"id", "tools", "reasoning", "context_length"} for m in rep10["available"])
print("T10 available: PASS（完整候选池 20 个，字段精简且含 Top5 之外的模型）")

print("ALL_UNIT_TESTS_PASS")
