# Active game with zero traffic (0 bets and 0 players in the last hour)

Flags games that are normally played at this time of day but had no bets and no players in the last 60 minutes. The usual cause is a frontend or lobby issue that hides the game, so operators can be notified.

- **SQL:** [`query.sql`](query.sql)
- **Datasource:** ProdCH (ClickHouse)

## Logic

| AC | How |
|---|---|
| AC1: evaluate all active games | Every game in `platform.mysql_games` (live rows) is classified. Last-hour bets and unique players come from `platform.slot_actions` (`betSize > 0`) and `platform.bets` (live). Test casinos are excluded. |
| AC2: exactly 0 bets and 0 players | The window is the last 60 min, ending 2 min before `now()` to cover ingestion lag. A game with no rows at all also counts as 0. |
| AC3: filter out naturally inactive games | Each game falls into one lifecycle stage (table below). Only established games and new releases are monitored. |

| Lifecycle | Rule (from `platform.agg_daily`) | Monitored? |
|---|---|---|
| Pre-launch | In the catalog but never had a bet | no |
| Retired / dead | No bets yesterday and not a new release | no |
| Established | Bets yesterday, plus ≥ 5 bets in this **clock hour on every day** of the last 7 (min 2 full days of `bi_sandbox.bets_per_minute`) | yes |
| New release | First bet ever within the last **7 days** (catalog `createdAt` is not used: games go live 2 days to 8 months after being added) | yes, once it had ≥ 20 bets in the 24 h before the window |
| Presenter studios | `kyiv_pros_alex`, `kyiv_pros_julia`, `x777_roulette_*`: scheduled but irregular breaks | no (excluded explicitly) |

**Value:** `expected_bets`, the bets normally seen in one hour. For established games it is the same-clock-hour average; for new releases it is the last-24h hourly average. Only breaching games are returned, so an empty result means OK.

**Labels:** `game_id`, `game_name`, `game_type`, `lifecycle` (`established` / `new release`).

### Checks (2026-10-09)

- **Classification of the 46 catalog games:**
  - 34 established and monitored;
  - 2 retired: `enchanted_forest` (last bet 2026-04-14) and `ua_branded_roulette` (last bet 2025-01-30);
  - 6 pre-launch, never bet: `TestGameeeeee`, `eg_mark_roulette`, `kyiv_pros_kate/mary/kris/val`;
  - 4 excluded studios;
  - no new releases at the moment.
- **Live result:** empty. Runs in ~1–2 s, also with `enable_analyzer = 0`.
- **Simulation:** treating Phoenix Roulette (first bet 2026-09-22) as a new release and removing its last-hour bets returned it with expected_bets 321.2.

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
No traffic: {{ $labels.game_name }} ({{ $labels.lifecycle }}) — 0 bets, 0 players in the last hour
```
Description:
```
*Game:* {{ $labels.game_name }} (`{{ $labels.game_id }}`, {{ $labels.game_type }}, {{ $labels.lifecycle }})
*Last hour:* 0 bets, 0 players · *usually per hour:* ~{{ humanize $values.B.Value }} bets
_Active game went silent. Check the lobby / frontend display and notify operators._
```
