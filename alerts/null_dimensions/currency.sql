-- =====================================================================
-- Alert: Missing currency in the bet feed
-- Source : ProdCH, incoming bet feed
--   slot -> platform.slot_actions   live -> platform.bets
--   (test casinos excluded; ~1 min ingestion lag)
-- Why    : key columns are not Nullable in ClickHouse, so an upstream NULL
--          lands as '' (or 0) or as an id missing from its dictionary table.
--          In Tableau this shows up as NULL currency.
-- Window : the last complete minute, 2 min behind now() for ingestion lag
-- Value  : null_pct = % of records in the window with the field missing
--          (any affected record gives a value > 0)
-- Alert  : Threshold IS ABOVE 0, evaluated every 1 min, pending None
-- Baseline (7 days, ~174 M slot rows + live): 0 affected records.
-- =====================================================================
WITH
    toStartOfMinute(now('UTC') - INTERVAL 2 MINUTE) AS win_end,
    win_end - INTERVAL 1 MINUTE                     AS win_start,

    test_wls AS (SELECT wlId FROM platform.mysql_whitelabels FINAL
                 WHERE isTest AND _peerdb_is_deleted = 0),

    feed AS
    (
        SELECT 'slot' AS source, wlId, country, gameId, currency, wlUserId, betSize, convertedBet
        FROM platform.slot_actions
        WHERE createdAt >= win_start AND createdAt < win_end
          AND wlId NOT IN test_wls

        UNION ALL

        SELECT 'live' AS source, wlId, country, gameId, currency, wlUserId, betSize, convertedBet
        FROM platform.bets
        WHERE createdAt >= win_start AND createdAt < win_end
          AND wlId NOT IN test_wls
    ),

    flagged AS
    (
        SELECT
            source,
            (currency = '' OR currency NOT IN (SELECT symbol FROM platform.mysql_currency FINAL
                                           WHERE _peerdb_is_deleted = 0)) AS miss_currency
        FROM feed
    )

SELECT
    source                                                 AS feed_type,
    f.1                                                    AS field,
    -- % of records with the field missing; never rounds a real hit down to 0
    if(countIf(f.2) = 0, 0,
       greatest(round(100 * countIf(f.2) / count(), 4), 0.0001)) AS null_pct
FROM flagged
ARRAY JOIN [('currency', miss_currency)] AS f
GROUP BY feed_type, field
ORDER BY null_pct DESC
