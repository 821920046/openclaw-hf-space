#!/usr/bin/env python3
import os
import sys
import json
import glob
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs
try:
    from huggingface_hub import HfApi
except ImportError:
    HfApi = None

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import openrouter_models as orm
except ImportError:
    orm = None

PORT = 18792
SPACE_ID = os.environ.get("SPACE_ID", "suifenglexiaoyao/ClawBot")
HF_TOKEN = os.environ.get("HF_TOKEN", "")

# Variables exposed in the UI
EDITABLE_VARS = [
    "HF_TOKEN",
    "OPENCLAW_HF_STATE_REPO",
    "OPENCLAW_HF_STATE_SYNC_INTERVAL",
    "OPENCLAW_REWRITE_CONFIG_ON_BOOT",
    "OPENROUTER_API_KEYS",
    "OPENROUTER_MODELS_JSON",
    "MODAL_API_KEY",
    "MODAL_BASE_URL",
    "MODAL_MODELS_JSON",
    "MODELSCOPE_API_KEY",
    "MODELSCOPE_BASE_URL",
    "MODELSCOPE_MODELS_JSON",
    "FEISHU_APP_ID",
    "FEISHU_APP_SECRET",
    "FEISHU_ALLOW_FROM",
    "DASHSCOPE_API_KEY",
    "SILICONFLOW_API_KEY",
    "BASIC_AUTH_USER",
    "BASIC_AUTH_PASSWORD",
    "OPENCLAW_DEFAULT_MODEL"
]

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenClaw 移动控制台</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; background-color: #f9fafb; color: #1f2937; margin: 0; display: flex; flex-direction: column; height: 100vh; }
        .header { background: white; box-shadow: 0 1px 2px 0 rgba(0, 0, 0, 0.05); padding: 1rem; display: flex; justify-content: space-between; align-items: center; position: sticky; top: 0; z-index: 10; }
        .header h1 { font-size: 1.25rem; font-weight: 700; margin: 0; }
        .tabs { display: flex; gap: 1rem; }
        .tab-btn { background: none; border: none; padding: 0.25rem 0; cursor: pointer; font-weight: 500; color: #6b7280; border-bottom: 2px solid transparent; transition: all 0.2s; }
        .tab-btn.active { color: #2563eb; border-bottom-color: #2563eb; }
        .models-table { width: 100%; border-collapse: collapse; font-size: 0.8rem; background: white; border-radius: 0.5rem; overflow: hidden; box-shadow: 0 1px 2px 0 rgba(0, 0, 0, 0.05); }
        .models-table th { background: #f3f4f6; color: #374151; text-align: left; padding: 0.5rem 0.6rem; white-space: nowrap; }
        .models-table td { padding: 0.5rem 0.6rem; border-top: 1px solid #e5e7eb; vertical-align: top; }
        .models-table tr:hover td { background: #f9fafb; }
        .badge { display: inline-block; padding: 0.05rem 0.4rem; border-radius: 9999px; font-size: 0.7rem; font-weight: 600; margin-left: 0.3rem; }
        .badge-green { background: #d1fae5; color: #065f46; }
        .badge-yellow { background: #fef3c7; color: #92400e; }
        .badge-gray { background: #e5e7eb; color: #4b5563; }
        .badge-red { background: #fee2e2; color: #991b1b; }
        .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 0.72rem; word-break: break-all; }
        .view { flex: 1; display: flex; flex-direction: column; padding: 1rem; overflow: hidden; }
        .hidden { display: none !important; }
        .log-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }
        .log-status-wrap { display: flex; align-items: center; gap: 0.5rem; font-size: 0.875rem; color: #6b7280; }
        .status-dot { width: 0.5rem; height: 0.5rem; border-radius: 9999px; }
        .status-green { background-color: #10b981; }
        .status-red { background-color: #ef4444; }
        .log-container { flex: 1; background: #111827; color: #34d399; padding: 0.75rem; border-radius: 0.5rem; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; font-size: 0.75rem; overflow-y: auto; white-space: pre-wrap; word-break: break-all; box-shadow: inset 0 2px 4px 0 rgba(0, 0, 0, 0.06); }
        .env-view { overflow-y: auto; }
        .alert { background-color: #fffbeb; border-left: 4px solid #f59e0b; padding: 1rem; margin-bottom: 1rem; border-radius: 0.25rem; font-size: 0.875rem; color: #92400e; }
        .form-group { margin-bottom: 1rem; }
        .form-group label { display: block; font-size: 0.875rem; font-weight: 500; color: #374151; margin-bottom: 0.25rem; }
        .form-control { width: 100%; padding: 0.5rem; border: 1px solid #d1d5db; border-radius: 0.375rem; font-family: ui-monospace, SFMono-Regular, monospace; font-size: 0.875rem; box-sizing: border-box; }
        .form-control:focus { outline: none; border-color: #2563eb; ring: 2px #bfdbfe; }
        textarea.form-control { font-size: 0.75rem; resize: vertical; }
        .btn { display: inline-flex; align-items: center; justify-content: center; padding: 0.75rem 1rem; font-weight: 700; border-radius: 0.5rem; border: none; cursor: pointer; transition: background 0.2s; }
        .btn-primary { background-color: #2563eb; color: white; width: 100%; margin-top: 1rem; }
        .btn-primary:hover { background-color: #1d4ed8; }
        .btn-primary:disabled { opacity: 0.7; cursor: not-allowed; }
        .btn-secondary { background-color: #e5e7eb; color: #374151; font-size: 0.875rem; padding: 0.25rem 0.75rem; }
        .btn-secondary:hover { background-color: #d1d5db; }
        .spinner { border: 2px solid #f3f3f3; border-top: 2px solid #2563eb; border-radius: 50%; width: 1rem; height: 1rem; animation: spin 1s linear infinite; margin-right: 0.5rem; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div class="header">
        <h1>🤖 控制台</h1>
        <div class="tabs">
            <button onclick="switchTab('logs')" id="tab-logs" class="tab-btn active">运行日志</button>
            <button onclick="switchTab('env')" id="tab-env" class="tab-btn">变量设置</button>
            <button onclick="switchTab('models')" id="tab-models" class="tab-btn">免费模型</button>
        </div>
    </div>

    <!-- Logs View -->
    <div id="view-logs" class="view">
        <div class="log-header">
            <div class="log-status-wrap">
                <div id="log-status" class="status-dot status-green"></div> 实时刷新中
            </div>
            <button onclick="fetchLogs()" class="btn btn-secondary">手动刷新</button>
        </div>
        <div class="log-container" id="log-content">正在加载日志...</div>
    </div>

    <!-- Env View -->
    <div id="view-env" class="view env-view hidden">
        <div class="alert">
            ⚠️ <b>注意</b>：修改并保存后，Space 会立即自动重启。在此期间服务将暂时中断约 1-2 分钟。
        </div>
        <form id="env-form">
            <!-- Dynamically populated -->
        </form>
        <button type="button" onclick="saveEnv()" id="save-btn" class="btn btn-primary">
            保存并重启容器
        </button>
    </div>

    <!-- Free Models View -->
    <div id="view-models" class="view env-view hidden">
        <div class="log-header">
            <div class="log-status-wrap">
                <div id="models-status" class="status-dot status-green"></div> <span id="models-meta">加载中...</span>
            </div>
            <div>
                <button onclick="fetchFreeModels(false)" class="btn btn-secondary">手动刷新</button>
                <button onclick="fetchFreeModels(true)" class="btn btn-secondary" style="margin-left:0.5rem;">重新检测</button>
            </div>
        </div>
        <div class="alert" style="background-color:#eff6ff;border-left-color:#3b82f6;color:#1e40af;">
            📊 OpenRouter 免费模型 Top5，按<b>近 7 天全站调用量</b>降序（数据源：OpenRouter 公开目录 + 使用榜单，配置 Key 时自动探活）。
            已在下架日期内的模型不会出现在列表中；即将到期的会标黄。此列表会在容器启动时自动写入配置，重启后生效。
        </div>
        <div id="models-content">正在加载...</div>
    </div>

    <script>
        let logInterval;

        function switchTab(tab) {
            document.getElementById('view-logs').classList.toggle('hidden', tab !== 'logs');
            document.getElementById('view-env').classList.toggle('hidden', tab !== 'env');
            document.getElementById('view-models').classList.toggle('hidden', tab !== 'models');
            document.getElementById('tab-logs').classList.toggle('active', tab === 'logs');
            document.getElementById('tab-env').classList.toggle('active', tab === 'env');
            document.getElementById('tab-models').classList.toggle('active', tab === 'models');

            if (tab === 'logs') {
                fetchLogs();
                logInterval = setInterval(fetchLogs, 3000);
            } else {
                clearInterval(logInterval);
                if (tab === 'env') fetchEnv();
                if (tab === 'models') fetchFreeModels(false);
            }
        }

        function fmtNum(n) {
            if (n >= 1e9) return (n / 1e9).toFixed(1) + 'B';
            if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
            if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
            return String(n || 0);
        }

        async function fetchFreeModels(force) {
            const dot = document.getElementById('models-status');
            const meta = document.getElementById('models-meta');
            const box = document.getElementById('models-content');
            try {
                dot.className = 'status-dot status-green';
                meta.textContent = force ? '正在重新检测（约 10-30 秒）...' : '加载中...';
                box.textContent = '正在加载...';
                const res = await fetch('/admin/api/free-models' + (force ? '?refresh=1' : ''));
                const data = await res.json();
                if (data.error) { box.textContent = '检测失败：' + data.error; return; }
                const s = data.stats || {};
                meta.textContent = `检测于 ${(data.generated_at || '').replace('T', ' ').slice(0, 19)} UTC | 窗口 ${data.window_days} 天 | 免费 ${s.free_in_catalog} 个 → 候选 ${s.chat_candidates} 个${data.probed ? ' | 已探活 ' + s.probed + ' 个' : ' | 未配置 Key 跳过探活'}`;
                let html = '<table class="models-table"><tr><th>#</th><th>模型</th><th>近窗调用</th><th>token</th><th>上下文</th><th>能力</th><th>到期</th><th>探活</th></tr>';
                for (const m of (data.top || [])) {
                    const caps = [];
                    if (m.tools) caps.push('<span class="badge badge-green">工具</span>');
                    if (m.reasoning) caps.push('<span class="badge badge-gray">推理</span>');
                    if (m.multimodal_input) caps.push('<span class="badge badge-gray">多模态输入</span>');
                    let exp = '<span class="badge badge-gray">未公布</span>';
                    if (m.expires_in_days !== null && m.expires_in_days !== undefined) {
                        exp = m.expires_in_days <= 14
                            ? `<span class="badge badge-yellow">⚠ ${m.expires_in_days} 天后到期</span>`
                            : `<span class="badge badge-gray">${m.expires_in_days} 天</span>`;
                    }
                    const probe = m.probe === 'alive' ? '<span class="badge badge-green">✓ 可用</span>'
                        : m.probe === 'dead' ? '<span class="badge badge-red">✗ 不可用</span>'
                        : m.probe === 'unknown' ? '<span class="badge badge-yellow">⚠ 未确认</span>'
                        : '<span class="badge badge-gray">未探测</span>';
                    html += `<tr><td>${m.rank}</td><td class="mono">${m.id}</td><td>${fmtNum(m.requests)}</td><td>${fmtNum(m.tokens)}</td><td>${Math.round((m.context_length || 0) / 1024)}K</td><td>${caps.join('') || '-'}</td><td>${exp}</td><td>${probe}</td></tr>`;
                }
                html += '</table>';
                if (data.excluded && data.excluded.length) {
                    html += '<div style="margin-top:0.75rem;font-size:0.75rem;color:#6b7280;">已排除 ' + data.excluded.length + ' 个：' +
                        data.excluded.map(e => e.id + '（' + e.reason + '）').join('；') + '</div>';
                }
                box.innerHTML = html;
            } catch (e) {
                dot.className = 'status-dot status-red';
                meta.textContent = '加载失败';
                box.textContent = '网络请求失败：' + e;
            }
        }

        async function fetchLogs() {
            try {
                const res = await fetch('/admin/api/logs');
                const text = await res.text();
                const el = document.getElementById('log-content');
                
                const isAtBottom = el.scrollHeight - el.scrollTop <= el.clientHeight + 50;
                el.textContent = text || '暂无日志记录。';
                if (isAtBottom) el.scrollTop = el.scrollHeight;
                
                document.getElementById('log-status').className = 'status-dot status-green';
            } catch (e) {
                document.getElementById('log-status').className = 'status-dot status-red';
            }
        }

        async function fetchEnv() {
            try {
                const res = await fetch('/admin/api/env');
                const data = await res.json();
                const form = document.getElementById('env-form');
                form.innerHTML = '';
                
                for (const key of Object.keys(data)) {
                    const isLong = key.includes('JSON') || key.includes('KEYS') || key.includes('ALLOW_FROM');
                    const value = data[key] || '';
                    
                    let inputHtml = '';
                    if (isLong) {
                        inputHtml = `<textarea name="${key}" rows="3" class="form-control">${value}</textarea>`;
                    } else {
                        inputHtml = `<input type="text" name="${key}" value="${value}" class="form-control">`;
                    }
                    
                    form.innerHTML += `
                        <div class="form-group">
                            <label>${key}</label>
                            ${inputHtml}
                        </div>
                    `;
                }
            } catch (e) {
                alert('获取变量失败！');
            }
        }

        async function saveEnv() {
            if (!confirm('确定要保存并重启容器吗？这会导致服务中断 1-2 分钟。')) return;
            
            const btn = document.getElementById('save-btn');
            const originalText = btn.innerText;
            btn.innerHTML = '<div class="spinner"></div> 保存中...';
            btn.disabled = true;
            
            const formData = new FormData(document.getElementById('env-form'));
            const data = Object.fromEntries(formData.entries());
            
            try {
                const res = await fetch('/admin/api/env', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(data)
                });
                
                const result = await res.json();
                if (result.success) {
                    alert('✅ 保存成功！Space 即将重启，请等待两分钟后刷新页面。');
                } else {
                    alert('❌ 保存失败：' + result.error);
                }
            } catch (e) {
                alert('❌ 网络请求失败！');
            } finally {
                btn.innerText = originalText;
                btn.disabled = false;
            }
        }

        // Init
        switchTab('logs');
    </script>
</body>
</html>"""

class AdminHandler(BaseHTTPRequestHandler):
    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == '/admin' or path == '/admin/':
            self.send_response(200)
            self.send_header('Content-type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(HTML_TEMPLATE.encode('utf-8'))
            return

        if path == '/admin/api/logs':
            # Get latest log file in /tmp/openclaw/
            log_files = glob.glob('/tmp/openclaw/openclaw-*.log')
            if not log_files:
                self.send_response(200)
                self.send_header('Content-type', 'text/plain; charset=utf-8')
                self.end_headers()
                self.wfile.write(b"No log files found in /tmp/openclaw/.")
                return
            
            latest_file = max(log_files, key=os.path.getctime)
            try:
                # Read last ~200 lines
                with open(latest_file, 'rb') as f:
                    f.seek(0, 2)
                    size = f.tell()
                    # Roughly 150 bytes per line, let's read last 30KB
                    read_size = min(size, 30000)
                    f.seek(max(0, size - read_size))
                    lines = f.readlines()
                    last_lines = lines[-200:]
                    content = b''.join(last_lines)
            except Exception as e:
                content = f"Error reading log file: {str(e)}".encode('utf-8')
            
            self.send_response(200)
            self.send_header('Content-type', 'text/plain; charset=utf-8')
            self.end_headers()
            self.wfile.write(content)
            return

        if path == '/admin/api/env':
            env_data = {}
            for k in EDITABLE_VARS:
                env_data[k] = os.environ.get(k, "")
            self.send_json(env_data)
            return

        if path == '/admin/api/free-models':
            # OpenRouter 免费模型监测结果：10 分钟内直接返回缓存，?refresh=1 强制重新检测
            if not orm:
                self.send_json({"error": "openrouter_models module not available"}, status=500)
                return
            try:
                force = parse_qs(parsed.query).get('refresh', [''])[0] == '1'
                data = orm.get_cached_result(orm.DEFAULT_OUT, max_age=600, force=force)
                self.send_json(data)
            except Exception as e:
                self.send_json({"error": str(e)}, status=500)
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == '/admin/api/env':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8')
            try:
                data = json.loads(body)
                if not HfApi:
                    self.send_json({"success": False, "error": "huggingface_hub library is missing."})
                    return
                if not HF_TOKEN:
                    self.send_json({"success": False, "error": "HF_TOKEN is not set in environment."})
                    return
                
                api = HfApi(token=HF_TOKEN)
                for k, v in data.items():
                    if k in EDITABLE_VARS:
                        # Update secret
                        val = str(v).strip()
                        if val:
                            api.add_space_secret(repo_id=SPACE_ID, key=k, value=val)
                
                self.send_json({"success": True})
            except Exception as e:
                self.send_json({"success": False, "error": str(e)})
            return
            
        self.send_response(404)
        self.end_headers()

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == '__main__':
    server = ThreadedHTTPServer(('127.0.0.1', PORT), AdminHandler)
    print(f"Admin API listening on 127.0.0.1:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
