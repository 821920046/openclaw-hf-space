#!/usr/bin/env python3
import unittest
import os
import sys
import json
import re
from pathlib import Path

# 将 docker 目录加入 path
sys.path.insert(0, str(Path(__file__).parent.parent / "docker"))
import openrouter_proxy

# 容错 mock huggingface_hub（本地开发环境可能未安装，容器环境已内置）
from unittest.mock import MagicMock
if "huggingface_hub" not in sys.modules:
    mock_hub = MagicMock()
    sys.modules["huggingface_hub"] = mock_hub
    sys.modules["huggingface_hub.errors"] = MagicMock()

import importlib.util
spec = importlib.util.spec_from_file_location("hf_state_store", str(Path(__file__).parent.parent / "docker" / "hf-state-store.py"))
hf_state_store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hf_state_store)

class TestOptimizationFeatures(unittest.TestCase):
    def test_proxy_health_and_keys(self):
        self.assertTrue(len(openrouter_proxy.KEYS) >= 1)
        next_key = openrouter_proxy.get_next_healthy_key()
        self.assertIsNotNone(next_key)

    def test_proxy_unhealthy_marking(self):
        key = openrouter_proxy.KEYS[0]
        openrouter_proxy.mark_key_unhealthy(key, "upstream_overload_503", cooldown=5)
        self.assertFalse(openrouter_proxy.key_status[key]["healthy"])
        openrouter_proxy.key_status[key]["healthy"] = True

    def test_security_guard_script_syntax(self):
        script_path = Path(__file__).parent.parent / "docker" / "security-guard.sh"
        self.assertTrue(script_path.exists())
        content = script_path.read_text(encoding="utf-8")
        self.assertIn("node", content)
        self.assertIn("gateway", content)
        self.assertIn("[SECURITY GUARD]", content)

    def test_context_compaction(self):
        # 构造一条长对话（1 条 system + 20 条对答）
        msgs = [{"role": "system", "content": "You are a helpful assistant."}]
        for i in range(20):
            msgs.append({"role": "user" if i % 2 == 0 else "assistant", "content": f"msg {i}"})
        
        raw_body = json.dumps({"messages": msgs}).encode("utf-8")
        # 限制为 10 条
        compacted = openrouter_proxy.compact_chat_messages(raw_body, max_history=10)
        data = json.loads(compacted.decode("utf-8"))
        
        # 检查是否成功压缩
        self.assertTrue(len(data["messages"]) < len(msgs))
        # 检查首条仍为 system
        self.assertEqual(data["messages"][0]["role"], "system")
        self.assertEqual(data["messages"][0]["content"], "You are a helpful assistant.")
        # 检查是否包含压缩通知
        self.assertIn("上下文智能保护", data["messages"][1]["content"])
        # 检查最新一条仍是最后一条
        self.assertEqual(data["messages"][-1]["content"], "msg 19")

    def test_state_exclude_rules(self):
        # 确保关键无用缓存和大体积归档被成功匹配排除
        test_paths = [
            ".openclaw/cache/feishu-plugin/index.js",
            ".openclaw/.cache/downloads/test.dat",
            ".openclaw/workspace/skills/test.tgz",
            ".openclaw/logs/run.log",
            ".openclaw/legacy-identity-backup/device.json",
            ".openclaw/config.bak",
            ".openclaw/tmp/session.tmp",
            ".openclaw/.npm/_cacache/content-v2",
        ]
        for p in test_paths:
            self.assertTrue(hf_state_store.is_excluded(p), f"Path should be excluded: {p}")

        # 确保核心用户数据绝对不被排除
        keep_paths = [
            ".openclaw/openclaw.json",
            ".openclaw/gateway.db",
            ".openclaw/workspace/skills/xiaohongshu-copywriting/SKILL.md",
            ".openclaw/state/agents/main/sessions/sessions.json",
        ]
        for p in keep_paths:
            self.assertFalse(hf_state_store.is_excluded(p), f"Path should be KEPT: {p}")

if __name__ == "__main__":
    unittest.main()
