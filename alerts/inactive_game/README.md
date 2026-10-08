# Active game with zero traffic (0 bets and 0 players in the last hour)

Flags games that are normally played at this time of day but had no bets and no players in the last 60 minutes. The usual cause is a frontend or lobby issue that hides the game, so operators can be notified.

- **SQL:** [`query.sql`](query.sql)
- **Datasource:** ProdCH (ClickHouse)

## Logic

| AC | How |
|---|---|
| AC1: evaluate all active games | Every game in `platform.mysql_games` (live rows) is checked. Last-hour bets and unique players come from `platform.slot_actions` (`betSize > 0`) and `platform.bets` (live). Test casinos are excluded. |
| AC2: exactly 0 bets and 0 players | The window is the last 60 min, ending 2 min before `now()` to cover ingestion lag. The game has `bets_1h = 0` and `players_1h = 0`. A game with no rows at all also counts as 0. |
| AC3: filter out naturally inactive games | A game is expected to have traffic now only if it had ≥ 5 bets in the **same clock hour on every day** of the history window. The window is the last 7 days, read from `bi_sandbox.bets_per_minute`, and needs at least 2 full days. Games never played at this hour, or not played recently, are skipped. Presenter studios with scheduled but irregular breaks are excluded explicitly: `kyiv_pros_*`, `x777_roulette_*`. |

**Value:** `expected_bets`, the average bets in this clock hour over the history days. Only breaching games are returned, so an empty result means OK.

### Checks (2026-10-08)

- **Coverage:** 46 games in the catalog. 34 are "active at this hour". 8 had no traffic and 4 are the excluded studios.
- **Live result:** empty, because every active game had traffic. Runs in ~0.13 s and also works with `enable_analyzer = 0`.
- **Simulation:** removing Pedro Spicy's slot traffic from the last hour returned `pedro_spicy`, with expected_bets 2142.5.
- **History:** over ~3 days of per-minute data, the only zero-bet hours belonged to the excluded studios.

### Not used: `platform.mysql_gameModeHistory`

This table logs MAINTENANCE windows for live games and would be the ideal AC3 filter. However, PeerDB replicates `dateStartedAt` and `dateFinishedAt` as `Date32`, so the time of day is lost, and `dateFinishedAt` is always `1900-01-01`. Once Data Engineering maps these columns to `DateTime64`, this alert can also skip games that are in maintenance.

## Grafana

Create the rule with **+ New alert rule**. Do not use Duplicate, see the bet_volume_drop README.

1. **Query A:** `query.sql`, Table format.
2. **B — Reduce:** Last of A, mode Drop non-numeric.
3. **C — Threshold:** B **IS ABOVE 0**.
4. **Evaluation group:** BI evaluation group (5m). **Pending period: None.** The query already requires a full hour of silence.
5. **No data → Normal. Error → Error.**
6. **Labels:** `team=bi`, `alert_scope=inactive_game`, `severity=high`.
7. **Contact point:** #bi-alerts.

### Annotations

Summary:
```
No traffic: {{ $labels.game_name }} (0 bets, 0 players in the last hour)
```
Description:
```
*Game:* {{ $labels.game_name }} (`{{ $labels.game_id }}`, {{ $labels.game_type }})
*Last hour:* 0 bets, 0 players · *usually at this hour:* ~{{ humanize $values.B.Value }} bets
_Active game went silent. Check the lobby / frontend display and notify operators._
```
