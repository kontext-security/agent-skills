#!/usr/bin/env bash
# kontext-connect.sh — connect this agent to Kontext.
#
# Primary: OAuth 2.0 authorization code + PKCE with a loopback callback
# (http://127.0.0.1:8976/callback). Zero typing: the browser opens, the human
# clicks Allow, the token lands here. Works on every deployment.
#
# Fallback: OAuth 2.0 device flow (RFC 8628) — set KONTEXT_CONNECT_FLOW=device.
# Useful over SSH (approve on another machine), but requires a deployment
# whose OAuth server enables the device grant (dev/self-hosted Hydra).
#
# No secret is ever entered or displayed.
# Optional env: KONTEXT_API_BASE (default https://api.kontext.security),
# KONTEXT_SCOPES, KONTEXT_CONNECT_FLOW=pkce|device, KONTEXT_CONNECT_TIMEOUT
# (seconds to wait for browser approval, default 900).
set -euo pipefail

# This script always connects the human through the built-in public client.
unset KONTEXT_CLIENT_ID KONTEXT_CLIENT_SECRET
source "$(dirname "$0")/kontext-context.sh"

CLIENT_ID="$IDENTITY"
UA="kontext-skill/0.9.1"
CALLBACK_PORT=8976
FLOW="${KONTEXT_CONNECT_FLOW:-pkce}"
# Approval often goes through a relayed URL or a second device, so wait long.
TIMEOUT="${KONTEXT_CONNECT_TIMEOUT:-900}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=0 ;; *) TIMEOUT=$((10#$TIMEOUT)) ;; esac
[ "$TIMEOUT" -gt 0 ] || { echo "kontext-connect: KONTEXT_CONNECT_TIMEOUT must be a positive number of seconds" >&2; exit 1; }

command -v jq >/dev/null || { echo "kontext-connect: jq is required" >&2; exit 1; }

save_token() { # $1 = token endpoint JSON response
  local access_token expires_in
  access_token=$(printf '%s' "$1" | jq -r '.access_token // empty')
  [ -z "$access_token" ] && { echo "kontext-connect: no token in response: $1" >&2; exit 1; }
  expires_in=$(printf '%s' "$1" | jq -r '.expires_in // 300')
  mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR"
  umask 177
  printf '{"access_token":%s,"expires_at":%s}\n' \
    "$(printf '%s' "$1" | jq '.access_token')" \
    "$(( $(date +%s) + expires_in - 30 ))" > "$TOKEN_FILE"
  echo "  Connected. You can run Kontext commands now."
}

wait_label() { # $1 = seconds
  local n=$1 unit=second
  [ $((n % 60)) -eq 0 ] && { n=$((n / 60)); unit=minute; }
  [ "$n" -eq 1 ] && echo "1 $unit" || echo "$n ${unit}s"
}

open_url() { # best effort; caller prints the URL either way
  local c
  for c in open xdg-open; do
    command -v "$c" >/dev/null && { "$c" "$1" >/dev/null 2>&1 || true; return; }
  done
}

# ---------------------------------------------------------------- PKCE flow
# The loopback listener runs as a detached worker in its own session, so it
# outlives this command: agent harnesses often stop a long-running command
# (timeout, cancel) while the human is still approving, and a stopped listener
# turns the Allow click into "127.0.0.1 refused to connect". The pending
# sign-in (verifier, state, deadline) lives in a private directory until it
# completes or expires, so a rerun inside the window reuses the same link, and
# reloading a refused callback page delivers the code once a listener is back.
PENDING="${TOKEN_FILE%.json}.pkce"
REDIRECT_URI="http://127.0.0.1:$CALLBACK_PORT/callback"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

pending_get() { cat "$PENDING/$1" 2>/dev/null || true; }

proc_start() { ps -o lstart= -p "$1" 2>/dev/null || true; }

worker_alive() { # the recorded worker, by PID and start time (PIDs get reused); not a zombie
  local pid stat; pid=$(pending_get pid)
  [ -n "$pid" ] && stat=$(ps -o stat= -p "$pid" 2>/dev/null) && [ -n "$stat" ] && [ "${stat#Z}" = "$stat" ] &&
    [ "$(proc_start "$pid")" = "$(pending_get pid_start)" ]
}

