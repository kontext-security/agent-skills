---
name: kontext-admin
description: Configure and operate a Kontext organization through its management API — SCIM/Entra directory sync, org settings, authorization decisions, traces, and managed-endpoint releases. Use when asked to set up Kontext, connect Entra/SCIM, inspect policy decisions or traces, change Kontext settings, or download Kontext releases.
---

# Kontext admin

You are operating a Kontext organization on behalf of one of its admins, through the Kontext management API.

## Setup

**Connect once, then run commands.** All requests go through the bundled helper, which authenticates the first time it needs to:

```
scripts/kontext-api.sh GET /api/v1/policy/deployment
```

The first call opens the user's **browser to approve access** (OAuth authorization code + PKCE, loopback callback): relay the printed URL to the user verbatim — they click Allow in their Kontext dashboard (where they're already signed in) and the token lands in the helper automatically. Zero codes to type; no secret is ever entered in the terminal or shown in chat. The token is then cached; later calls reuse it.

You can also connect explicitly first:

```
scripts/kontext-connect.sh    # opens the browser, waits for approval
```

Optional environment:

```
KONTEXT_API_BASE       optional, default https://api.kontext.security
KONTEXT_SCOPES         optional, override the requested scopes (space-separated)
KONTEXT_CONNECT_FLOW   optional, "device" for the device-code flow (RFC 8628):
                       prints a URL + short code to approve on another machine
                       (SSH boxes). Requires a deployment with the device grant
                       enabled (dev/self-hosted).
```

**CI / headless** (no human to approve): set `KONTEXT_CLIENT_ID` + `KONTEXT_CLIENT_SECRET` from a service account (dashboard → Settings → Agent access → Advanced), and the helper uses client-credentials instead of the browser. For policy changes, choose the **Policy author** preset and export `KONTEXT_SCOPES` with the granted scopes. The creator must remain an organization admin. **Observer** grants policy reads, replay, and blocked-call reports without writes. Use a separate `XDG_CACHE_HOME` for each service account or API environment so a cached token cannot select the wrong identity.

A 403 means the connected identity lacks that scope — tell the user which scope is needed rather than retrying.

## API map

Machine-readable contract: `GET {KONTEXT_API_BASE}/api/openapi.json` — fetch the relevant path definitions when you need exact schemas. Summary (all paths under `/api/v1`):

| Area | Endpoints | Scope |
|---|---|---|
| Directory / SCIM | `GET/POST /organizations/current/directory/scim-tokens`, `POST …/scim-tokens/{sha256}/revoke`, `GET …/directory/status`, `…/groups`, `…/reconciliation` | `management:directory:read` / `:write` |
| Org settings | `GET/PATCH /policy/settings` (`policyEnabled`, `payloadCaptureMode`) | `management:settings:read` / `:write` |
| Policy state and history | `GET /policy/deployment` (both slots + ETag), `GET /policy`, `GET /policy/versions`, `GET /policy/versions/{id}`, `GET /policy/rule-templates` | `management:policy:read` |
| Policy actions | `POST /policy/actions`, `POST /policy/validations` | `management:policy:write` |
| Policy evidence | `POST /policy/replay`, `GET /policy/blocked?days=7` | `management:policy:read` |
| Decisions | `GET /decisions` (filters: provider, decisionResult, decisionCategory, reasonCode, riskLevel, installationId, sessionId, from/to; cursor pagination), `GET /decisions/{id}` | `management:logs:read` |
| Traces | `GET /traces`, `GET /traces/stats`, `GET /traces/{traceId}` — **requires OTEL trace ingestion, which is not enabled on hosted deployments.** Do not reach for these to answer "what is this org doing"; see the activity workflow below | `management:logs:read` |
| Releases | `GET /deployments/releases`, `GET /deployments/releases/latest`, `POST /deployments/releases/{version}/artifacts/{kind}/download-url` | `management:deployments:read` |
| Install tokens | `GET/POST /organizations/current/install-tokens`, `POST …/{sha256}/revoke` | `management:deployments:read` / `:write` |

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

### Change Cedar policy safely

The deployment has an enforced version and an optional observing version. The
observing version is replayed against recorded calls; adding to it does not weaken
the enforced version. In an observe-only workspace, `policyVersionId` is the
observing version. A disabled workspace stays disabled until resumed in the dashboard.
Local Cedar evaluation on each Mac makes the policy decision; replay reports what
recorded calls would have done under the candidate.

1. **Read both slots and the deployment ETag.** All paths below start with `/api/v1`.
   Read `/policy/deployment`, then `/policy/versions/{id}` for each non-null slot.
   Read `/policy/rule-templates` for available templates and `/policy/versions` for history.
   The helper writes successful response headers when `KONTEXT_RESPONSE_HEADERS`
   is set. Failed requests leave the file unchanged:

   ```bash
   headers=$(mktemp)
   KONTEXT_RESPONSE_HEADERS="$headers" scripts/kontext-api.sh GET /api/v1/policy/deployment
   etag=$(awk 'tolower($1) == "etag:" {sub(/\r$/, "", $2); print $2}' "$headers")
   ```

