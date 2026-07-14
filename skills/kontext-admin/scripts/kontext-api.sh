#!/usr/bin/env bash
# kontext-api.sh — authenticated requests against the Kontext management API.
# Usage: kontext-api.sh METHOD PATH [JSON_BODY]
#   kontext-api.sh GET  /api/v1/policy/settings
#   kontext-api.sh POST /api/v1/organizations/current/install-tokens '{"label":"ci"}'
# Requires: KONTEXT_CLIENT_ID, KONTEXT_CLIENT_SECRET. Optional: KONTEXT_API_BASE.
set -euo pipefail

BASE="${KONTEXT_API_BASE:-https://api.kontext.security}"
UA="kontext-skill/0.1.0"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/kontext-skill"
TOKEN_FILE="$CACHE_DIR/token.json"

: "${KONTEXT_CLIENT_ID:?KONTEXT_CLIENT_ID is required}"
: "${KONTEXT_CLIENT_SECRET:?KONTEXT_CLIENT_SECRET is required}"

fetch_token() {
  mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR"
  local resp expires_in
  resp=$(curl -sS --fail-with-body -X POST "$BASE/oauth2/token" \
    -u "$KONTEXT_CLIENT_ID:$KONTEXT_CLIENT_SECRET" \
    -H "Content-Type: application/x-www-form-urlencoded" -H "Accept: application/json" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "audience=$BASE/api/v1")
  expires_in=$(printf '%s' "$resp" | jq -r '.expires_in // 300')
  umask 177
  printf '{"access_token":%s,"expires_at":%s}\n' \
    "$(printf '%s' "$resp" | jq '.access_token')" \
    "$(( $(date +%s) + expires_in - 30 ))" > "$TOKEN_FILE"
}

get_token() {
  if [ -f "$TOKEN_FILE" ] && [ "$(jq -r '.expires_at' "$TOKEN_FILE" 2>/dev/null || echo 0)" -gt "$(date +%s)" ]; then
    jq -r '.access_token' "$TOKEN_FILE"
  else
    fetch_token && jq -r '.access_token' "$TOKEN_FILE"
  fi
}

METHOD="${1:?usage: kontext-api.sh METHOD PATH [JSON_BODY]}"
API_PATH="${2:?usage: kontext-api.sh METHOD PATH [JSON_BODY]}"
BODY="${3:-}"

run() {
  local token args
  token=$(get_token)
  args=(-sS -X "$METHOD" "$BASE$API_PATH"
    -H "Authorization: Bearer $token" -H "Accept: application/json" -H "User-Agent: $UA"
    -w '\n%{http_code}')
  [ -n "$BODY" ] && args+=(-H "Content-Type: application/json" --data "$BODY")
  curl "${args[@]}"
}

OUT=$(run)
STATUS=$(printf '%s' "$OUT" | tail -1)
PAYLOAD=$(printf '%s' "$OUT" | sed '$d')

if [ "$STATUS" = "401" ]; then # stale token: refetch once, retry (safe for any method: request was rejected)
  rm -f "$TOKEN_FILE"
  OUT=$(run); STATUS=$(printf '%s' "$OUT" | tail -1); PAYLOAD=$(printf '%s' "$OUT" | sed '$d')
fi

printf '%s\n' "$PAYLOAD"
case "$STATUS" in 2*) exit 0;; *) echo "HTTP $STATUS" >&2; exit 1;; esac