# Every change to $PENDING (create, resume, restart, discard) happens under one
# short-lived lock; waiting for the human happens outside it. The lock is a
# symlink naming its creation time and holder, created atomically; a lock whose
# holder is gone or that is older than a minute is broken.
LOCK="$PENDING.lock"
LOCKED=""
lock_pending() {
  local i info now
  for i in $(seq 450); do
    if ln -s "$(date +%s) $$" "$LOCK" 2>/dev/null; then LOCKED=1; return 0; fi
    if info=$(readlink "$LOCK" 2>/dev/null); then
      now=$(date +%s)
      if [ $(( now - ${info%% *} )) -gt 60 ] || ! kill -0 "${info##* }" 2>/dev/null; then
        [ "$(readlink "$LOCK" 2>/dev/null)" != "$info" ] || rm -f "$LOCK"
      fi
    fi
    sleep 0.2
  done
  echo "kontext-connect: another sign-in is still starting; run connect again." >&2; exit 1
}
unlock_pending() { [ -z "$LOCKED" ] || rm -f "$LOCK"; LOCKED=""; }

stop_worker() { # let a worker that is exchanging a code finish, then stop it
  local i
  for i in $(seq 75); do worker_alive && [ ! -f "$PENDING/result" ] || break; sleep 0.2; done
  ! worker_alive || kill -TERM -- "-$(pending_get pid)" 2>/dev/null || true
  for i in $(seq 25); do worker_alive || break; sleep 0.2; done
}

release_other_approvals() { # one loopback port: a new sign-in replaces any other one still waiting
  local own=$PENDING p i
  for p in "$CACHE_DIR"/token-*.pkce; do
    [ -d "$p" ] && [ "$p" != "$own" ] || continue
    PENDING=$p
    if worker_alive && [ ! -f "$PENDING/result" ]; then
      kill -TERM -- "-$(pending_get pid)" 2>/dev/null || true
      for i in $(seq 25); do worker_alive || break; sleep 0.2; done
      rm -rf "$PENDING"
      echo "kontext-connect: replaced an earlier sign-in that was still waiting; its link no longer works." >&2
    fi
  done
  PENDING=$own
}

token_valid() {
  [ -f "$TOKEN_FILE" ] && [ "$(jq -r '.expires_at' "$TOKEN_FILE" 2>/dev/null || echo 0)" -gt "$(date +%s)" ]
}

