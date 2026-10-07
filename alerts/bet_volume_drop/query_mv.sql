-- =====================================================================
-- Alert: Bet volume drop — version reading bi_sandbox.bets_per_minute
-- Same logic, thresholds and output as query.sql; use it once the minute
-- table from minute_table.sql exists and has >= 25 h of data.
-- Reads ~0.5 M pre-aggregated rows instead of ~50 M raw rows.
-- =====================================================================
WITH
    toStartOfFifteenMinutes(now('UTC') - INTERVAL 2 MINUTE) AS cur_end,
    cur_end - INTERVAL 15 MINUTE                            AS cur_start,
    cur_start - INTERVAL 1 HOUR                             AS base_end,
    base_end - INTERVAL 24 HOUR                             AS base_start,
    96                                                      AS buckets_in_24h,
    25.0                                                    AS game_threshold_pct,
    50.0                                                    AS total_threshold_pct,
    25                                                      AS min_baseline_bets,
    ['kyiv_pros_alex', 'kyiv_pros_julia',
     'x777_roulette_maria', 'x777_roulette_valeriy']        AS excluded_games,

    counts AS
    (
        SELECT source, gameId,
               uniqMergeIf(bets, minute >= cur_start) AS cur_bets,
               uniqMergeIf(bets, minute <  base_end)  AS base_bets
        FROM bi_sandbox.bets_per_minute
        WHERE minute >= base_start AND minute < cur_end
          AND wlId NOT IN (SELECT wlId FROM platform.mysql_whitelabels FINAL
                           WHERE isTest AND _peerdb_is_deleted = 0)
        GROUP BY source, gameId
    ),

    scored AS
    (
        SELECT source, gameId, cur_bets, base_bets / buckets_in_24h AS baseline,
               game_threshold_pct AS threshold_pct
        FROM counts
        WHERE NOT has(excluded_games, toString(gameId))

        UNION ALL

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
    round(100 * cur_bets / baseline, 1)                                    AS pct_of_baseline
FROM scored
WHERE baseline >= min_baseline_bets
  AND 100 * cur_bets / baseline < threshold_pct
ORDER BY pct_of_baseline
LIMIT 500
