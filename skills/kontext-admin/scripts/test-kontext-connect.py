#!/usr/bin/env python3
"""Run with python3: checks the PKCE sign-in against a local fake authorization server.

The loopback listener must outlive the command that started it (agent harnesses
stop long commands while the human is still approving), a rerun must reuse the
same approval, and a reloaded callback must still exchange with the original
code_verifier.
"""
import base64
import hashlib
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
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import urlopen

CALLBACK = "http://127.0.0.1:8976/callback"


class FakeAuthServer(BaseHTTPRequestHandler):
    """Token endpoint that enforces single-use codes and the S256 challenge."""
    codes = {}  # code -> code_challenge
    exchanges = []

    def do_POST(self):
        assert self.headers.get("User-Agent") == "kontext-skill/0.10.1"
        form = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        code, verifier = form["code"][0], form["code_verifier"][0]
        assert form["redirect_uri"] == [CALLBACK] and form["client_id"] == ["kontext-cli"]
        challenge = self.codes.pop(code, None)
        if code.startswith("slow"):
            time.sleep(2)  # an approved exchange still in flight
        digest = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        ok = challenge is not None and challenge == digest
        self.exchanges.append(ok)
        self.send_response(200 if ok else 400)
        self.end_headers()
        self.wfile.write(json.dumps({"access_token": f"token-{code}", "expires_in": 300} if ok else {"error": "invalid_grant"}).encode())

    def log_message(self, *_):
        pass


def port_free():
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)  # Ignore closed callbacks in TIME_WAIT.
        try:
            sock.bind(("127.0.0.1", 8976))
            return True
        except OSError:
            return False


def wait_port_free():
    for _ in range(50):
        if port_free():
            return
        time.sleep(0.1)
    raise AssertionError("Listener still holds 127.0.0.1:8976")


def approve(auth_url, code):
    """What the browser does after Allow: register the code, then hit the callback."""
    query = parse_qs(urlparse(auth_url).query)
    FakeAuthServer.codes[code] = query["code_challenge"][0]
    return f"{CALLBACK}?code={code}&state={query['state'][0]}"


def get(url):
    try:
        with urlopen(url, timeout=5) as response:
            return response.status
    except HTTPError as error:
        return error.code
    except URLError:
        return "refused"


