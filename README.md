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

Credentials: create a service account in the Kontext dashboard under **Settings → Agent access** and export `KONTEXT_CLIENT_ID` / `KONTEXT_CLIENT_SECRET`.
