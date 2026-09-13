#!/usr/bin/env python3
"""Run with python3: checks conditional writes against a local HTTP server."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

requests = []
identities = []
token_requests = []
families = ["providers", "applications", "policy", "directory", "settings", "logs", "deployments"]
default_scopes = " ".join(f"management:{family}:{action}" for family in families for action in ["read", "write"])

def token_path(cache, base, client="kontext-cli", scopes=default_scopes):
    key = hashlib.sha256(f"{base}|{client}|{scopes}".encode()).hexdigest()[:16]
    return cache / f"token-{key}.json"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        identities.append(self.headers.get("Authorization"))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{}')

    def do_POST(self):
        if self.path == "/oauth2/token":
            payload = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
            token_requests.append((self.headers.get("Authorization"), payload))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({"access_token": f"issued-{len(token_requests)}", "expires_in": 300}).encode())
            return

        requests.append((self.path, self.headers.get("If-Match")))
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        status = 403 if self.path == "/forbidden" else 422 if self.path.endswith("/invalid") else 412 if self.headers.get("If-Match") == '"stale"' else 200
        self.send_response(status)
        self.send_header("ETag", '"deployment-2"' if status == 200 else 'W/"error-response"')
        self.end_headers()
        self.wfile.write(json.dumps({"error": "insufficient_scope", "missingScopes": ["management:policy:write"], "hint": "Enable it under Settings → Agent access."} if status == 403 else {"message": "done"}).encode())

    def log_message(self, *_):
        pass

with tempfile.TemporaryDirectory() as directory:
    cache = Path(directory) / "kontext-skill"
    cache.mkdir()
    (cache / "token.json").write_text(json.dumps({"access_token": "legacy-must-not-be-used", "expires_at": 9999999999}))
    headers = Path(directory) / "headers"
    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = {**os.environ, "XDG_CACHE_HOME": directory, "KONTEXT_API_BASE": f"http://127.0.0.1:{server.server_port}", "KONTEXT_RESPONSE_HEADERS": str(headers)}
    script = Path(__file__).with_name("kontext-api.sh")
    token_path(cache, env["KONTEXT_API_BASE"]).write_text(json.dumps({"access_token": "local-test", "expires_at": 9999999999}))
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
        before = len(requests)
        result = subprocess.run(["bash", str(script), "POST", "/forbidden", '{}'], env=env, capture_output=True, text=True)
        assert result.returncode == 1 and "HTTP 403" in result.stderr
        assert json.loads(result.stdout)["missingScopes"] == ["management:policy:write"]
        assert json.loads(result.stdout)["hint"] == "Enable it under Settings → Agent access."
        assert len(requests) == before + 1, "Insufficient scope must not be retried"

        def get(context):
            result = subprocess.run(["bash", str(script), "GET", "/api/v1/policy"], env=context, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            return identities[-1]

        assert get(env) == "Bearer local-test"
        contexts = [
            {**env, "KONTEXT_CLIENT_ID": "alpha", "KONTEXT_CLIENT_SECRET": "alpha-secret"},
            {**env, "KONTEXT_CLIENT_ID": "bravo", "KONTEXT_CLIENT_SECRET": "bravo-secret"},
            {**env, "KONTEXT_CLIENT_ID": "alpha", "KONTEXT_CLIENT_SECRET": "alpha-secret", "KONTEXT_SCOPES": "management:policy:read"},
            {**env, "KONTEXT_CLIENT_ID": "alpha", "KONTEXT_CLIENT_SECRET": "alpha-secret", "KONTEXT_API_BASE": env["KONTEXT_API_BASE"].replace("127.0.0.1", "localhost")},
        ]
        for index, context in enumerate(contexts, 1):
            assert get(context) == f"Bearer issued-{index}"
            assert get(context) == f"Bearer issued-{index}", "Same context must reuse its token"
            assert len(token_requests) == index, "Each new context needs exactly one token"
            path = token_path(cache, context["KONTEXT_API_BASE"], context["KONTEXT_CLIENT_ID"], context.get("KONTEXT_SCOPES", default_scopes))
            assert path.stat().st_mode & 0o077 == 0
        from urllib.parse import parse_qs
        assert parse_qs(token_requests[0][1])["scope"] == [default_scopes]
        assert parse_qs(token_requests[2][1])["scope"] == ["management:policy:read"]
        assert get(env) == "Bearer local-test", "Service account auth must not overwrite the interactive cache"
        print("Conditional writes, 403 stop, private headers, 14 scopes, and identity/base/scope cache isolation passed")
    finally:
        server.shutdown()
