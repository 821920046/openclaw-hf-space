#!/usr/bin/env python3
import http.server
import socketserver
import subprocess
import os

PORT = 18790

class BackupHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/plain; charset=utf-8')
            self.end_headers()
            
            repo = os.environ.get("OPENCLAW_HF_STATE_REPO", "")
            if not repo:
                self.wfile.write(b"Error: OPENCLAW_HF_STATE_REPO is not set. State sync is disabled.\n")
                return

            self.wfile.write(b"Starting state backup to Hugging Face Hub...\n")
            self.wfile.write(b"Please wait, this may take a few seconds.\n\n")
            
            # Execute backup script synchronously
            cmd = [
                "python3", "/app/docker/hf-state-store.py", "save",
                "--home", os.environ.get("OPENCLAW_HOME", "/root/.openclaw"),
                "--repo-id", repo,
                "--repo-type", os.environ.get("OPENCLAW_HF_STATE_REPO_TYPE", "dataset"),
                "--archive-name", os.environ.get("OPENCLAW_HF_STATE_ARCHIVE_NAME", "openclaw-home.tgz"),
                "--metadata-name", os.environ.get("OPENCLAW_HF_STATE_METADATA_NAME", "openclaw-state.json"),
                "--reason", "manual_api"
            ]
            if os.environ.get("OPENCLAW_HF_STATE_PRIVATE", "1") == "1":
                cmd.append("--private")
            
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, check=True)
                self.wfile.write(b"=== Backup Completed Successfully ===\n\n")
                self.wfile.write(result.stdout.encode('utf-8'))
            except subprocess.CalledProcessError as e:
                self.wfile.write(b"=== Backup Failed ===\n\n")
                self.wfile.write(b"STDOUT:\n")
                self.wfile.write(e.stdout.encode('utf-8'))
                self.wfile.write(b"\nSTDERR:\n")
                self.wfile.write(e.stderr.encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

# Allow reuse address to prevent "Address already in use" errors on rapid restarts
socketserver.TCPServer.allow_reuse_address = True

with socketserver.TCPServer(("127.0.0.1", PORT), BackupHandler) as httpd:
    print(f"Backup API server listening on 127.0.0.1:{PORT}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
