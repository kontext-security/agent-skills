---
name: kontext-admin
metadata:
  version: "0.8.0"
description: Configure and operate a Kontext organization through its management API — SCIM/Entra directory sync, org settings, policies and policy-set versions, authorization decisions, risks, traces, managed endpoints, and releases. Use when asked to connect to Kontext, connect Entra/SCIM, check logs and risks, propose, write or enforce policies, inspect policy decisions, risks or traces, change Kontext settings, or download Kontext releases.
---

# Kontext admin

You are operating a Kontext organization on behalf of one of its admins, through the Kontext management API.

## Connect and read

**Connect once, then run commands.** All requests go through the bundled helper, which authenticates the first time it needs to:

```
scripts/kontext-api.sh GET /api/v1/policy/deployment
```

The first call opens the user's **browser to approve access** (OAuth authorization code + PKCE, loopback callback): relay the printed URL to the user verbatim — they click Allow in their Kontext dashboard (where they're already signed in) and the token lands in the helper automatically. Zero codes to type; no secret is ever entered in the terminal or shown in chat. The helper waits up to 15 minutes for approval (`KONTEXT_CONNECT_TIMEOUT` in seconds changes that), so run it with a command timeout of at least that long, or in the background, and do not cancel it while the user is approving: a stopped helper shows "127.0.0.1 refused to connect" in the browser. If that happens or the wait ends, run it again and relay the new URL. The helper requests the scopes needed for the five areas below. The token is cached by API base URL, client ID, and requested scopes; later calls in the same context reuse it.

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
KONTEXT_API_BASE        optional, default https://api.kontext.security
KONTEXT_CONNECT_TIMEOUT optional, seconds to wait for browser approval (default 900)
KONTEXT_CONNECT_FLOW    optional, "device" for the device-code flow (RFC 8628):
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
| Endpoints (Macs) | `GET /organizations/current/directory/reconciliation` (every managed endpoint: `installationId`, `deviceLabel`, `userEmail`, `lastSeenAt`, directory match) | `management:directory:read` |
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
   Some presets need a companion guard; the server adds it in the same action
   and lists it in the response's `message` and `changedPolicyIds`, and enforcing
   the preset enforces its guard too, so a preset's companion needs no add or
   enforce of its own. A custom policy gets no companion: when it needs a
   block-unrecognized guard, add and enforce that preset yourself.
   A 409 `policy_already_present` means a copy is already in the set (often a
   companion added earlier) and nothing changed, so keep the last good ETag.
   Re-read the version and check each requested scope: scoped copies carry
   `:endpoint:` or `:agent:` after the policy ID. When every scope you asked for
   is there, treat it as done, not as an error; otherwise add only the missing
   scopes. After a successful action,
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
   keeps enforcement paused. Enforcing a preset also enforces its observing
   companion guard; the response's `changedPolicyIds` lists both.
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
policies."** Treat it, and any request like it, as this workflow, and run every
step below in one go. The prompt is the request to write: adding to the
observing version blocks nothing, so present the list and add it in the same run
instead of stopping to ask for acceptance. Nothing is enforced unless the user
asks for enforcement, in this prompt or a later one.

1. **Read the current state:** `/policy/deployment` (keep its ETag), each non-null
   `/policy/versions/{id}`, and `/policy/versions`. Note which policy IDs are
   already enforced or observing so you do not propose duplicates.
2. **Check demo mode first:** `GET /demo-data/mode`. When `demoMode` is `true`,
   the risk, replay and blocked reads return the shared demo workspace while
   decisions, traces and writes stay on this one. Stop: tell the user that demo
   mode is on and to turn it off in the dashboard, then run the prompt again.
   Never propose from demo data.
3. **Read what agents actually do** over the last 30 days: `GET /traces/stats?period=30d`,
   `GET /decisions` with `from`/`to` (follow `nextCursor`; each item names
   `provider`, `toolName`, `operation`, `decisionResult`, `installationId`), and
   `GET /enterprise/dashboard/risk/summary` plus `…/risk/findings` for the same
   window. Combine them: which tools and resources are used, by which endpoints,
   what was flagged and how severely, and what was already blocked.
4. **List the endpoints:** `GET /organizations/current/directory/reconciliation`
   returns every managed endpoint (Mac) with its `installationId`, `deviceLabel`,
   `userEmail` and `lastSeenAt`. If it answers 403, use the distinct
   `installationId`s from the decisions instead and say so. Use this list to
   decide whether a policy should apply to all endpoints or to one
   (`endpointId` is the `installationId`), and to tell the user which Macs have
   not checked in recently and so will not pick up changes soon.
