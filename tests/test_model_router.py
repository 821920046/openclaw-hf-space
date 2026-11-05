"""model_router.py 离线单测：意图分类、会话锁定、零改写边界、只选 tools 模型"""
import importlib.util
import json
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "model_router", Path(__file__).resolve().parent.parent / "docker" / "model_router.py")
mr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mr)

DEFAULT = "openrouter/nvidia/nemotron-3-super-120b-a12b:free"
RAW_MODEL = "nvidia/nemotron-3-super-120b-a12b:free"
TOP1 = "nvidia/nemotron-3-ultra-550b-a55b:free"
CODER = "qwen/qwen3-coder:free"

POOL = {
    "available": [
        {"id": TOP1, "tools": True, "reasoning": True, "context_length": 1000000},
        {"id": CODER, "tools": True, "reasoning": False, "context_length": 262000},
        # tools=False 且上下文更大：验证「只选支持工具的模型」优先于上下文长度
        {"id": "some/weak-coder:free", "tools": False, "reasoning": False, "context_length": 9999999},
    ],
    "top": [{"id": TOP1, "tools": True}, {"id": CODER, "tools": True}],
}


def mk_body(text=None, model=RAW_MODEL, last=None):
    msgs = [{"role": "system", "content": "you are openclaw"}]
    if text is not None:
        msgs.append({"role": "user", "content": text})
    if last is not None:
        msgs.append(last)
    return json.dumps({"model": model, "messages": msgs, "max_tokens": 100},
                      ensure_ascii=False).encode("utf-8")


def setup_pool(td, pool=POOL):
    p = Path(td) / "free-models.json"
    p.write_text(json.dumps(pool, ensure_ascii=False), encoding="utf-8")
    mr._pool_cache.update(ts=0.0, data=None)   # 绕开 300 秒池缓存
    mr.reset_state()
    return str(p)


def model_of(out):
    return json.loads(out)["model"] if out is not None else None


# ---------- 1. 分类：代码优先消解歧义、无命中返回 None ----------
assert mr.classify("帮我写个 Python 脚本读 CSV") == "code"       # 语言名消解「脚本」歧义
assert mr.classify("这段代码报错 TypeError，帮我 debug 一下") == "code"
assert mr.classify("帮我写一条小红书文案，语气轻松点") == "writing"
assert mr.classify("视频脚本怎么写？") == "writing"
assert mr.classify("今天天气怎么样") is None
assert mr.classify("") is None
print("T1 classify: PASS（代码优先 / 写作 / 未命中）")

with tempfile.TemporaryDirectory() as td:
    p = setup_pool(td)

    # ---------- 2. 默认关闭：零行为变化 ----------
    assert mr.route_body(mk_body("写个函数"), False, DEFAULT, p) == (None, None)
    print("T2 开关关闭: PASS（完全不改写）")

    # ---------- 3. 代码类改写，且跳过 tools=False 的模型 ----------
    out, note = mr.route_body(mk_body("写个函数判断回文"), True, DEFAULT, p)
    assert model_of(out) == CODER, model_of(out)
    assert note and "code" in note
    print("T3 代码类路由: PASS（选中 coder，跳过不支持工具的模型）")

    # ---------- 4. 会话锁定：工具循环 / 无 user 文本请求都保持同一模型 ----------
    mr.reset_state()
    out1, _ = mr.route_body(mk_body("写个函数"), True, DEFAULT, p)
    assert model_of(out1) == CODER
    loop = mk_body("写个函数", last={"role": "tool", "content": "tool result"})
    out2, note2 = mr.route_body(loop, True, DEFAULT, p)
    assert model_of(out2) == CODER, "工具循环中途换模型会破坏 agent"
    assert note2 is None, "沿用锁定不应刷日志"
    internal = json.dumps({"model": RAW_MODEL,
                           "messages": [{"role": "system", "content": "summarize"}]},
                          ensure_ascii=False).encode("utf-8")
    assert model_of(mr.route_body(internal, True, DEFAULT, p)[0]) == CODER
    print("T4 会话锁定: PASS（工具循环与内部请求不中途切换）")

    # ---------- 5. 新消息重分类；未命中时清除锁定、完全不改写 ----------
    out4, note4 = mr.route_body(mk_body("再帮我写条朋友圈文案"), True, DEFAULT, p)
    assert model_of(out4) == TOP1 and note4 and "writing" in note4
    out5, note5 = mr.route_body(mk_body("今天天气怎么样"), True, DEFAULT, p)
    assert out5 is None and note5 is None
    loop2 = mk_body("今天天气怎么样", last={"role": "tool", "content": "r"})
    assert model_of(mr.route_body(loop2, True, DEFAULT, p)[0]) is None, "锁定未清除"
    print("T5 重分类 / 未命中: PASS（切写作 → 未命中归零且不残留锁定）")

    # ---------- 6. 用户显式指定别的模型 → 尊重手动选择 ----------
    manual = mk_body("写个函数", model="google/gemma-4-31b-it:free")
    assert mr.route_body(manual, True, DEFAULT, p)[0] is None
    print("T6 显式指定优先: PASS")

    # ---------- 7. coder 全都不支持 tools 时，代码类不改写（安全降级）----------
    pool2 = {
        "available": [{"id": "x/coder:free", "tools": False, "context_length": 1000}],
        "top": [{"id": TOP1, "tools": True}],
    }
    p2 = setup_pool(td, pool2)
    assert mr.route_body(mk_body("写个函数"), True, DEFAULT, p2)[0] is None
    assert model_of(mr.route_body(mk_body("写条文案"), True, DEFAULT, p2)[0]) == TOP1
    print("T7 安全降级: PASS（无可用 coder 就不切；写作类仍可用）")

    # ---------- 8. 池文件缺失 / body 非法 → 不改写且不抛异常 ----------
    mr.reset_state()
    mr._pool_cache.update(ts=0.0, data=None)
    assert mr.route_body(mk_body("写个函数"), True, DEFAULT, "/nonexistent/pool.json")[0] is None
    assert mr.route_body(b"not json", True, DEFAULT, p)[0] is None
    assert mr.route_body(json.dumps({"model": RAW_MODEL}).encode(), True, DEFAULT, p)[0] is None
    print("T8 异常兜底: PASS（池缺失 / 非 JSON / 无 messages 均安全跳过）")

print("ALL_ROUTER_TESTS_PASS")