pkce_worker() { # runs detached; writes exactly one line to $PENDING/result
  local state verifier remaining cb err code tok terr out
  proc_start "$$" > "$PENDING/pid_start" # identity first: pid is read as "alive"
  printf '%s\n' "$$" > "$PENDING/pid"
  state=$(pending_get state); verifier=$(pending_get verifier)
  finish() { # only into its own approval, never one that replaced it
    [ "$(pending_get state)" = "$state" ] || exit 0
    printf '%s\n' "$1" > "$PENDING/result.tmp" && mv -f "$PENDING/result.tmp" "$PENDING/result"; rm -f "$PENDING/verifier"; exit 0
  }
  [ -n "$state" ] && [ -n "$verifier" ] || finish "error: the pending sign-in is incomplete. Run connect again."
  remaining=$(( $(pending_get deadline) - $(date +%s) ))
  [ "$remaining" -gt 0 ] || finish timeout
  # Waits for the /callback hit carrying this sign-in's state (stale tabs get
  # a notice and are ignored), prints its params as JSON, exits on timeout.
  cb=$(node -e '
    const http = require("http"), fs = require("fs");
    const [port, seconds, expected, ready] = [Number(process.argv[1]), Number(process.argv[2]), process.argv[3], process.argv[4]];
    const page = (title, text) => `<html><body style="font-family:sans-serif;padding:2rem"><h3>${title}</h3><p>${text}</p></body></html>`;
    const srv = http.createServer((req, res) => {
      const u = new URL(req.url, `http://127.0.0.1:${port}`);
      if (u.pathname !== "/callback") { res.writeHead(404); res.end(); return; }
      if (u.searchParams.get("state") !== expected) {
        res.writeHead(400, { "Content-Type": "text/html" });
        res.end(page("Kontext: this approval link is out of date.", "Use the latest link your agent printed."));
        return;
      }
      const error = u.searchParams.get("error");
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(error ? page("Kontext: not connected.", "Return to your agent for details.") : page("Kontext: connected.", "You can close this tab and return to your agent."));
      console.log(JSON.stringify({ code: u.searchParams.get("code"), error, error_description: u.searchParams.get("error_description") }));
      srv.close(() => process.exit(0));
    });
    srv.on("error", (e) => { console.log(JSON.stringify({ error: "listener", error_description: String(e.message) })); process.exit(1); });
    srv.listen(port, "127.0.0.1", () => fs.writeFileSync(ready, ""));
    setTimeout(() => { console.log(JSON.stringify({ error: "timeout" })); process.exit(1); }, seconds * 1000);
  ' "$CALLBACK_PORT" "$remaining" "$state" "$PENDING/ready") || true
  err=$(printf '%s' "$cb" | jq -r '.error // empty' 2>/dev/null || echo listener)
  [ "$err" = "timeout" ] && finish timeout
  [ -n "$err" ] && finish "$err: $(printf '%s' "$cb" | jq -r '.error_description // empty' 2>/dev/null)"
  code=$(printf '%s' "$cb" | jq -r '.code // empty')
  [ -n "$code" ] || finish "error: no authorization code returned."
  tok=$(curl -sS -X POST "$BASE/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" -H "User-Agent: $UA" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$REDIRECT_URI" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "code_verifier=$verifier" 2>&1) || finish "error: token exchange failed: $tok"
  terr=$(printf '%s' "$tok" | jq -r '.error // empty' 2>/dev/null || true)
  [ -n "$terr" ] && finish "error: token exchange failed: $tok"
  out=$( (save_token "$tok") 2>&1) || finish "error: ${out#kontext-connect: }"
  # errexit is off inside `||`, so confirm the cache really holds the new token.
  [ "$(jq -r '.access_token // empty' "$TOKEN_FILE" 2>/dev/null || true)" = "$(printf '%s' "$tok" | jq -r '.access_token')" ] ||
    finish "error: could not write the token cache $TOKEN_FILE"
  finish ok
}

start_worker() { # detached (setsid via node), so stopping this command keeps it
  local i
  rm -f "$PENDING/pid" "$PENDING/pid_start" "$PENDING/ready"
  KONTEXT_PKCE_WORKER=1 node -e '
    require("child_process").spawn(process.argv[1], process.argv.slice(2), { detached: true, stdio: "ignore" }).unref();
  ' bash "$SELF"
  for i in $(seq 75); do # up to 15s for the listener to bind before the URL goes out
    [ -f "$PENDING/ready" ] || [ -f "$PENDING/result" ] && return 0
    sleep 0.2
  done
}

connect_pkce() {
  command -v node >/dev/null || { echo "kontext-connect: node is required for the browser flow (set KONTEXT_CONNECT_FLOW=device for the device-code flow)" >&2; exit 1; }
  command -v openssl >/dev/null || { echo "kontext-connect: openssl is required" >&2; exit 1; }
  trap unlock_pending EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR"

  lock_pending
  local reuse="" restarted=""
  if [ -d "$PENDING" ]; then
    if [ -f "$PENDING/result" ]; then
      # A previous run was stopped but its worker finished: report a success, retry anything else.
      if [ "$(pending_get result)" = "ok" ] && token_valid; then
        rm -rf "$PENDING"; unlock_pending
        echo "  Connected. You can run Kontext commands now."; return
      fi
    elif [ -f "$PENDING/url" ] && [ "$(pending_get deadline)" -gt "$(date +%s)" ] 2>/dev/null; then
      reuse=1
    fi
    if [ -z "$reuse" ]; then # finished, expired or never completed: discard it
      stop_worker
      rm -rf "$PENDING"
    fi
  fi

  if [ -z "$reuse" ]; then
    local verifier challenge state
    verifier=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
    challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=\n')
    state=$(openssl rand -hex 16)
    ( # url last: only a complete approval is ever resumed
      umask 077
      mkdir "$PENDING"
      printf '%s\n' "$verifier" > "$PENDING/verifier"
      printf '%s\n' "$state" > "$PENDING/state"
      printf '%s\n' "$(( $(date +%s) + TIMEOUT ))" > "$PENDING/deadline"
      printf '%s\n' "$BASE/oauth2/auth?client_id=$CLIENT_ID&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A$CALLBACK_PORT%2Fcallback&scope=${SCOPES// /%20}&state=$state&code_challenge=$challenge&code_challenge_method=S256" > "$PENDING/url"
    )
  fi
  if ! worker_alive && [ ! -f "$PENDING/result" ]; then
    [ -z "$reuse" ] || restarted=1
    release_other_approvals
    start_worker
  fi
  local result own_state auth_url remaining=$TIMEOUT
  result=$(pending_get result)
  own_state=$(pending_get state)
  auth_url=$(pending_get url)
  case "$result" in
    listener:*)
      rm -rf "$PENDING"; unlock_pending
      echo "kontext-connect: $result" >&2
      echo "kontext-connect: could not listen on 127.0.0.1:$CALLBACK_PORT (port in use?)" >&2; exit 1 ;;
  esac
  if [ -n "$reuse" ]; then # what is left, rounded up to whole minutes
    remaining=$(( $(pending_get deadline) - $(date +%s) ))
    [ "$remaining" -lt 60 ] || remaining=$(( (remaining + 59) / 60 * 60 ))
    [ "$remaining" -gt 0 ] || remaining=1
  fi
  unlock_pending

  # Relay this to the user verbatim; do not proceed silently.
  echo ""
  if [ -n "$reuse" ]; then
    echo "  A Kontext approval started earlier is still open. Approve access in your browser:"
    echo "  $auth_url"
    [ -z "$restarted" ] || echo "  If the browser showed \"127.0.0.1 refused to connect\" after Allow, reload that page."
    echo ""
  else
    echo "  To connect Kontext, approve access in your browser:"
    echo "  $auth_url"
    echo ""
    open_url "$auth_url"
  fi
  echo "  Waiting for approval (up to $(wait_label "$remaining"))…"

  # Poll in a child and block in `wait`, so a signal runs its trap at once
  # (bash can mis-parse a trap that fires while it runs a command substitution).
  await_approval & WAITER=$!
  trap 'kill "$WAITER" 2>/dev/null || true; unlock_pending' EXIT
  wait "$WAITER" || exit $?
}

await_approval() { # uses own_state and result from connect_pkce
  # A parallel run that shares this approval may read the result and clean up first.
  outcome() {
    [ "$(pending_get state)" = "$own_state" ] && result=$(pending_get result) || result=""
    [ -n "$result" ] || { [ "$(pending_get state)" != "$own_state" ] && token_valid && result=ok; }
  }
  while ! outcome; do
    if [ "$(pending_get state)" != "$own_state" ] || ! worker_alive; then
      sleep 0.3
      outcome && break
      echo "kontext-connect: the approval listener stopped unexpectedly. Run connect again to resume the same approval." >&2; exit 1
    fi
    sleep 0.2
  done
  lock_pending # discard only our own approval, never one that replaced it
  [ "$(pending_get state)" != "$own_state" ] || rm -rf "$PENDING"
  unlock_pending
  case "$result" in
    ok) echo "  Connected. You can run Kontext commands now." ;;
    timeout) echo "kontext-connect: no approval within $(wait_label "$TIMEOUT"); the approval link has stopped working. Run connect again for a new link." >&2; exit 1 ;;
    listener:*) echo "kontext-connect: $result" >&2; echo "kontext-connect: could not listen on 127.0.0.1:$CALLBACK_PORT (port in use?)" >&2; exit 1 ;;
    error:*) echo "kontext-connect: ${result#error: }" >&2; exit 1 ;;
    *) echo "kontext-connect: $result" >&2; exit 1 ;;
  esac
}

