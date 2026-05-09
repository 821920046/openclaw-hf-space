#!/usr/bin/env python3
import http.server
import socketserver
import requests
import os
import itertools
import json

PORT = 18780

# Retrieve keys from environment
keys_env = os.environ.get("OPENROUTER_API_KEYS", "")
if not keys_env:
    keys_env = os.environ.get("OPENROUTER_API_KEY", "")
KEYS = [k.strip() for k in keys_env.split(",") if k.strip()]

if not KEYS:
    print("[Proxy] Warning: No OpenRouter API keys found. Proxy will fail.")
    KEYS = ["invalid_key"]

key_cycle = itertools.cycle(KEYS)

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def proxy_request(self, method):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length) if content_length > 0 else None
        
        # OpenClaw sends request to http://127.0.0.1:18791/api/v1/...
        # We forward it to https://openrouter.ai/api/v1/...
        url = "https://openrouter.ai" + self.path
        
        headers = {}
        for k, v in self.headers.items():
            if k.lower() not in ['host', 'authorization', 'connection', 'content-length', 'accept-encoding']:
                headers[k] = v
                
        max_retries = len(KEYS)
        for attempt in range(max_retries):
            key = next(key_cycle)
            headers['Authorization'] = f"Bearer {key}"
            
            try:
                with requests.request(method, url, data=body, headers=headers, stream=True) as r:
                    if r.status_code == 429:
                        print(f"[Proxy] Key {key[:8]}... hit 429 on {method}. Trying next key...")
                        continue
                        
                    self.send_response(r.status_code)
                    for k, v in r.headers.items():
                        if k.lower() not in ['transfer-encoding', 'content-encoding', 'connection']:
                            self.send_header(k, v)
                    self.end_headers()
                    
                    # Stream the response back to OpenClaw
                    for chunk in r.iter_content(chunk_size=4096):
                        if chunk:
                            try:
                                self.wfile.write(chunk)
                                self.wfile.flush()
                            except (BrokenPipeError, ConnectionResetError):
                                break # Client (OpenClaw) closed connection early
                    return # Success
            except requests.exceptions.RequestException as e:
                self.send_response(502)
                self.end_headers()
                self.wfile.write(str(e).encode('utf-8'))
                return

        # If we exhausted all keys and still got 429
        self.send_response(429)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        error_msg = json.dumps({"error": {"message": "All configured OpenRouter API keys are currently rate limited. Please wait and try again later."}})
        self.wfile.write(error_msg.encode('utf-8'))

    def do_POST(self):
        self.proxy_request("POST")
        
    def do_GET(self):
        self.proxy_request("GET")
        
    def do_OPTIONS(self):
        self.proxy_request("OPTIONS")

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), ProxyHandler) as httpd:
    print(f"[Proxy] OpenRouter Load Balancer Proxy listening on 127.0.0.1:{PORT} with {len(KEYS)} keys.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
