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
# Request the full management scope set: Hydra narrows to the scopes actually
# granted to this service account, and the API narrows again to its stored
# grant. Without an explicit scope, client_credentials yields a scopeless token
# and every request 401s. KONTEXT_SCOPES overrides if a narrower token is wanted.
SCOPES="${KONTEXT_SCOPES:-management:providers:read management:providers:write management:applications:read management:applications:write management:policy:read management:policy:write management:directory:read management:directory:write management:settings:read management:settings:write management:logs:read management:logs:write management:deployments:read management:deployments:write}"

# Authentication is either interactive device flow (default) or, when a
# service-account secret is present, client credentials (CI / headless).
fetch_token_client_credentials() {
  mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR"
  local resp expires_in
  resp=$(curl -sS --fail-with-body -X POST "$BASE/oauth2/token" \
    -u "$KONTEXT_CLIENT_ID:$KONTEXT_CLIENT_SECRET" \
    -H "Content-Type: application/x-www-form-urlencoded" -H "Accept: application/json" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "audience=$BASE/api/v1" \
    --data-urlencode "scope=$SCOPES")
  expires_in=$(printf '%s' "$resp" | jq -r '.expires_in // 300')
  umask 177
  printf '{"access_token":%s,"expires_at":%s}\n' \
    "$(printf '%s' "$resp" | jq '.access_token')" \
    "$(( $(date +%s) + expires_in - 30 ))" > "$TOKEN_FILE"
}

get_token() {
  if [ -f "$TOKEN_FILE" ] && [ "$(jq -r '.expires_at' "$TOKEN_FILE" 2>/dev/null || echo 0)" -gt "$(date +%s)" ]; then
    jq -r '.access_token' "$TOKEN_FILE"
    return
  fi
  if [ -n "${KONTEXT_CLIENT_ID:-}" ] && [ -n "${KONTEXT_CLIENT_SECRET:-}" ]; then
    fetch_token_client_credentials              # CI / headless fallback
  else
    "$(dirname "$0")/kontext-connect.sh" >&2    # interactive device flow (default)
  fi
  jq -r '.access_token' "$TOKEN_FILE"
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
