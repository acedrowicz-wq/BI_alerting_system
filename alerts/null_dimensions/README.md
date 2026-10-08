# NULL / missing key dimensions in the bet feed (3 alerts)

Catches upstream developer errors (NULLs, empty strings, ids that do not exist in reference tables) in the incoming bet feed before they reach Tableau.

| Rule | SQL | Field(s) | Missing means |
|---|---|---|---|
| Missing casino | [`casino.sql`](casino.sql) | `wlId` | empty, or not in `platform.mysql_whitelabels` (Tableau shows a NULL `casino_name`) |
| Missing country | [`country.sql`](country.sql) | `country` | not a 2-letter uppercase ISO code (empty included) |
| Missing other key fields | [`other_fields.sql`](other_fields.sql) | `gameId`, `currency`, `wlUserId`, EUR conversion | empty, unknown id, or stake > 0 with `convertedBet = 0` |

- **Feed:** `platform.slot_actions` (slots) and `platform.bets` (live). Test casinos are excluded.
- **Why not `IS NULL`:** these columns are not `Nullable` in ClickHouse. PeerDB writes an upstream NULL as `''` / `0`, so "missing" is checked as empty or unknown.
- **Window (AC1):** the last complete minute, 2 min behind `now()` to cover the ~1 min ingestion lag.
- **Value:** `null_pct`, the share of records in that minute with the field missing. A single bad record already gives a value > 0, e.g. 1 of 13.5k slot rows = 0.0074%.
- **Baseline:** 7 days and ~174 M slot rows plus live, with 0 affected records. Any hit is a real error.
- **Cost:** ~20 ms per run, ~30–90k rows read.

## Grafana (same steps for each of the 3 rules)

1. **Query A:** the rule's `.sql`, datasource ProdCH, Table format.
2. **B — Reduce:** Last of A, mode Drop non-numeric.
3. **C — Threshold (AC2):** B **IS ABOVE 0**.
4. **Evaluation group:** a new group `BI data quality` with interval **1m**. The 5m BI group would skip 4 of every 5 minutes.
5. **Pending period:** **None**. A single bad minute is enough.
6. **No data → Normal** (a minute with no traffic). **Error → Error.**
7. **Labels:** `team=bi`, `alert_scope=null_dimensions`, `severity=high`.
8. **Contact point (AC3):** the Slack contact point posting to **#bi-alerts**.

Each rule returns one row per feed (`slot`, `live`) and field, so every (feed, field) pair is its own alert instance. They are labelled `feed_type` and `field`.

### Annotations

Summary:
```
Missing {{ $labels.field }} in the {{ $labels.feed_type }} bet feed
```
Description:
```
*Field:* {{ $labels.field }}  ·  *Feed:* {{ $labels.feed_type }}
*Records with the field missing (last minute):* {{ printf "%.4f" $values.B.Value }}%
_Upstream sent NULL / empty values or ids unknown to the reference tables. Check the latest deployment before it reaches Tableau._
```

### Test

Simulated on ProdCH by flagging `country = 'DE'` as missing: 2.7% (slot) and 6.1% (live). A single flagged record: 0.0074%.
