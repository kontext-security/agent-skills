#!/usr/bin/env bash
# kontext-api.sh — authenticated requests against the Kontext management API.
# Usage: kontext-api.sh METHOD PATH [JSON_BODY] [IF_MATCH]
#   kontext-api.sh GET  /api/v1/policy/settings
#   kontext-api.sh POST /api/v1/organizations/current/install-tokens '{"label":"ci"}'
# Auth: browser approval, or KONTEXT_CLIENT_ID + KONTEXT_CLIENT_SECRET for CI.
set -euo pipefail

source "$(dirname "$0")/kontext-context.sh"

UA="kontext-skill/0.5.0"
# Authentication is either interactive browser approval (default) or, when a
# service-account secret is present, client credentials (CI / headless).
fetch_token_client_credentials() {
  mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR"
  local resp expires_in
  resp=$(printf 'user = %s\n' "$(printf '%s' "$IDENTITY:$KONTEXT_CLIENT_SECRET" | jq -Rs .)" | \
    curl --config - -sS --fail-with-body -X POST "$BASE/oauth2/token" \
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
  if [ -n "${KONTEXT_CLIENT_SECRET:-}" ]; then
    fetch_token_client_credentials              # CI / headless fallback
  else
    "$(dirname "$0")/kontext-connect.sh" >&2    # interactive browser approval (default)
  fi
  jq -r '.access_token' "$TOKEN_FILE"
}

METHOD="${1:?usage: kontext-api.sh METHOD PATH [JSON_BODY] [IF_MATCH]}"
API_PATH="${2:?usage: kontext-api.sh METHOD PATH [JSON_BODY] [IF_MATCH]}"
BODY="${3:-}"
IF_MATCH="${4:-}"
# Optional private file for successful response headers, including the deployment ETag.
RESPONSE_HEADERS="${KONTEXT_RESPONSE_HEADERS:-}"
HEADERS_TMP=""
if [ -n "$RESPONSE_HEADERS" ]; then
  HEADERS_TMP=$(mktemp "${RESPONSE_HEADERS}.XXXXXX")
  trap 'rm -f "$HEADERS_TMP"' EXIT
fi

run() {
  local token args
  token=$(get_token)
  args=(-sS -X "$METHOD" "$BASE$API_PATH"
    -H "Authorization: Bearer $token" -H "Accept: application/json" -H "User-Agent: $UA"
    -w '\n%{http_code}')
  [ -n "$BODY" ] && args+=(-H "Content-Type: application/json" --data "$BODY")
  [ -n "$IF_MATCH" ] && args+=(-H "If-Match: $IF_MATCH")
  [ -n "$HEADERS_TMP" ] && args+=(-D "$HEADERS_TMP")
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
case "$STATUS" in
  2*)
    [ -z "$HEADERS_TMP" ] || mv -f "$HEADERS_TMP" "$RESPONSE_HEADERS"
    exit 0 ;;
  *) echo "HTTP $STATUS" >&2; exit 1 ;;
esac