5. **Read the preset catalog:** `GET /policy/rule-templates`. Each template
   carries `availability`, `coverage`, `knownGaps` and its raw `cedar`. Prefer a
   preset when one covers a risk or a write-capable tool you saw in use. Some
   presets need a companion guard (for example a block-unrecognized operations
   policy); the server adds it with the preset, so do not add that companion
   separately. Step 7 covers the one case where you add a guard yourself.
6. **Write custom raw policies for what no preset covers.** Look for it before
   concluding the presets are enough: logs usually show something specific to
   this workspace, such as a particular MCP tool, a provider no preset names, or
   risky calls coming from one endpoint. Write each as exactly one static
   `forbid` statement with a unique `@id("custom:...")` and an
   `@description("...")`, modelled on the catalog's raw `cedar`, with
   `action == Kontext::Action::"ToolUse"`. How to name the tool:
   - Shell commands are `Kontext::Tool::"shell"`; match the parsed
     `context.shell.facts` the way the presets do.
   - GitHub, Atlassian and HubSpot MCP calls are resolved through a catalog,
     and only some tools keep a name (for example
     `github-mcp/merge_pull_request`); the rest arrive as
     `<provider>-mcp/unrecognized` with an access tier. For these providers
     prefer a preset, or match `context.tool` (`provider`, `product`, `access`)
     like the tier presets do, and never build an ID from a tool name.
   - Any other tool keeps the agent's own tool name, as `toolName` shows it in
     the decisions, for example `Kontext::Tool::"mcp__linear__delete_issue"`.
     Exception: while the enforced or observing text still names
     `Kontext::Tool::"unknown"`, Macs report every such tool as `unknown`, so a
     named rule would never match. Do not write one then; tell the user the set
     must stop naming `unknown` first and let them decide.
   Whichever you use, validation in the next step is the check: a tool ID it
   flags `unsupported_tool_id` never matches. Do not add an `@id` that collides
   with an existing ID or a preset's prefix, and do not write `:agent:` or
   `:endpoint:` into it; pass the scope as `endpointId` or `agentId` instead.
7. **Validate every custom policy** before adding it:
   `POST /policy/validations` with `{"policyText":"<text of the version your add
   builds on>\n\n<your statement>"}`. That version is the observing one (in an
   observe-only workspace, `policyVersionId`); with no version yet, use the
   catalog's `default-permit` cedar. Fix and validate again
   until `valid` is true. Treat warnings as problems too: `unsupported_tool_id`
   means the policy would never match, and `forbid_may_fail_open` means calls
   without a tier slip past: add the provider's block-unrecognized preset when
   the catalog has one, otherwise match the tool by resource instead. Drop a policy you cannot make valid and
   say why.
8. **Present the list,** most important first: for each policy, the logged usage
   or risk it answers (with counts), preset ID or the custom raw policy, scope
   (all endpoints, one endpoint, one agent), and what it would block. Keep it to
   the few policies that matter; three to six is typical.
9. **Add them to observing** right away, one `POST /policy/actions`
   `{"action":"add",...}` per policy, following
   [Change Cedar policy safely](#change-cedar-policy-safely) for ETags and
   errors. Before each add, read the current version's text and skip a policy
   only when it is already there for the same scope (companion guards added by
   an earlier preset count; they apply to the scope of that preset). Handle a
   409 `policy_already_present` as described there: done when every requested
   scope exists, otherwise add the missing scopes.
10. **Replay** the resulting observing version over 30 days (or 7 or 14) and
    report per policy what it would have blocked and what was not replayable.
11. **Finish.** If the user did not ask for enforcement, say which version is
    observing (by number), that nothing blocks yet, and that they can say
    **"Enforce them"**. If they asked, in this prompt or later,
    enforce what this run added. When the observing version holds only this
    run's changes, promote it as described in step 4 of
    [Change Cedar policy safely](#change-cedar-policy-safely). When it also held
    earlier changes, promote enforces those too, so enforce this run's policies
    one by one with `enforce` instead, passing the exact `@id` of each copy you
    added as it appears in the version text (scoped copies carry their
    `:endpoint:` or `:agent:` suffix). A base preset ID enforces every copy of
    that preset, including older ones, so use it only when no other copy
    exists. Include any block-unrecognized guard a custom policy of this run
    relies on, even if it was already observing, since nothing enforces it
    for a custom policy. Do this unless the user explicitly approved the
    whole version after you listed the earlier changes. Say that an
    observe-only workspace now enforces, and name the enforced version. Either
    way, say that each Mac applies a change at its next check-in.

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
