#!/usr/bin/env bash
# Shared OAuth scope request and cache context for both connection paths.
BASE="${KONTEXT_API_BASE:-https://api.kontext.security}"
SCOPES="${KONTEXT_SCOPES:-management:providers:read management:providers:write management:applications:read management:applications:write management:policy:read management:policy:write management:directory:read management:directory:write management:settings:read management:settings:write management:logs:read management:logs:write management:deployments:read management:deployments:write}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/kontext-skill"
TOKEN_FILE="$CACHE_DIR/token-$(printf '%s|%s|%s' "$BASE" "${KONTEXT_CLIENT_ID:-kontext-cli}" "$SCOPES" | shasum -a 256 | cut -c1-16).json"
