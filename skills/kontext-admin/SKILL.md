---
name: kontext-admin
metadata:
  version: "0.7.1"
description: Configure and operate a Kontext organization through its management API — SCIM/Entra directory sync, org settings, policies and policy-set versions, authorization decisions, risks, traces, and managed-endpoint releases. Use when asked to connect to Kontext, connect Entra/SCIM, propose or enforce policies, inspect policy decisions, risks or traces, change Kontext settings, or download Kontext releases.
---

# Kontext admin

You are operating a Kontext organization on behalf of one of its admins, through the Kontext management API.

## Connect and read

**Connect once, then run commands.** All requests go through the bundled helper, which authenticates the first time it needs to:

```
scripts/kontext-api.sh GET /api/v1/policy/deployment
```

The first call opens the user's **browser to approve access** (OAuth authorization code + PKCE, loopback callback): relay the printed URL to the user verbatim — they click Allow in their Kontext dashboard (where they're already signed in) and the token lands in the helper automatically. Zero codes to type; no secret is ever entered in the terminal or shown in chat. The helper requests the scopes needed for the five areas below. The token is cached by API base URL, client ID, and requested scopes; later calls in the same context reuse it.

Connect once: permissions live under **Settings → Agent access** and changes apply to the next request without reconnecting. New workspaces start with **Policy author** (every read plus policy write), so a connected agent can propose policies right away. Workspaces created earlier may still be read-only; there an admin switches the preset to Policy author before policy writes work. The five areas are **Policies, Directory, Settings, Logs, and Deployments**. Use service accounts when each agent needs different access or when running in CI.

The dashboard prompt is **"Connect to Kontext and show me my policies."** Complete it with reads only:

1. Run `scripts/kontext-api.sh GET /api/v1/policy/deployment`, completing browser approval if needed.
2. Read `GET /api/v1/policy/versions/{id}` for each distinct non-null policy version named in the deployment.
3. Summarize the policies and whether they are enforced, observing, or disabled. If there is no version, say that no policies are configured. Stop here. Connection does not require onboarding, provisioning, or any write request.

You can also connect explicitly first:

```
scripts/kontext-connect.sh    # opens the browser, waits for approval
```

Optional environment:

```
KONTEXT_API_BASE       optional, default https://api.kontext.security
KONTEXT_CONNECT_FLOW   optional, "device" for the device-code flow (RFC 8628):
                       prints a URL + short code to approve on another machine
                       (SSH boxes). Requires a deployment with the device grant
                       enabled (dev/self-hosted).
```

**CI / headless** (no human to approve): set `KONTEXT_CLIENT_ID` + `KONTEXT_CLIENT_SECRET` from a service account (dashboard → Settings → Agent access → Service accounts). The helper uses client credentials. Choose the granted scopes with a preset such as **Policy author**; `KONTEXT_SCOPES` remains an optional narrower request. The creator must remain an organization admin. Service accounts keep their own grants and are not limited by the connected-agent setting.

On a 403 with `error: "insufficient_scope"`, report the `missingScopes` and the server's `hint` verbatim, then stop. Do not retry, reconnect, or change `KONTEXT_SCOPES` to bypass it. Other 403 responses may be role or session-only restrictions; report the response without inventing missing scopes. Only a signed-in admin can change the connected-agent setting.

## API map

Machine-readable contract: `GET {KONTEXT_API_BASE}/api/openapi.json` — fetch the relevant path definitions when you need exact schemas. Summary (all paths under `/api/v1`):

