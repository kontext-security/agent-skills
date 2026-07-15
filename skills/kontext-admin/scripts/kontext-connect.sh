#!/usr/bin/env bash
# kontext-connect.sh — connect this agent to Kontext via OAuth 2.0 device flow (RFC 8628).
# Prints a URL + code for the human to approve in their browser; polls for the token;
# caches it. No secret is ever entered or displayed. gh-style: offers to open the browser.
# Optional: KONTEXT_API_BASE (default https://api.kontext.security), KONTEXT_SCOPES.
set -euo pipefail

BASE="${KONTEXT_API_BASE:-https://api.kontext.security}"
CLIENT_ID="kontext-cli"
UA="kontext-skill/0.2.0"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/kontext-skill"
TOKEN_FILE="$CACHE_DIR/token.json"
SCOPES="${KONTEXT_SCOPES:-management:providers:read management:providers:write management:applications:read management:applications:write management:directory:read management:directory:write management:settings:read management:settings:write management:logs:read management:deployments:read management:deployments:write}"

command -v jq >/dev/null || { echo "kontext-connect: jq is required" >&2; exit 1; }

# 1. Device authorization request.
resp=$(curl -sS --fail-with-body -X POST "$BASE/oauth2/device/auth" \
  -H "Content-Type: application/x-www-form-urlencoded" -H "User-Agent: $UA" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "scope=$SCOPES") || { echo "kontext-connect: device request failed: $resp" >&2; exit 1; }

device_code=$(printf '%s' "$resp" | jq -r '.device_code')
user_code=$(printf '%s' "$resp" | jq -r '.user_code')
verify=$(printf '%s' "$resp" | jq -r '.verification_uri')
verify_complete=$(printf '%s' "$resp" | jq -r '.verification_uri_complete // empty')
interval=$(printf '%s' "$resp" | jq -r '.interval // 5')
[ "$device_code" = "null" ] && { echo "kontext-connect: unexpected response: $resp" >&2; exit 1; }

# 2. Tell the human. Relay these to the user verbatim; do not proceed silently.
url="${verify_complete:-$verify}"
echo ""
echo "  To connect Kontext, open:  $url"
echo "  and confirm the code:      $user_code"
echo ""

# gh-style: offer to open the browser when interactive.
opener=""
for c in open xdg-open; do command -v "$c" >/dev/null && { opener="$c"; break; }; done
if [ -n "$opener" ] && [ -t 0 ]; then
  printf "  Open the browser now? [Y/n] "
  read -r ans || ans=""
  case "$ans" in [Nn]*) : ;; *) "$opener" "$url" >/dev/null 2>&1 || true ;; esac
fi

# 3. Poll the token endpoint until approved (or the code expires).
echo "  Waiting for approval…"
mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR"
while true; do
  sleep "$interval"
  tok=$(curl -sS -X POST "$BASE/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" -H "User-Agent: $UA" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
    --data-urlencode "device_code=$device_code" \
    --data-urlencode "client_id=$CLIENT_ID")
  err=$(printf '%s' "$tok" | jq -r '.error // empty')
  case "$err" in
    authorization_pending) ;;                                  # keep waiting
    slow_down) interval=$((interval + 5)) ;;                    # back off
    "" )
      access_token=$(printf '%s' "$tok" | jq -r '.access_token // empty')
      [ -z "$access_token" ] && { echo "kontext-connect: no token in response: $tok" >&2; exit 1; }
      expires_in=$(printf '%s' "$tok" | jq -r '.expires_in // 300')
      umask 177
      printf '{"access_token":%s,"expires_at":%s}\n' \
        "$(printf '%s' "$tok" | jq '.access_token')" \
        "$(( $(date +%s) + expires_in - 30 ))" > "$TOKEN_FILE"
      echo "  Connected. You can run Kontext commands now."
      exit 0 ;;
    access_denied) echo "kontext-connect: the request was denied in the browser." >&2; exit 1 ;;
    expired_token) echo "kontext-connect: the code expired before approval — run connect again." >&2; exit 1 ;;
    *) echo "kontext-connect: $err" >&2; exit 1 ;;
  esac
done