# -------------------------------------------------------------- Device flow
connect_device() {
  local resp
  resp=$(curl -sS --fail-with-body -X POST "$BASE/oauth2/device/auth" \
    -H "Content-Type: application/x-www-form-urlencoded" -H "User-Agent: $UA" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "scope=$SCOPES") || { echo "kontext-connect: device request failed: $resp" >&2; exit 1; }

  local device_code user_code verify verify_complete interval
  device_code=$(printf '%s' "$resp" | jq -r '.device_code')
  user_code=$(printf '%s' "$resp" | jq -r '.user_code')
  verify=$(printf '%s' "$resp" | jq -r '.verification_uri')
  verify_complete=$(printf '%s' "$resp" | jq -r '.verification_uri_complete // empty')
  interval=$(printf '%s' "$resp" | jq -r '.interval // 5')
  [ "$device_code" = "null" ] && { echo "kontext-connect: unexpected response: $resp" >&2; exit 1; }

  # Relay these to the user verbatim; do not proceed silently.
  local url="${verify_complete:-$verify}"
  echo ""
  echo "  To connect Kontext, open:  $url"
  echo "  and confirm the code:      $user_code"
  echo ""
  if [ -t 0 ]; then
    printf "  Open the browser now? [Y/n] "
    local ans; read -r ans || ans=""
    case "$ans" in [Nn]*) : ;; *) open_url "$url" ;; esac
  fi

  echo "  Waiting for approval…"
  while true; do
    sleep "$interval"
    local tok err
    tok=$(curl -sS -X POST "$BASE/oauth2/token" \
      -H "Content-Type: application/x-www-form-urlencoded" -H "User-Agent: $UA" \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      --data-urlencode "device_code=$device_code" \
      --data-urlencode "client_id=$CLIENT_ID")
    err=$(printf '%s' "$tok" | jq -r '.error // empty')
    case "$err" in
      authorization_pending) ;;                                  # keep waiting
      slow_down) interval=$((interval + 5)) ;;                    # back off
      "" ) save_token "$tok"; exit 0 ;;
      access_denied) echo "kontext-connect: the request was denied in the browser." >&2; exit 1 ;;
      expired_token) echo "kontext-connect: the code expired before approval — run connect again." >&2; exit 1 ;;
      *) echo "kontext-connect: $err" >&2; exit 1 ;;
    esac
  done
}

if [ -n "${KONTEXT_PKCE_WORKER:-}" ]; then
  pkce_worker
  exit 0
fi

case "$FLOW" in
  device) connect_device ;;
  *) connect_pkce ;;
esac