| Area | Endpoints | Scope |
|---|---|---|
| Directory / SCIM | `GET/POST /organizations/current/directory/scim-tokens`, `POST …/scim-tokens/{sha256}/revoke`, `GET …/directory/status`, `…/groups`, `…/reconciliation` | `management:directory:read` / `:write` |
| Agent access | `GET /organizations/current/agent-access` (PATCH requires an admin dashboard session) | `management:settings:read` |
| Org settings | `GET/PATCH /policy/settings` (`policyEnabled`, `payloadCaptureMode`) | `management:settings:read` / `:write` |
| Policy state and history | `GET /policy/deployment` (both slots + ETag), `GET /policy`, `GET /policy/versions`, `GET /policy/versions/{id}`, `GET /policy/rule-templates` | `management:policy:read` |
| Policy actions | `POST /policy/actions`, `POST /policy/validations` | `management:policy:write` |
| Policy-set versions | `POST /policy/deployment/promote` (enforce the reviewed observing version), `POST /policy/deployment/rollback` (enforce an earlier version again) | `management:policy:write` |
| Policy evidence | `POST /policy/replay`, `GET /policy/blocked?days=7` | `management:policy:read` |
| Decisions | `GET /decisions` (filters: provider, decisionResult, decisionCategory, reasonCode, riskLevel, installationId, sessionId, from/to; cursor pagination), `GET /decisions/{id}` | `management:logs:read` |
| Traces | `GET /traces`, `GET /traces/stats`, `GET /traces/{traceId}` | `management:logs:read` |
| Risks | `GET /enterprise/dashboard/risk/summary` (from/to), `GET /enterprise/dashboard/risk/findings` (from/to, severity, riskCategory, agent, principal, decision; cursor pagination), `GET /enterprise/dashboard/execution/failures` (from/to, toolName) | `management:logs:read` |
| Demo mode | `GET /demo-data/mode` (returns `{"demoMode": true}` or `false`; read-only) | `management:logs:read` |
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
2. Give the user the two values for the IdP portal — Tenant URL: `{KONTEXT_API_BASE}/scim/v2`, Secret token: the minted token — and walk them through the Entra side: *Entra admin center → the integration's Provisioning page → Automatic → paste Tenant URL + Secret Token → Test connection → assign users/groups → Start provisioning.* (If they granted you Microsoft Graph access you may drive that side too; otherwise it is manual.)
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
   Every save is an immutable version numbered v1, v2, … per organization; each
   listed version has a `state` (`enforced`, `observing`, `paused` or `past`) and
   the `changes` (policy IDs added, removed or modified) against its parent. Refer
   to versions by number when talking to the user.
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

   When the user has reviewed the whole observing version and wants all of it
   enforced, promote the version instead of enforcing policies one by one:

   ```bash
   scripts/kontext-api.sh POST /api/v1/policy/deployment/promote \
     '{"observingVersionId":"<observing ID you reviewed>"}' "$etag"
   ```

   Promote creates no new version. It fails with 409
   `observing_changed` if a different version is observing now (read it, replay
   it, and present it again) and 409 `nothing_observing` if nothing is. In an
   observe-only workspace it switches the workspace to enforcing, so say so before
   promoting; a paused workspace stays paused.

5. **Roll back if needed.** To enforce an earlier version again, send
   `{"policyVersionId":"<earlier version ID>"}` to `POST /policy/deployment/rollback`
   with the current ETag. It creates no new version and leaves the observing
   version as it is. A version's `changes` describe it against its own parent, not
   against what is enforced now, so read both versions with `/policy/versions/{id}`
   and present the policies the rollback would remove and restore. It
   answers 409 `already_enforced` for the enforced version and 422 for a version
   that is no longer valid.

6. **Verify the result.** Re-read `/policy/deployment` and `/policy/versions`.
   Check `/policy/blocked?days=7` and `/decisions?from=<change time>` after a relevant
   test call. History records one origin per action. A successful API write does
   not prove that a Mac has checked in and applied it.

**Always pass `If-Match` as the helper's fourth argument for actions.** A missing
header returns 428. On 412, re-read the deployment, reconcile the change, and
re-present it; never blindly retry or remove the precondition. On a timeout,
read deployment and History to determine whether the transaction committed.
Invalid Cedar returns 422 with diagnostics, unknown IDs return 404, and policy-ID
collisions or conflicting states return 409.

