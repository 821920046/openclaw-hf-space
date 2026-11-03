#!/usr/bin/env python3
import unittest
import os
import sys
from pathlib import Path

# 将 docker 目录加入 path
sys.path.insert(0, str(Path(__file__).parent.parent / "docker"))
import openrouter_proxy

class TestOptimizationFeatures(unittest.TestCase):
    def test_proxy_health_and_keys(self):
        self.assertTrue(len(openrouter_proxy.KEYS) >= 1)
        next_key = openrouter_proxy.get_next_healthy_key()
        self.assertIsNotNone(next_key)

    def test_proxy_unhealthy_marking(self):
        key = openrouter_proxy.KEYS[0]
        openrouter_proxy.mark_key_unhealthy(key, "upstream_overload_503", cooldown=5)
        self.assertFalse(openrouter_proxy.key_status[key]["healthy"])
        # 重置回健康状态
        openrouter_proxy.key_status[key]["healthy"] = True

    def test_security_guard_script_syntax(self):
        script_path = Path(__file__).parent.parent / "docker" / "security-guard.sh"
        self.assertTrue(script_path.exists())
        content = script_path.read_text(encoding="utf-8")
        self.assertIn("node", content)
        self.assertIn("gateway", content)
        self.assertIn("[SECURITY GUARD]", content)

if __name__ == "__main__":
    unittest.main()
