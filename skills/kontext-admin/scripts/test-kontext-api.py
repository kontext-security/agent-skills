#!/usr/bin/env python3
"""Run with python3: checks conditional writes against a local HTTP server."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

requests = []

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        requests.append((self.path, self.headers.get("If-Match")))
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        status = 422 if self.path.endswith("/invalid") else 412 if self.headers.get("If-Match") == '"stale"' else 200
        self.send_response(status)
        self.send_header("ETag", '"deployment-2"' if status == 200 else 'W/"error-response"')
        self.end_headers()
        self.wfile.write(b'{"message":"done"}')

    def log_message(self, *_):
        pass

with tempfile.TemporaryDirectory() as directory:
    cache = Path(directory) / "kontext-skill"
    cache.mkdir()
    (cache / "token.json").write_text(json.dumps({"access_token": "local-test", "expires_at": 9999999999}))
    headers = Path(directory) / "headers"
    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = {**os.environ, "XDG_CACHE_HOME": directory, "KONTEXT_API_BASE": f"http://127.0.0.1:{server.server_port}", "KONTEXT_RESPONSE_HEADERS": str(headers)}
    script = Path(__file__).with_name("kontext-api.sh")
    try:
        result = subprocess.run(["bash", str(script), "POST", "/api/v1/policy/actions", '{"action":"enforce","policyId":"test"}', '"deployment-1"'], env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert requests == [("/api/v1/policy/actions", '"deployment-1"')]
        assert 'ETag: "deployment-2"' in headers.read_text()
        assert headers.stat().st_mode & 0o077 == 0
        result = subprocess.run(["bash", str(script), "POST", "/api/v1/policy/actions", '{}', '"stale"'], env=env, capture_output=True, text=True)
        assert result.returncode == 1 and "HTTP 412" in result.stderr
        assert len(requests) == 2, "A stale write must not be retried"
        successful_headers = headers.read_text()
        assert 'ETag: "deployment-2"' in successful_headers
        result = subprocess.run(["bash", str(script), "POST", "/invalid", '{}', '"deployment-2"'], env=env, capture_output=True, text=True)
        assert result.returncode == 1 and "HTTP 422" in result.stderr
        assert headers.read_text() == successful_headers, "Errors must not replace the deployment ETag"
        etag = next(line.split(": ", 1)[1] for line in headers.read_text().splitlines() if line.lower().startswith("etag:"))
        result = subprocess.run(["bash", str(script), "POST", "/api/v1/policy/actions", '{}', etag], env=env, capture_output=True, text=True)
        assert result.returncode == 0 and requests[-1][1] == '\"deployment-2\"'
        headers.unlink()
        result = subprocess.run(["bash", str(script), "POST", "/invalid", '{}'], env=env, capture_output=True, text=True)
        assert result.returncode == 1 and not headers.exists(), "An initial error must not publish headers"
        assert not list(Path(directory).glob("headers.*")), "Temporary headers must be removed"
        print("Conditional writes, 422 recovery, private headers, and error cleanup passed")
    finally:
        server.shutdown()
