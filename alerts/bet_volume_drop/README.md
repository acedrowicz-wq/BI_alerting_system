# Bet volume drop alert (per game + platform total) — CRITICAL

Detects frontend, server or integration outages: a game's bet volume falls far below its running 24h average and stays there for more than 1 hour.

- **Datasource:** ProdCH (ClickHouse)
- **SQL:**
  - [`query.sql`](query.sql) — raw tables, works today (~1 s, ~50 M rows read).
  - [`query_mv.sql`](query_mv.sql) — same output, reads the per-minute rollup from [`minute_table.sql`](minute_table.sql).

## Logic

| Step | What it does |
|---|---|
| Volume | Bets per game. Slots: `platform.slot_actions` with `betSize > 0`. Live: `platform.bets`. Test casinos are excluded. Fun-money traffic is kept, because it is real traffic and an outage hits it too. |
| Current | Bets in the last **complete 15-min bucket**, with 2 min of slack for ingestion lag (~1 min). |
| Baseline (AC2) | Average 15-min volume over the **previous 24h**. The most recent hour is left out of the baseline, so an ongoing outage does not drag it down. |
| Breach | Per game: current < **25%** of baseline. `ALL_GAMES` (platform total): current < **50%** of baseline. |
| Duration (AC3) | Grafana pending period **1h**: the alert fires only after a full hour below the threshold. |
| Gate | Games with a baseline under 25 bets per 15 min (100 per hour) are skipped. |
| Excluded | Presenter studios with scheduled breaks: `kyiv_pros_alex`, `kyiv_pros_julia`, `x777_roulette_maria`, `x777_roulette_valeriy`. Their volume drops to ~0 several times a day by design. |
| Value | `pct_of_baseline`: bets in the last 15 min as a % of the 24h average. Only breaching rows are returned, so an empty result means OK. |

### Backtest (7 days, 15-min buckets, a breach counts only after 1h below threshold)

- **Big slots:** 0 alerts.
- **Mid live tables** (`greek`, `phoenix`, `everyspin`, `energy`): 1–4 alert windows per week each.
- **Small slots** (`pedro_spicy`, `power_gems`, `thor_hit_the_bonus`, `lightning_crown`): a few alert windows per week. Each affected one game at a time, consistent with a game being switched off at a casino.
- **Platform total:** never below 62% of its 24h average, so the 50% threshold had no false alarms.
- **Excluded studios:** 20–50 alert windows per week each without the exclusion.

## Grafana alert rule

Same setup as the RTP spike alert, with these differences:

1. **Query A:** `query.sql`, Table format. No `time` column.
2. **B — Reduce:** Last of A, mode Drop non-numeric.
3. **C — Threshold:** B **IS ABOVE -1**. The breach logic lives in the SQL. The value can be **0** (no bets at all), so do not use "> 0".
4. **Evaluation group:** every 5m. **Pending period: 1h.**
5. **No data → Normal. Error → Error.**
6. **Labels:** `severity=critical`, `team=bi`, `alert=bet_volume_drop`.
7. **Contact point:** the BI Slack contact point (it uses the `bi-slack` template).

### Annotations

Summary:
```
Bet volume drop: {{ $labels.game_name }}
```
Description:
```
*Game:* {{ $labels.game_name }} (`{{ $labels.game_id }}`, {{ $labels.game_type }})
*Bets in the last 15 min:* {{ humanize $values.B.Value }}% of the 24h average (threshold {{ $labels.threshold_pct }}%)
_Below threshold for over 1 hour. Check frontend / game server / casino integration._
```

## Per-minute rollup (optional, recommended)

`minute_table.sql` creates `bi_sandbox.bets_per_minute`:
- grain: minute × slot/live × game × casino;
- `uniqState(mongoId)`, so PeerDB row re-inserts are not double counted;
- TTL 8 days, ~0.5 M rows/day;
- two materialized views fill it from `slot_actions` and `bets`, plus a 2-day backfill.

A ClickHouse admin has to run it, because the BI and Grafana users are read-only. Then switch query A to `query_mv.sql`, which gives the same output while reading ~100× less data.

The rollup keeps `wlId`, so the same table can later drive a per-casino volume alert (a single casino integration going down).