assert port_free(), "Never interrupt another connection's listener."
script = Path(__file__).with_name("kontext-connect.sh")
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    opener = root / "open"
    opener.write_text("#!/bin/sh\nexit 0\n")
    opener.chmod(0o700)
    server = HTTPServer(("127.0.0.1", 0), FakeAuthServer)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {**{k: v for k, v in os.environ.items() if k != "KONTEXT_CONNECT_TIMEOUT"}, "PATH": directory + os.pathsep + os.environ["PATH"],
           "XDG_CACHE_HOME": directory, "KONTEXT_CONNECT_FLOW": "pkce", "KONTEXT_CLIENT_ID": "alpha", "KONTEXT_CLIENT_SECRET": "",
           "KONTEXT_API_BASE": f"http://127.0.0.1:{server.server_port}"}
    token_file = token_path(env)
    pending = token_file.with_suffix(".pkce")
    started = []

    def start(extra=None):
        log = (root / f"connect-{len(started)}.log").open("w+")
        process = subprocess.Popen(["bash", str(script)], env={**env, **(extra or {})}, stdout=log, stderr=log, start_new_session=True)
        started.append(process)
        return process, log

    def wait_for(process, log, text):
        for _ in range(200):
            log.seek(0)
            output = log.read()
            if text in output:
                return output
            assert process.poll() is None, output
            time.sleep(0.05)
        raise AssertionError(f"{text!r} never printed: {output}")

    def auth_url(output):
        return next(line.strip() for line in output.splitlines() if "response_type=code" in line)

    def finished(process, log, code=0):
        assert process.wait(timeout=10) == code, (log.seek(0), log.read())[1]
        log.seek(0)
        return log.read()

    def reset():
        token_file.unlink(missing_ok=True)
        wait_port_free()
        assert not pending.exists(), list(pending.iterdir())

    try:
        # 1. Plain success; the request carries the client and the 12 default scopes.
        process, log = start()
        url = auth_url(wait_for(process, log, "Waiting for approval (up to 15 minutes)"))
        query = parse_qs(urlparse(url).query)
        assert query["client_id"] == ["kontext-cli"], "ID without secret must stay PKCE"
        expected = {f"management:{family}:{action}" for family in ["providers", "applications", "policy", "directory", "settings", "logs", "deployments"] for action in (["read"] if family in ["providers", "applications"] else ["read", "write"])}
        assert set(query["scope"][0].split()) == expected and len(query["scope"][0].split()) == 12
        assert get(f"{CALLBACK}?code=x&state=stale") == 400, "a stale tab must not end the sign-in"
        assert get(approve(url, "plain")) == 200
        assert "Connected." in finished(process, log)
        assert not (token_file.parent / "token.json").exists()
        assert json.loads(token_file.read_text())["access_token"] == "token-plain"
        assert token_file.stat().st_mode & 0o077 == 0
        reset()

        # 2. The reported bug: the harness kills the command (whole process group)
        # while the human approves. Allow must still land and save the token.
        process, log = start()
        url = auth_url(wait_for(process, log, "Waiting for approval"))
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        assert get(approve(url, "killed")) == 200, "listener died with its command"
        for _ in range(50):
            if token_file.exists():
                break
            time.sleep(0.1)
        assert json.loads(token_file.read_text())["access_token"] == "token-killed"
        process, log = start()  # a rerun just reports the finished approval
        assert "Connected." in finished(process, log) and "response_type" not in log.read()
        reset()

        # 3. INT/TERM/HUP keep their exit codes and leave the approval open;
        # the rerun shows the same link and finishes it.
        for interruption in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
            process, log = start()
            url = auth_url(wait_for(process, log, "Waiting for approval"))
            process.send_signal(interruption)
            assert process.wait(timeout=5) == 128 + interruption, (process.returncode, interruption, (log.seek(0), log.read()[-800:])[1])
            process, log = start()
            output = wait_for(process, log, "Waiting for approval (up to 15 minutes)")
            assert "still open" in output and auth_url(output) == url and "reload" not in output
            assert get(approve(url, f"sig{interruption}")) == 200
            assert "Connected." in finished(process, log)
            assert json.loads(token_file.read_text())["access_token"] == f"token-sig{interruption}"
            reset()

        # 4. Listener gone after Allow ("refused to connect"): a rerun brings it back
        # on the same verifier, and reloading the refused page completes the sign-in.
        process, log = start()
        url = auth_url(wait_for(process, log, "Waiting for approval"))
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        os.killpg(int((pending / "pid").read_text()), signal.SIGKILL)
        wait_port_free()
        callback = approve(url, "reloaded")
        assert get(callback) == "refused"
        process, log = start()
        output = wait_for(process, log, "Waiting for approval")
        assert auth_url(output) == url and "reload that page" in output, output
        assert get(callback) == 200
        assert "Connected." in finished(process, log)
        assert json.loads(token_file.read_text())["access_token"] == "token-reloaded"
        assert FakeAuthServer.exchanges[-1] is True
        reset()

        # 5. Two commands needing a token at once share one approval.
        first, first_log = start()
        second, second_log = start()
        url = auth_url(wait_for(first, first_log, "Waiting for approval"))
        assert auth_url(wait_for(second, second_log, "Waiting for approval")) == url
        assert get(approve(url, "shared")) == 200
        assert "Connected." in finished(first, first_log) and "Connected." in finished(second, second_log)
        reset()

        # 5b. Two reruns of an approval whose listener died restart exactly one listener.
        process, log = start()
        url = auth_url(wait_for(process, log, "Waiting for approval"))
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        os.killpg(int((pending / "pid").read_text()), signal.SIGKILL)
        wait_port_free()
        first, first_log = start()
        second, second_log = start()
        outputs = [wait_for(first, first_log, "Waiting for approval"), wait_for(second, second_log, "Waiting for approval")]
        assert all(auth_url(output) == url for output in outputs)
        assert sum("reload that page" in output for output in outputs) == 1, outputs
        assert get(approve(url, "restarted")) == 200
        assert "Connected." in finished(first, first_log) and "Connected." in finished(second, second_log)
        reset()

        # 5c. A token cache that cannot be written is an error, not "Connected."
        token_file.mkdir()
        process, log = start()
        assert get(approve(auth_url(wait_for(process, log, "Waiting for approval")), "unwritable")) == 200
        assert "could not write the token cache" in finished(process, log, 1)
        token_file.rmdir()
        reset()

        # 5d. After the window a rerun starts a new approval; the old link is dead.
        process, log = start({"KONTEXT_CONNECT_TIMEOUT": "2"})
        old_url = auth_url(wait_for(process, log, "Waiting for approval"))
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        time.sleep(2.5)
        process, log = start()
        url = auth_url(wait_for(process, log, "Waiting for approval (up to 15 minutes)"))
        assert url != old_url and "still open" not in log.read()
        assert get(approve(old_url, "expired")) == 400
        assert get(approve(url, "renewed")) == 200
        assert "Connected." in finished(process, log)
        reset()

        # 5e. Stale leftovers: an expired approval whose recorded PID now belongs to an
        # unrelated process (never signalled), and a lock whose holder is gone.
        bystander = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            pending.mkdir(mode=0o700)
            for name, value in {"state": "old", "verifier": "old", "deadline": "1", "url": "http://old",
                                "pid": str(bystander.pid), "pid_start": "not this process"}.items():
                (pending / name).write_text(value + "\n")
            dead = subprocess.Popen(["true"])
            dead.wait()
            os.symlink(f"{int(time.time())} {dead.pid}", str(token_file.parent / "pkce.lock"))
            process, log = start()
            url = auth_url(wait_for(process, log, "Waiting for approval (up to 15 minutes)"))
            assert bystander.poll() is None, "signalled a process that is not the worker"
            assert get(approve(url, "leftovers")) == 200
            assert "Connected." in finished(process, log)
            assert not os.path.lexists(str(token_file.parent / "pkce.lock"))
        finally:
            bystander.kill()
            bystander.wait()
        reset()

        # 6. Denied in the browser.
        process, log = start()
        state = parse_qs(urlparse(auth_url(wait_for(process, log, "Waiting for approval"))).query)["state"][0]
        assert get(f"{CALLBACK}?error=access_denied&error_description=denied&state={state}") == 200
        assert "access_denied: denied" in finished(process, log, 1)
        reset()

        # 7. Port held by something else.
        with socket.socket() as blocker:
            blocker.bind(("127.0.0.1", 8976))
            blocker.listen()
            process, log = start()
            assert "port in use?" in finished(process, log, 1)
        reset()

        # 7b. An approval left waiting for another API base (a different cache
        # entry) holds the port: a new sign-in replaces it instead of failing.
        other, other_log = start({"KONTEXT_API_BASE": "http://127.0.0.1:9"})
        old_url = auth_url(wait_for(other, other_log, "Waiting for approval"))
        os.killpg(other.pid, signal.SIGKILL)
        other.wait()
        assert not port_free(), "the earlier approval's listener should still be waiting"
        process, log = start()
        output = wait_for(process, log, "Waiting for approval (up to 15 minutes)")
        assert "replaced an earlier sign-in" in output and auth_url(output) != old_url, output
        assert get(approve(old_url, "stale")) == 400
        assert get(approve(auth_url(output), "replaced")) == 200
        assert "Connected." in finished(process, log)
        other_pending = token_path({**env, "KONTEXT_API_BASE": "http://127.0.0.1:9"}).with_suffix(".pkce")
        assert (other_pending / "result").read_text().strip() == "replaced"
        subprocess.run(["rm", "-rf", str(other_pending)])
        reset()

        # 7c. A sign-in for another cache entry whose callback already arrived is
        # exchanging its code: a new sign-in must let it finish.
        narrow = {"KONTEXT_SCOPES": "management:logs:read"}
        other, other_log = start(narrow)
        other_url = auth_url(wait_for(other, other_log, "Waiting for approval"))
        assert get(approve(other_url, "slow-exchange")) == 200
        process, log = start()
        output = wait_for(process, log, "Waiting for approval (up to 15 minutes)")
        assert "replaced" not in output, output
        assert "Connected." in finished(other, other_log)
        assert json.loads(token_path({**env, **narrow}).read_text())["access_token"] == "token-slow-exchange"
        assert get(approve(auth_url(output), "alongside")) == 200
        assert "Connected." in finished(process, log)
        token_path({**env, **narrow}).unlink()
        reset()

        # 8. Custom and invalid timeouts.
        process, log = start({"KONTEXT_CONNECT_TIMEOUT": "1"})
        output = finished(process, log, 1)
        assert "Waiting for approval (up to 1 second)" in output and "no approval within 1 second" in output, output
        reset()
        result = subprocess.run(["bash", str(script)], env={**env, "KONTEXT_CONNECT_TIMEOUT": "soon"}, capture_output=True, text=True, timeout=10)
        assert result.returncode == 1 and "must be a positive number of seconds" in result.stderr, result.stderr
        print("listener survives a killed command; reruns reuse the approval and its verifier; parallel runs and parallel restarts share one listener; unwritable cache fails; expired approval renews; stale PID and lock are safe; "
              "INT/TERM/HUP exit codes; denial, busy port, stale approval for another base replaced, in-flight exchange spared, 15 minute default and custom timeout")
    finally:
        for process in started:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        if (pending / "pid").exists():
            try:
                os.killpg(int((pending / "pid").read_text()), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass
        server.shutdown()