Promote and rollback accept the deployment ETag as an optional `If-Match`;
always send it.

**Never send `PUT /policy/deployment` from this skill.** It controls rollout mode
for the whole organization and remains a dashboard workflow. Do not use
`PUT /policy` for per-policy changes either; `/policy/actions` saves and deploys
atomically. Policy write access still technically permits those lower-level API
routes; the Policy author preset does not separate authoring from enforcement.

### Propose policies from logs and risks

The onboarding prompt is **"Check logs, combine with risks, and propose
policies."** Treat it, and any request like it, as this workflow. Proposals land in
the observing version; nothing is enforced unless the user says so.

1. **Connect and read the current state:** `/policy/deployment`, each non-null
   `/policy/versions/{id}`, and `/policy/versions`. Note which policy IDs are
   already enforced or observing so you do not propose duplicates.
2. **Read what agents actually do.** Use `GET /traces/stats?period=30d` and
   `GET /decisions` over the last 30 days (`from`/`to`) to see which tools and
   resources are used and what was already blocked. Read `GET /enterprise/dashboard/risk/summary` and
   `…/risk/findings` for the same window to see flagged calls by severity and
   category. Before relying on these reads, call `GET /demo-data/mode`. When
   `demoMode` is `true`, the risk, replay and blocked reads return the shared demo
   workspace while decisions, traces and writes stay on this one: tell the user
   that demo mode is on and have them turn it off in the dashboard before
   proposing. Summarize the top resources and risks for the user.
3. **Read the preset catalog:** `GET /policy/rule-templates`. Prefer a preset when
   one covers a risk; check `availability`, `coverage` and `knownGaps`.
4. **Propose.** Present a short list: for each policy, the risk or usage it
   answers, preset ID or custom raw policy, and scope (all agents, one agent, one
   endpoint). Write custom policies as one static Cedar statement with a unique
   `@id("custom:...")` and validate the full candidate text through
   `POST /policy/validations` before proposing it.
5. **Add the accepted ones to observing** with `POST /policy/actions`
   (`"action":"add"`), one action per policy, following
   [Change Cedar policy safely](#change-cedar-policy-safely) for ETags and errors.
   Each add creates the next observing version.
6. **Replay** the observing version over 7, 14 or 30 days and report what it would
   have blocked. Enforce only when the user asks: per policy with `enforce`, or the
   whole reviewed version with promote.

On a 403 `insufficient_scope` for policy write, report `missingScopes` and the
server's `hint` verbatim as described above. When you connected through browser
approval with the default scopes, the likely cause is a workspace still set to
read-only: an admin can choose **Policy author** under **Settings → Agent access**.
A service account or a narrower `KONTEXT_SCOPES` request has its own grants, which
that setting does not change.

### Verify policy behavior through decisions

After any policy or settings change: have the user (or a test endpoint) trigger the relevant tool call, then query `GET /api/v1/decisions?from=<change time>` and inspect `decisionResult`, `reasonCode`, `riskLevel`. Use `GET /decisions/{id}` for a single decision. This is the ground truth for "did the change do what we intended".

### Download the latest release for MDM distribution

1. `GET /api/v1/deployments/releases/latest` — note `version`, changelog, and each artifact's `sha256`.
2. `POST /api/v1/deployments/releases/{version}/artifacts/{kind}/download-url` for `package` and `install_script` (URLs expire in ~15 minutes; do not log them).
3. Download, then verify: `shasum -a 256 <file>` must equal the manifest's `sha256` — refuse to hand over an artifact that does not match.
4. The install script expects `KONTEXT_INSTALL_TOKEN` at install time — mint one via `POST /api/v1/organizations/current/install-tokens` (write scope; shown once; rule 3 applies) and pass it into the user's MDM (e.g. Addigy) as instructed by the install script's docs.
