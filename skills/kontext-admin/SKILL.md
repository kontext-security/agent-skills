---
name: kontext-admin
description: Configure and operate a Kontext organization through its management API — SCIM/Entra directory sync, org settings, authorization decisions, traces, and managed-endpoint releases. Use when asked to set up Kontext, connect Entra/SCIM, inspect policy decisions or traces, change Kontext settings, or download Kontext releases.
---

# Kontext admin

You are operating a Kontext organization on behalf of one of its admins, through the Kontext management API.

## Setup

**Connect once, then run commands.** All requests go through the bundled helper, which authenticates the first time it needs to:

```
scripts/kontext-api.sh GET /api/v1/policy/settings
```

The first call runs the **device flow**: the helper prints a URL and a short code. Relay both to the user verbatim — they open the URL, confirm the code, and approve the scopes in their Kontext dashboard (where they're already signed in). No secret is ever entered in the terminal or shown in chat. The token is then cached; later calls reuse it.

You can also connect explicitly first:

```
scripts/kontext-connect.sh    # prints the URL + code, waits for approval
```

Optional environment:

```
KONTEXT_API_BASE   optional, default https://api.kontext.security
KONTEXT_SCOPES     optional, override the requested scopes (space-separated)
```

**CI / headless** (no human to approve): set `KONTEXT_CLIENT_ID` + `KONTEXT_CLIENT_SECRET` from a service account (dashboard → Settings → Agent access → Advanced), and the helper uses client-credentials instead of the device flow — same commands, no browser.

A 403 means the connected identity lacks that scope — tell the user which scope is needed rather than retrying.

## API map

Machine-readable contract: `GET {KONTEXT_API_BASE}/api/openapi.json` — fetch the relevant path definitions when you need exact schemas. Summary (all paths under `/api/v1`):

| Area | Endpoints | Scope |
|---|---|---|
| Directory / SCIM | `GET/POST /organizations/current/directory/scim-tokens`, `POST …/scim-tokens/{sha256}/revoke`, `GET …/directory/status`, `…/groups`, `…/reconciliation` | `management:directory:read` / `:write` |
| Org settings | `GET/PATCH /policy/settings` (`policyEnabled`, `payloadCaptureMode`) | `management:settings:read` / `:write` |
| Decisions | `GET /decisions` (filters: provider, decisionResult, decisionCategory, reasonCode, riskLevel, installationId, sessionId, from/to; cursor pagination), `GET /decisions/{id}` | `management:logs:read` |
| Traces | `GET /traces`, `GET /traces/stats`, `GET /traces/{traceId}` | `management:logs:read` |
| Releases | `GET /deployments/releases`, `GET /deployments/releases/latest`, `POST /deployments/releases/{version}/artifacts/{kind}/download-url` | `management:deployments:read` |
| Install tokens | `GET/POST /organizations/current/install-tokens`, `POST …/{sha256}/revoke` | `management:deployments:read` / `:write` |

Policy rule authoring via API is not available yet — it arrives with the Cedar admin API. Direct the user to the dashboard for policy rules; settings toggles above are available.

Rate limit: 120 requests/min per credential. On 429, wait the `Retry-After` seconds. Include the `x-request-id` response header when reporting API errors to the user.

## Rules for writes (non-negotiable)

1. **Read before write.** Fetch current state, show the user a concise diff of what will change, then apply.
2. **Settings PATCH:** include `expectedUpdatedAt` from your read. On 412, the state changed under you — re-read and re-present, never force.
3. **Never blind-retry a credential-minting POST** (SCIM tokens, install tokens). The secret is returned exactly once; a timed-out request may still have created a token. On ambiguous failure: list tokens, revoke the orphan if one appeared, then mint again.
4. Secrets (minted tokens, client secrets) go straight into the delivery target (clipboard, env file, the IdP form the user is filling). Never into chat output, shell history via `echo`, or logs.

## Workflows

### Connect Entra ID (or any SCIM IdP)

1. `POST /api/v1/organizations/current/directory/scim-tokens` with a label like `entra-prod`. The response contains the raw token **once**.
2. Give the user the two values for the IdP portal — Tenant URL: `{KONTEXT_API_BASE}/scim/v2`, Secret token: the minted token — and walk them through the Entra side: *Entra admin center → Enterprise applications → their app (or New application → Create your own) → Provisioning → Automatic → paste Tenant URL + Secret Token → Test connection → assign users/groups → Start provisioning.* (If they granted you Microsoft Graph access you may drive that side too; otherwise it is manual.)
3. Verify from the Kontext side: `GET …/directory/status` (user/group counts appear after the first sync cycle — Entra's initial cycle can take up to ~40 minutes), `GET …/directory/groups`, and `GET …/directory/reconciliation` to see which managed endpoints resolve against the directory (`matched` / `no_email` / `unmatched` / `ambiguous`).

### Verify policy behavior through decisions

After any policy or settings change: have the user (or a test endpoint) trigger the relevant tool call, then query `GET /api/v1/decisions?provider=github&from=<change time>` and inspect `decisionResult`, `reasonCode`, `riskLevel`. Use `GET /decisions/{id}` for a single decision. This is the ground truth for "did the change do what we intended".

### Download the latest release for MDM distribution

1. `GET /api/v1/deployments/releases/latest` — note `version`, changelog, and each artifact's `sha256`.
2. `POST /api/v1/deployments/releases/{version}/artifacts/{kind}/download-url` for `package` and `install_script` (URLs expire in ~15 minutes; do not log them).
3. Download, then verify: `shasum -a 256 <file>` must equal the manifest's `sha256` — refuse to hand over an artifact that does not match.
4. The install script expects `KONTEXT_INSTALL_TOKEN` at install time — mint one via `POST /api/v1/organizations/current/install-tokens` (write scope; shown once; rule 3 applies) and pass it into the user's MDM (e.g. Addigy) as instructed by the install script's docs.
