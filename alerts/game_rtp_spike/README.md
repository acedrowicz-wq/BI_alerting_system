# Game RTP spike alert (4h / 12h / 24h vs 94% target)

Covers **all games**: slots and live. Fires when a game's RTP over a rolling **4h**, **12h** or **24h** window drastically exceeds the
**94%** target, after suppressing natural variance (low volume, single high-roller wins).

- **Datasource:** ProdCH (ClickHouse)
  - slots: `platform.agg_slots_ggr`
  - live: `platform.bets FINAL`
- **SQL:** [`query.sql`](query.sql)
- **Evaluation:** every 5 min, pending period 15 min

## Logic

| Step | What it does |
|---|---|
| Source (slots) | `platform.agg_slots_ggr`: settled real-money slot actions in EUR, 15-min buckets per game / casino / player. Test casinos and fun currencies are already excluded by the MV. Matches `agg_daily` (`isPromo = 0`) within 0.01 pp. |
| Source (live) | `platform.bets FINAL`, filtered to `status IN ('FINALIZED','COMPLETED')`, non-test casinos, non-fun currencies and no free spins. The day total matches `agg_daily` live (`isPromo = 0`): €775 148 vs €775 405. The fun-currency filter is mandatory: without it, `convertedBet` contains about €1bn/day of play money. |
| Windows | The last 16 / 48 / 96 **complete** 15-min buckets (4h / 12h / 24h), all computed in one pass. |
| High-roller suppression | `rtp_ex_top_pct` = RTP after removing the net win of the single biggest winner in the window. A single jackpot cannot trigger the alert on its own; only a broad-based spike can. |
| Volume gate (AC2) | **Slot** 4h: bet ≥ €10k, ≥ 50 players, ≥ 5k actions · 12h: ≥ €30k, ≥ 100 players, ≥ 15k actions · 24h: ≥ €60k, ≥ 200 players, ≥ 30k actions. **Live** 4h: bet ≥ €3k, ≥ 20 players, ≥ 300 bets · 12h: ≥ €8k, ≥ 30 players, ≥ 600 bets · 24h: ≥ €15k, ≥ 50 players, ≥ 1 200 bets. Live volume is 10–50× lower than slots; with the slot gates, 4 of the 11 live games would never be evaluated. |
| Threshold | 4h: `rtp_ex_top_pct` > **115%** (94 + 21 pp) · 12h: > **108%** (94 + 14 pp) · 24h: > **105%** (94 + 11 pp) |
| Alert value | The query returns **only the breaching (game, window) rows**, after the volume gate and with `rtp_ex_top_pct` above the threshold. The single numeric column, `rtp_actual_pct`, is the game's **actual (raw) RTP** in that window. An empty result means everything is OK. |

### Backtest (7 days, 2026-09-29 → 2026-10-06, hourly window ends)

| Window | Windows with raw RTP above threshold | After removing the top winner | Episodes |
|---|---|---|---|
| slot 4h  | 119 (> 115%) | 4  | thor_1000, hotfire_diamonds_2, thor_hit_the_bonus |
| slot 12h | 124 (> 108%) | 6  | pedro_spicy (01.10), thor_1000 (29.09) |
| live 4h  | — | 5  | greek_roulette (03.10, 05.10), wonder_wheel, phoenix_roulette |
| live 12h | — | 5  | greek_roulette (04.10), wonder_wheel, everyspin_x320_roulette |
| slot 24h | — | 5 (6 days) | pedro_spicy (same episode as 12h) |
| live 24h | — | 6 (6 days) | egypt_roulette, greek_roulette |

Every raw spike in the period came from a single player. The remaining episodes were sustained
over-payouts across hundreds of players, which is what this alert is meant to catch.


## Import into Grafana (recommended)

`grafana/rule-group.json` holds the complete rule, generated from `query.sql`:
- query A on ProdCH, then Reduce Last (B), then Threshold B > 0 (C);
- evaluation every 5m, pending 15m;
- No data → OK, Error → Error;
- labels `team=bi`, `alert=game_rtp_spike`;
- Slack summary and description templates;
- direct routing to the Slack contact point.

Grafana's UI cannot import Grafana-managed rules from a file, so the scripts below send one call to the provisioning API (`PUT /api/v1/provisioning/folder/<folder>/rule-groups/bi_game_rtp_spike`). They send `X-Disable-Provenance: true`, which keeps the rule editable in the UI.

**You need:**
1. **ProdCH datasource UID:** Connections → Data sources → ProdCH. It is the last segment of the URL (`/connections/datasources/edit/<uid>`).
2. **Folder UID:** Dashboards → open the target folder. It is the segment after `/dashboards/f/` in the URL.
3. **Slack contact point name:** Alerting → Contact points. Use the exact name.
4. **Service account token:** Administration → Service accounts, role Editor or alert-rule write access in that folder. The script prompts for it and never stores it.

