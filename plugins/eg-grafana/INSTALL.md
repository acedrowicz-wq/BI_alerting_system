# eg-grafana — install

EnjoyGaming's customised version of the Grafana Labs `grafana-mcp` plugin. Compared with upstream it:

- points at **https://grafana.enjoygaming.live** by default (override with `GRAFANA_URL`),
- reads the token from the `GRAFANA_SERVICE_ACCOUNT_TOKEN` environment variable instead of a plugin config prompt, so it works in Claude Code cloud sessions (no config screen) as well as locally,
- enables only the tool categories BI uses (`search, datasource, dashboard, folder, alerting, navigation, annotations, clickhouse`) to keep the context small; edit `--enabled-tools` in `.mcp.json` to change that,
- ships the `grafana-bi-alerting` skill with the team's alert conventions (ProdCH, Table query, Reduce Last → Threshold > 0, 5m/15m, No data → OK, `team=bi` labels).

## 0. Grafana service account (once, a Grafana admin)

1. Grafana → **Administration → Users and access → Service accounts → Add service account**, e.g. `claude-bi`.
2. Role: **Viewer** for read-only use. Creating or updating alert rules needs **Editor**; prefer granting Editor only on the BI alerts folder (folder → Permissions) and keeping the org role at Viewer.
3. **Add service account token**, with an expiry. Store it in the places below only. Never paste it into a chat.

## 1. Claude Code cloud sessions (claude.ai/code)

In the session's environment (environment menu in the session title bar → **Edit**):

1. Environment variables:
   - `GRAFANA_SERVICE_ACCOUNT_TOKEN=<token>`
   - `GRAFANA_URL` is optional. It defaults to `https://grafana.enjoygaming.live`.
2. **Network access** → **Custom** → add `grafana.enjoygaming.live` to the allowed domains. Add the Docker Hub hosts (`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`) too, so the `grafana/mcp-grafana` image can be pulled.
3. Start a **new** session. Plugins and environment changes apply only to sessions started after them.

## 2. Claude Code locally

```bash
export GRAFANA_SERVICE_ACCOUNT_TOKEN="glsa_..."     # e.g. from your password manager / keychain
claude                                              # Docker must be running
```

Without Docker, install the `mcp-grafana` binary (github.com/grafana/mcp-grafana) and change `.mcp.json` to `"command": "mcp-grafana"` with only the `--enabled-tools ...` args.

## 3. Publishing to the company marketplace

This directory has the same layout as `eg-clickhouse` in `EnjoyGaming-Live/claude-plugins`. Copy `plugins/eg-grafana/` there, add it to that repo's marketplace manifest, and push to `master`. The marketplace syncs to `claude.ai/admin-settings/plugins`. Then turn off the upstream `grafana-mcp` plugin, so both don't start a `grafana` server.

## 4. Verify

In a new session:

```
Check the Grafana connection and give me the UID of the ProdCH datasource.
```

Expected: the `list_datasources` result with `ProdCH` (type `grafana-clickhouse-datasource`). Then:

```
Deploy the alert from alerts/game_rtp_spike/query.sql on branch claude/loving-wozniak-vmh0db.
```
