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
# KONTEXT_SCOPES, KONTEXT_CONNECT_FLOW=pkce|device.
set -euo pipefail

BASE="${KONTEXT_API_BASE:-https://api.kontext.security}"
CLIENT_ID="kontext-cli"
UA="kontext-skill/0.3.0"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/kontext-skill"
TOKEN_FILE="$CACHE_DIR/token.json"
CALLBACK_PORT=8976
SCOPES="${KONTEXT_SCOPES:-management:providers:read management:providers:write management:applications:read management:applications:write management:policy:read management:policy:write management:directory:read management:directory:write management:settings:read management:settings:write management:logs:read management:deployments:read management:deployments:write}"
FLOW="${KONTEXT_CONNECT_FLOW:-pkce}"

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

open_url() { # best effort; caller prints the URL either way
  local c
  for c in open xdg-open; do
    command -v "$c" >/dev/null && { "$c" "$1" >/dev/null 2>&1 || true; return; }
  done
}

# ---------------------------------------------------------------- PKCE flow
connect_pkce() {
  command -v node >/dev/null || { echo "kontext-connect: node is required for the browser flow (set KONTEXT_CONNECT_FLOW=device for the device-code flow)" >&2; exit 1; }
  command -v openssl >/dev/null || { echo "kontext-connect: openssl is required" >&2; exit 1; }

  local verifier challenge state
  verifier=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
  challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=\n')
  state=$(openssl rand -hex 16)

  # Loopback listener: waits for exactly one /callback hit, prints its params
  # as JSON, exits. 5 minute timeout.
  local result_file
  result_file=$(mktemp)
  node -e '
    const http = require("http");
    const port = Number(process.argv[1]);
    const srv = http.createServer((req, res) => {
      const u = new URL(req.url, `http://127.0.0.1:${port}`);
      if (u.pathname !== "/callback") { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end("<html><body style=\"font-family:sans-serif;padding:2rem\"><h3>Kontext: connected.</h3><p>You can close this tab and return to your agent.</p></body></html>");
      console.log(JSON.stringify({ code: u.searchParams.get("code"), state: u.searchParams.get("state"), error: u.searchParams.get("error"), error_description: u.searchParams.get("error_description") }));
      srv.close(() => process.exit(0));
    });
    srv.on("error", (e) => { console.log(JSON.stringify({ error: "listener", error_description: String(e.message) })); process.exit(1); });
    srv.listen(port, "127.0.0.1");
    setTimeout(() => { console.log(JSON.stringify({ error: "timeout" })); process.exit(1); }, 300000);
  ' "$CALLBACK_PORT" > "$result_file" &
  local listener_pid=$!
  sleep 0.3
  kill -0 "$listener_pid" 2>/dev/null || { cat "$result_file" >&2; echo "kontext-connect: could not listen on 127.0.0.1:$CALLBACK_PORT (port in use?)" >&2; exit 1; }

  local auth_url="$BASE/oauth2/auth?client_id=$CLIENT_ID&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A$CALLBACK_PORT%2Fcallback&scope=${SCOPES// /%20}&state=$state&code_challenge=$challenge&code_challenge_method=S256"

  # Relay this to the user verbatim; do not proceed silently.
  echo ""
  echo "  To connect Kontext, approve access in your browser:"
  echo "  $auth_url"
  echo ""
  open_url "$auth_url"
  echo "  Waiting for approval…"

  wait "$listener_pid" || true
  local cb code cb_state err
  cb=$(cat "$result_file"); rm -f "$result_file"
  err=$(printf '%s' "$cb" | jq -r '.error // empty')
  [ "$err" = "timeout" ] && { echo "kontext-connect: timed out waiting for browser approval — run connect again." >&2; exit 1; }
  [ -n "$err" ] && { echo "kontext-connect: $err: $(printf '%s' "$cb" | jq -r '.error_description // empty')" >&2; exit 1; }
  code=$(printf '%s' "$cb" | jq -r '.code // empty')
  cb_state=$(printf '%s' "$cb" | jq -r '.state // empty')
  [ "$cb_state" = "$state" ] || { echo "kontext-connect: state mismatch — aborting." >&2; exit 1; }
  [ -z "$code" ] && { echo "kontext-connect: no authorization code returned." >&2; exit 1; }

  local tok
  tok=$(curl -sS -X POST "$BASE/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" -H "User-Agent: $UA" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=http://127.0.0.1:$CALLBACK_PORT/callback" \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "code_verifier=$verifier")
  local terr
  terr=$(printf '%s' "$tok" | jq -r '.error // empty')
  [ -n "$terr" ] && { echo "kontext-connect: token exchange failed: $tok" >&2; exit 1; }
  save_token "$tok"
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

case "$FLOW" in
  device) connect_device ;;
  *) connect_pkce ;;
esac