**Run it from a machine that can reach Grafana (VPN / office network):**

```powershell
# Windows
cd alerts\game_rtp_spike\grafana
powershell -ExecutionPolicy Bypass -File .\import.ps1 -DatasourceUid <uid> -FolderUid <uid> -ContactPoint "<name>"
```

```bash
# macOS / Linux
cd alerts/game_rtp_spike/grafana
./import.sh <datasource_uid> <folder_uid> "<contact point name>"
```

Both scripts refuse to run if group `bi_game_rtp_spike` already holds other rules, because a PUT replaces the whole group. Re-running them updates this rule in place.

The datasource type is set to `grafana-clickhouse-datasource`, the official ClickHouse plugin. If ProdCH uses the Altinity plugin (`vertamedia-clickhouse-datasource`), tell BI to regenerate the JSON.

## Grafana alert rule (manual setup)

1. **Query A:** paste `query.sql`. Datasource ProdCH, Query Type **Table**.
   - Leave out `$__timeFilter`: the windows are rolling and anchored to `now()`, not to the dashboard range.
2. **Expression B (Reduce):** input A, function **Last**, mode **Drop non-numeric values**.
3. **Expression C (Threshold):** input B, **IS ABOVE 0**. Set this as the alert condition. The breach logic lives in the SQL; any returned row fires.
4. **Evaluation:** every **5m**, pending period **15m** (3 consecutive breaches).
5. **No data / Error handling:** No data → **OK** (no data is the normal state). Error → **Error**.
6. **Labels:** `team=bi`, `alert=game_rtp_spike`. Route this label to the dedicated Slack contact point (AC3).

Each game and window becomes its own alert instance, with labels `game_id`, `game_name`,
`game_type` (`slot` / `live`), `window` (`4h` / `12h` / `24h`) and `threshold_pct`. Once the game's RTP falls back
under the threshold, its row disappears from the result. Grafana marks the series as missing and
resolves the alert, which sends a "Resolved" message to Slack.

The query has **no `time` column**. With one, Grafana reads the table as a "long" time series and Reduce fails with `input data must be a wide series but got type long`.

Grafana alerting takes **exactly one numeric column** per query, so `rtp_actual_pct` is the only
numeric column. All other columns are strings and become stable labels.

### Slack template (summary / description)

```
:rotating_light: RTP spike — {{ $labels.game_name }} ({{ $labels.game_id }}, {{ $labels.game_type }})
Window: last {{ $labels.window }} | Target: 94% | Alert threshold: {{ $labels.threshold_pct }}%
Actual RTP ({{ $labels.window }}): {{ humanize $values.B.Value }}%
Still above threshold after excluding the biggest single winner, so not explained by one high-roller.
Check math version / game config / recent releases.
```


## Tuning

Change the constants in the `scored` CTE:

- `target_rtp_pct` (94)
- the `+21` / `+14` / `+11` pp offsets
- the `min_*` volume gates

To use per-game targets, `platform.slot_rtp_target` holds the target per game and math version.
The ggr rollup has no math-version column, though, so for now 94% stays the single target, as
the Jira ticket specifies.

## Grafana datasource permissions

Grafana's ProdCH datasource connects as `monitor_user`, which has `SELECT` on `platform` and `pulse` but `dictGet` only on `pulse`. The query therefore avoids `platform.*_d` dictionaries:
- test casinos and fun currencies are filtered via `platform.mysql_whitelabels` / `platform.mysql_currency` (`FINAL`, not deleted). Same sets as the dictionaries: 15 test casinos, 6 fun currencies.
- game names come from `pulse.games_d`, which has the same source as `platform.games_d`.

Alternative: an admin runs `GRANT dictGet ON platform.* TO monitor_user`.

## Performance notes

- The whole query (slot + live) runs in about 0.06–0.5 s.
- `bets FINAL`: the sort key starts with `toStartOfHour(createdAt)`, so the 24h filter prunes to about 80k rows and `FINAL` is cheap.
- The slot part reads the whole of `agg_slots_ggr`: about 2.2M rows (~40 MB). The table size is bounded by `TTL bucket + 8 days`.
- The sort key is `(gameId, wlId, wlUserId, bucket)`, so the `bucket` filter does not prune through the primary index. At the current size this does not matter. If the table grows (more games or a longer TTL), add a `minmax` skip index on `bucket`, or a projection ordered by `bucket`.
- No JOINs. Game names come from an O(1) `dictGet` on `platform.games_d`.
