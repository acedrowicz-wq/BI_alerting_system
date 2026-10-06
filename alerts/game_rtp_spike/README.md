# Game RTP spike alert (4h / 12h vs 94% target)

Covers **all games**: slots and live. Fires when a game's RTP over a rolling **4h** or **12h** window drastically exceeds the
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
| Windows | The last 16 / 48 **complete** 15-min buckets (4h / 12h), both computed in one pass. |
| High-roller suppression | `rtp_ex_top_pct` = RTP after removing the net win of the single biggest winner in the window. A single jackpot cannot trigger the alert on its own; only a broad-based spike can. |
| Volume gate (AC2) | **Slot** 4h: bet ≥ €10k, ≥ 50 players, ≥ 5k actions · 12h: ≥ €30k, ≥ 100 players, ≥ 15k actions. **Live** 4h: bet ≥ €3k, ≥ 20 players, ≥ 300 bets · 12h: ≥ €8k, ≥ 30 players, ≥ 600 bets. Live volume is 10–50× lower than slots; with the slot gates, 4 of the 11 live games would never be evaluated. |
| Threshold | 4h: `rtp_ex_top_pct` > **115%** (94 + 21 pp) · 12h: > **108%** (94 + 14 pp) |
| Alert value | `rtp_excess_pp = rtp_ex_top_pct − threshold`. The rule fires when the value is above **0**. |

### Backtest (7 days, 2026-09-29 → 2026-10-06, hourly window ends)

| Window | Windows with raw RTP above threshold | After removing the top winner | Episodes |
|---|---|---|---|
| slot 4h  | 119 (> 115%) | 4  | thor_1000, hotfire_diamonds_2, thor_hit_the_bonus |
| slot 12h | 124 (> 108%) | 6  | pedro_spicy (01.10), thor_1000 (29.09) |
| live 4h  | — | 5  | greek_roulette (03.10, 05.10), wonder_wheel, phoenix_roulette |
| live 12h | — | 5  | greek_roulette (04.10), wonder_wheel, everyspin_x320_roulette |

Every raw spike in the period came from a single player. The remaining episodes were sustained
over-payouts across hundreds of players, which is what this alert is meant to catch.

## Grafana alert rule

1. **Query A:** paste `query.sql`. Datasource ProdCH, Query Type **Table**.
   - Leave out `$__timeFilter`: the windows are rolling and anchored to `now()`, not to the dashboard range.
2. **Expression B (Reduce):** input A, function **Last**, mode **Drop non-numeric values**.
3. **Expression C (Threshold):** input B, **IS ABOVE 0**. Set this as the alert condition.
4. **Evaluation:** every **5m**, pending period **15m** (3 consecutive breaches).
5. **No data / Error handling:** No data → **OK**. Error → **Error**.
6. **Labels:** `team=bi`, `alert=game_rtp_spike`. Route this label to the dedicated Slack contact point (AC3).

Each game and window becomes its own alert instance, with labels `game_id`, `game_name`,
`game_type` (`slot` / `live`), `window` and `threshold_pct`.

### Optional detail queries for the Slack message

Grafana alerting accepts **one numeric column per query**. To show more numbers in the message,
duplicate query A as B2–E and swap the last `SELECT` column for one of the commented
alternatives in `query.sql`: `rtp_raw_pct`, `rtp_ex_top_pct`, `bet_eur`, `players`. Grafana
matches these to query A by their labels.

### Slack template (summary / description)

```
:rotating_light: RTP spike — {{ $labels.game_name }} ({{ $labels.game_id }}, {{ $labels.game_type }})
Window: {{ $labels.window }} | Target: 94% | Alert threshold: {{ $labels.threshold_pct }}%
RTP (excl. top winner): {{ humanize $values.C2.Value }}%  (+{{ humanize $values.A.Value }} pp over threshold)
Raw RTP: {{ humanize $values.B2.Value }}% | Bets: €{{ humanize $values.D.Value }} | Players: {{ $values.E.Value }}
Not explained by a single high-roller. Check math version / game config / recent releases.
```

If you skip the detail queries, use only `$labels.*` and `$values.A.Value`.

## Tuning

Change the constants in the `scored` CTE:

- `target_rtp_pct` (94)
- the `+21` / `+14` pp offsets
- the `min_*` volume gates

To use per-game targets, `platform.slot_rtp_target` holds the target per game and math version.
The ggr rollup has no math-version column, though, so for now 94% stays the single target, as
the Jira ticket specifies.

## Performance notes

- The whole query (slot + live) runs in about 0.06–0.5 s.
- `bets FINAL`: the sort key starts with `toStartOfHour(createdAt)`, so the 12h filter prunes to about 40k rows and `FINAL` is cheap.
- The slot part reads the whole of `agg_slots_ggr`: about 2.2M rows (~40 MB). The table size is bounded by `TTL bucket + 8 days`.
- The sort key is `(gameId, wlId, wlUserId, bucket)`, so the `bucket` filter does not prune through the primary index. At the current size this does not matter. If the table grows (more games or a longer TTL), add a `minmax` skip index on `bucket`, or a projection ordered by `bucket`.
- No JOINs. Game names come from an O(1) `dictGet` on `platform.games_d`.
