#!/usr/bin/env python3
"""Run with python3: checks real loopback cleanup and a local PKCE exchange."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
from test_helpers import token_path
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse
from urllib.request import urlopen


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.headers.get("User-Agent") == "kontext-skill/0.6.0"
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"access_token":"local-test","expires_in":300}')

    def log_message(self, *_):
        pass


def assert_port_free():
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)  # Ignore closed callbacks in TIME_WAIT.
        sock.bind(("127.0.0.1", 8976))


assert_port_free()  # Never interrupt another connection's listener.
script = Path(__file__).with_name("kontext-connect.sh")
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    scratch = root / "scratch"
    scratch.mkdir()
    opener = root / "open"
    opener.write_text("#!/bin/sh\nexit 0\n")
    opener.chmod(0o700)
    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
           "TMPDIR": str(scratch), "XDG_CACHE_HOME": directory,
           "KONTEXT_CONNECT_FLOW": "pkce", "KONTEXT_CLIENT_ID": "alpha", "KONTEXT_CLIENT_SECRET": "",
           "KONTEXT_API_BASE": f"http://127.0.0.1:{server.server_port}"}
    try:
        for interruption in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP, None]:
            with (root / "connect.log").open("w+") as log:
                process = subprocess.Popen(["bash", str(script)], env=env, stdout=log, stderr=log, start_new_session=True)
                try:
                    for _ in range(100):
                        log.seek(0)
                        output = log.read()
                        if "Waiting for approval" in output:
                            break
                        assert process.poll() is None, output
                        time.sleep(0.05)
                    else:
                        raise AssertionError("Listener did not start")
                    if interruption:
                        process.send_signal(interruption)
                    else:
                        auth_url = next(line.strip() for line in output.splitlines() if "response_type=code" in line)
                        query = parse_qs(urlparse(auth_url).query)
                        assert query["client_id"] == ["kontext-cli"], "ID without secret must stay PKCE"
                        scopes = query["scope"][0]
                        expected = {f"management:{family}:{action}" for family in ["providers", "applications", "policy", "directory", "settings", "logs", "deployments"] for action in (["read"] if family in ["providers", "applications"] else ["read", "write"])}
                        assert set(scopes.split()) == expected and len(scopes.split()) == 12
                        state = query["state"][0]
                        with urlopen(f"http://127.0.0.1:8976/callback?code=local-test&state={state}") as response:
                            assert response.status == 200
                    assert process.wait(timeout=5) == (128 + interruption if interruption else 0)
                    assert_port_free()
                    assert not list(scratch.iterdir()), "Callback temporary file leaked"
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
        token_file = token_path(env)
        assert not (token_file.parent / "token.json").exists()
        assert json.loads(token_file.read_text())["access_token"] == "local-test"
        assert token_file.stat().st_mode & 0o077 == 0
        print("INT/TERM/HUP release port and temporary file; successful PKCE still saves token")
    finally:
        server.shutdown()