2. **Add one policy, observing.** Use a template or exactly one static Cedar
   statement with a unique `@id("custom:...")`. A raw ID must not overlap an
   existing policy ID or a catalog template's reserved prefix. For custom Cedar,
   validate the full candidate text through `POST /policy/validations` first; the
   action also validates the final text before saving anything.

   ```bash
   KONTEXT_RESPONSE_HEADERS="$headers" scripts/kontext-api.sh POST /api/v1/policy/actions \
     '{"action":"add","templateId":"block-github-force-push"}' "$etag"
   ```

   Custom form: `{"action":"add","cedar":"@id(\"custom:no-shell\") forbid(principal, action, resource);"}`.
   Optional `endpointId` is an enrolled installation ID; `agentId` is
   `anthropic-claude-code` or `openai-codex` (use the catalog/OpenAPI enum).
   To add copies for several scopes in one transaction, use `scopes` instead of
   the top-level scope fields, for example `[{"agentId":"openai-codex"}]`.
   The response names any companion guards added. After a successful action,
   refresh `etag` from its response headers before the next action. Only use
   ETags from successful deployment reads or policy actions, never error responses
   or other endpoints. After a 422, fix the policy and retain the last deployment
   ETag; a subsequent 412 still requires a fresh deployment read.

3. **Replay before promoting.** `POST /policy/replay` with
   `{"enforcingVersionId":"<active ID>","observingVersionId":"<observing ID>","days":7}`.
   Supported windows are 7, 14, and 30 days. In observe-only workspaces use
   `policyVersionId` for both IDs and set `baselinePolicyText` to the catalog's
   default-permit text. If disabled with only an observing slot, use its ID for
   both and the same baseline. Report per-policy `wouldBlock`/`wouldAllow`,
   `needsCapture`, `notReplayable`, and `truncated`; zero captured calls are not
   evidence that a policy is safe. Replay needs only policy read access.

4. **Promote explicitly.** Send `{"action":"enforce","policyId":"block-github-force-push"}`
   to `/policy/actions` with the current deployment ETag. This promotes only
   that policy's blocks; other changes keep observing. This explicit action may
   switch observe → enforce. In a paused workspace it changes the selection but
   keeps enforcement paused. Companion guards are separate policies: review and
   explicitly enforce them too when the template needs them.
   Stop with `{"action":"stop","policyId":"..."}` to move it back to observing.
   Remove with `{"action":"delete","policyId":"...","where":"observing"}` or
   `"where":"enforced"`; deleting an enforced policy also removes its observing copies.

5. **Verify the result.** Re-read `/policy/deployment` and `/policy/versions`.
   Check `/policy/blocked?days=7` and `/decisions?from=<change time>` after a relevant
   test call. History records one origin per action. A successful API write does
   not prove that a Mac has checked in and applied it.

**Always pass `If-Match` as the helper's fourth argument for actions.** A missing
header returns 428. On 412, re-read the deployment, reconcile the change, and
re-present it; never blindly retry or remove the precondition. On a timeout,
read deployment and History to determine whether the transaction committed.
Invalid Cedar returns 422 with diagnostics, unknown IDs return 404, and policy-ID
collisions or conflicting states return 409.

**Never send `PUT /policy/deployment` from this skill.** It controls rollout mode
for the whole organization and remains a dashboard workflow. Do not use
`PUT /policy` for per-policy changes either; `/policy/actions` saves and deploys
atomically. Policy write access still technically permits those lower-level API
routes; the Policy author preset does not separate authoring from enforcement.

### Report on org activity (tool usage, sessions, denials)

`GET /api/v1/decisions` is the activity surface — one row per tool call the endpoint
daemon evaluated, carrying `toolName`, `sessionId`, `installationId`, `occurredAt`,
`decisionResult`, `decisionCategory`, `reasonCode`, `provider`, `operation`. Use it for
"top tools", "which sessions", "what got denied", "how much traffic".

**Do not use `/traces` or `/traces/stats` for this.** Trace ingestion is not enabled on
hosted deployments, so those endpoints return `{"items": []}` and an all-zeros stats
payload (`totalTraces: 0`, `topTools: []`) — indistinguishable from a genuinely idle
org. An empty `/traces` result is not evidence that nothing happened; re-check
`/decisions` before reporting inactivity.

There is no server-side aggregation, so top-N means paging and counting client-side:

```
cursor=""; : > decisions.jsonl
while :; do
  q="/api/v1/decisions?limit=200"; [ -n "$cursor" ] && q="$q&cursor=$cursor"
  resp=$(scripts/kontext-api.sh GET "$q") || break
  printf '%s' "$resp" | jq -c '.items[]?' >> decisions.jsonl
  cursor=$(printf '%s' "$resp" | jq -r '.nextCursor // empty'); [ -z "$cursor" ] && break
done
jq -r '.toolName' decisions.jsonl | sort | uniq -c | sort -rn | head -20
```

Narrow with `from`/`to` before paging when the user asked about a window — the default
is the full retained history. When reporting, say which window and how many rows the
numbers cover, and note that `toolName` may be empty on some rows (e.g. async
telemetry) rather than silently dropping them.

### Verify policy behavior through decisions

After any policy or settings change: have the user (or a test endpoint) trigger the relevant tool call, then query `GET /api/v1/decisions?from=<change time>` and inspect `decisionResult`, `reasonCode`, `riskLevel`. Use `GET /decisions/{id}` for a single decision. This is the ground truth for "did the change do what we intended".

### Download the latest release for MDM distribution

1. `GET /api/v1/deployments/releases/latest` — note `version`, changelog, and each artifact's `sha256`.
2. `POST /api/v1/deployments/releases/{version}/artifacts/{kind}/download-url` for `package` and `install_script` (URLs expire in ~15 minutes; do not log them).
3. Download, then verify: `shasum -a 256 <file>` must equal the manifest's `sha256` — refuse to hand over an artifact that does not match.
4. The install script expects `KONTEXT_INSTALL_TOKEN` at install time — mint one via `POST /api/v1/organizations/current/install-tokens` (write scope; shown once; rule 3 applies) and pass it into the user's MDM (e.g. Addigy) as instructed by the install script's docs.
