-- =====================================================================
-- Alert: Bet volume drop per game (vs running 24h average) — CRITICAL
-- Source : ProdCH
--   slot -> platform.slot_actions (rows with betSize > 0; ~1 min ingest lag)
--   live -> platform.bets
--   test casinos excluded; fun-money traffic kept (it is real traffic,
--   an outage hits it too)
-- Logic  : bets in the last complete 15-min bucket vs the average 15-min
--          volume over the previous 24h (the last hour is left out of the
--          baseline so an ongoing outage does not drag it down)
-- Breach : per game   < 25% of baseline (volume down >= 75%)
--          ALL_GAMES  < 50% of baseline (platform-wide outage)
--          Grafana pending period 1h = "below threshold for more than 1 hour"
-- Value  : pct_of_baseline (single numeric column); only breaching rows are
--          returned, so an empty result = OK
-- Runs   : every 5 min, ~1-2 s (reads ~25 M slot_actions rows)
-- =====================================================================
WITH
    -- last COMPLETE 15-min bucket, with 2 min slack for ingestion lag
    toStartOfFifteenMinutes(now('UTC') - INTERVAL 2 MINUTE) AS cur_end,
    cur_end - INTERVAL 15 MINUTE                            AS cur_start,
    cur_start - INTERVAL 1 HOUR                             AS base_end,
    base_end - INTERVAL 24 HOUR                             AS base_start,
    96                                                      AS buckets_in_24h,
    25.0                                                    AS game_threshold_pct,
    50.0                                                    AS total_threshold_pct,
    25                                                      AS min_baseline_bets,  -- per 15 min (= 100 / h)
    -- presenter studios with scheduled breaks: volume drops to ~0 several
    -- times a day by design, so they would alert constantly
    ['kyiv_pros_alex', 'kyiv_pros_julia',
     'x777_roulette_maria', 'x777_roulette_valeriy']        AS excluded_games,

    counts AS
    (
        SELECT 'slot' AS source, gameId,
               countIf(createdAt >= cur_start) AS cur_bets,
               countIf(createdAt <  base_end)  AS base_bets
        FROM platform.slot_actions
        WHERE createdAt >= base_start AND createdAt < cur_end
          AND betSize > 0
          AND wlId NOT IN (SELECT wlId FROM platform.mysql_whitelabels FINAL
                           WHERE isTest AND _peerdb_is_deleted = 0)
        GROUP BY gameId

        UNION ALL

        SELECT 'live' AS source, gameId,
               countIf(createdAt >= cur_start) AS cur_bets,
               countIf(createdAt <  base_end)  AS base_bets
        FROM platform.bets
        WHERE createdAt >= base_start AND createdAt < cur_end
          AND wlId NOT IN (SELECT wlId FROM platform.mysql_whitelabels FINAL
                           WHERE isTest AND _peerdb_is_deleted = 0)
        GROUP BY gameId
    ),

    scored AS
    (
        -- per game (a game with 0 bets now still has a baseline row, so it is caught)
        SELECT source, gameId, cur_bets, base_bets / buckets_in_24h AS baseline,
               game_threshold_pct AS threshold_pct
        FROM counts
        WHERE NOT has(excluded_games, toString(gameId))

        UNION ALL

        -- platform total
        SELECT 'all' AS source, 'ALL_GAMES' AS gameId,
               sum(cur_bets), sum(base_bets) / buckets_in_24h,
               total_threshold_pct
        FROM counts
    )

SELECT
    gameId                                                                 AS game_id,
    if(gameId = 'ALL_GAMES', 'All games (platform total)',
       dictGetOrDefault('pulse.games_d', 'name', toString(gameId), gameId)) AS game_name,
    source                                                                 AS game_type,
    toString(threshold_pct)                                                AS threshold_pct,
    -- single numeric column: bets in the last 15 min as % of the 24h average
    round(100 * cur_bets / baseline, 1)                                    AS pct_of_baseline
FROM scored
WHERE baseline >= min_baseline_bets
  AND 100 * cur_bets / baseline < threshold_pct
ORDER BY pct_of_baseline
LIMIT 500
