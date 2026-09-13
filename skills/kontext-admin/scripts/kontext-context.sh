#!/usr/bin/env bash
# Shared OAuth scope request and cache context for both connection paths.
BASE="${KONTEXT_API_BASE:-https://api.kontext.security}"
BASE="${BASE%/}"
IDENTITY=kontext-cli
if [ -n "${KONTEXT_CLIENT_SECRET:-}" ]; then
  IDENTITY="${KONTEXT_CLIENT_ID:?KONTEXT_CLIENT_ID is required with KONTEXT_CLIENT_SECRET}"
fi
SCOPES="${KONTEXT_SCOPES:-management:providers:read management:providers:write management:applications:read management:applications:write management:policy:read management:policy:write management:directory:read management:directory:write management:settings:read management:settings:write management:logs:read management:logs:write management:deployments:read management:deployments:write}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/kontext-skill"
# Drop the pre-0.5 cache so it cannot be reused by an older helper.
rm -f "$CACHE_DIR/token.json"
TOKEN_FILE="$CACHE_DIR/token-$(printf '%s|%s|%s' "$BASE" "$IDENTITY" "$SCOPES" | {
  if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi
} | cut -c1-16).json"
