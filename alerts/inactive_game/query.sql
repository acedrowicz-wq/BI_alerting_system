-- =====================================================================
-- Alert: Active game with zero traffic in the last hour
-- Source : ProdCH
--   catalog   -> platform.mysql_games (live rows)
--   last hour -> platform.slot_actions (betSize > 0) + platform.bets (live)
--   history   -> bi_sandbox.bets_per_minute (same clock hour, previous 7 days)
--   test casinos excluded everywhere
-- AC1    : every game in the catalog is evaluated
-- AC2    : alert when a game has exactly 0 bets AND 0 unique players in the
--          last 60 minutes (window ends 2 min before now for ingestion lag)
-- AC3    : "naturally inactive" games are filtered out. A game is expected to
--          have traffic now only if, in the same clock hour, it had >= 5 bets
--          on EVERY day of the last 7 (at least 2 days of history required).
--          Presenter studios with scheduled but irregular breaks are excluded.
-- Value  : expected_bets = average bets in this clock hour over the history
--          days (single numeric column); only breaching games are returned,
--          so an empty result = OK
-- Runs   : every 5 min, ~0.1-0.5 s
-- =====================================================================
WITH
    toStartOfMinute(now('UTC') - INTERVAL 2 MINUTE) AS win_end,
    win_end - INTERVAL 1 HOUR                       AS win_start,
    7                                               AS history_days,
    2                                               AS min_history_days,
    5                                               AS min_bets_per_history_day,
    ['kyiv_pros_alex', 'kyiv_pros_julia',
     'x777_roulette_maria', 'x777_roulette_valeriy'] AS excluded_games,

    test_wls AS (SELECT wlId FROM platform.mysql_whitelabels FINAL
                 WHERE isTest AND _peerdb_is_deleted = 0),

    catalog AS (SELECT gameId FROM platform.mysql_games FINAL
                WHERE _peerdb_is_deleted = 0),

    -- history days fully covered by the per-minute table (it only exists since its creation)
    least(history_days,
          intDiv(toUnixTimestamp(win_start)
                 - toUnixTimestamp((SELECT min(minute) FROM bi_sandbox.bets_per_minute)), 86400)) AS covered_days,

    -- bets in the same 60-min clock window on each of the previous 7 days
    per_day AS
    (
        SELECT
            gameId,
            any(source)                                                 AS src,
            intDiv(toUnixTimestamp(win_end) - toUnixTimestamp(minute) - 1, 86400) AS day_offset,
            uniqMerge(bets)                                             AS day_bets
        FROM bi_sandbox.bets_per_minute
        WHERE minute >= win_start - toIntervalDay(history_days)
          AND minute <  win_end   - INTERVAL 1 DAY
          AND (toUnixTimestamp(win_end) - toUnixTimestamp(minute) - 1) % 86400 < 3600
          AND wlId NOT IN test_wls
        GROUP BY gameId, day_offset
    ),

    expected AS
    (
        SELECT
            gameId,
            any(src)                     AS game_type,
            countIf(day_bets >= min_bets_per_history_day) AS busy_days,
            round(avg(day_bets), 1)      AS expected_bets
        FROM per_day
        WHERE day_offset BETWEEN 1 AND covered_days
        GROUP BY gameId
    ),

    last_hour AS
    (
        SELECT gameId, count() AS bets, uniqExact(wlId, wlUserId) AS players
        FROM platform.slot_actions
        WHERE createdAt >= win_start AND createdAt < win_end
          AND betSize > 0
          AND wlId NOT IN test_wls
        GROUP BY gameId

        UNION ALL

        SELECT gameId, count() AS bets, uniqExact(wlId, wlUserId) AS players
        FROM platform.bets
        WHERE createdAt >= win_start AND createdAt < win_end
          AND wlId NOT IN test_wls
        GROUP BY gameId
    ),

    now_traffic AS
    (
        SELECT gameId, sum(bets) AS bets_1h, sum(players) AS players_1h
        FROM last_hour
        GROUP BY gameId
    )

SELECT
    e.gameId                                                               AS game_id,
    dictGetOrDefault('pulse.games_d', 'name', toString(e.gameId), e.gameId) AS game_name,
    e.game_type                                                            AS game_type,
    e.expected_bets                                                        AS expected_bets
FROM expected AS e
LEFT JOIN now_traffic AS t ON t.gameId = e.gameId
WHERE e.gameId IN (SELECT gameId FROM catalog)
  AND NOT has(excluded_games, toString(e.gameId))
  AND covered_days >= min_history_days
  AND e.busy_days = covered_days                  -- traffic in this hour on every history day
  AND ifNull(t.bets_1h, 0) = 0                   -- AC2: exactly 0 bets ...
  AND ifNull(t.players_1h, 0) = 0                -- ... and 0 unique players
ORDER BY expected_bets DESC
SETTINGS join_use_nulls = 1
