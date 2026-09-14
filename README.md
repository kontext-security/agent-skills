# Kontext Agent Skills

Skills that teach coding agents (Claude Code, Cursor, Codex, …) to operate [Kontext](https://kontext.security) through its management API.

## Install

```
npx skills add kontext-security/agent-skills
```

Install-less: point your agent at the raw skill — `Read https://raw.githubusercontent.com/kontext-security/agent-skills/main/skills/kontext-admin/SKILL.md and connect this organization.`

## Skills

| Skill | What it does |
|---|---|
| [`kontext-admin`](skills/kontext-admin/SKILL.md) | SCIM/Entra directory setup, org settings, authorization-decision and trace inspection, release downloads — against the [management API](https://api.kontext.security/api/openapi.json). |

Tell your agent: **"Connect to Kontext and show me my policies."** Approve once in your browser. Connected agents start read-only; change their permissions under **Settings → Agent access**.

For CI or different access per agent, create a service account under **Settings → Agent access → Service accounts** and export `KONTEXT_CLIENT_ID` / `KONTEXT_CLIENT_SECRET`.

Skill version: **0.6.0**.
