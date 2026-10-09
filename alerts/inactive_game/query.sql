-- =====================================================================
-- Alert: Active game with zero traffic in the last hour
-- Source : ProdCH
--   catalog   -> platform.mysql_games (live rows)
--   lifecycle -> platform.agg_daily (first bet day, bets yesterday)
--   last hour -> platform.slot_actions (betSize > 0) + platform.bets (live)
--   history   -> bi_sandbox.bets_per_minute (same clock hour on previous days,
--                and the 24 h before the window)
--   test casinos excluded everywhere
-- AC1    : every game in the catalog is evaluated
-- AC2    : alert when a game has exactly 0 bets AND 0 unique players in the
--          last 60 minutes (window ends 2 min before now for ingestion lag)
-- AC3    : naturally inactive games are filtered out:
--   * pre-launch     : in the catalog but never had a bet            -> skipped
--   * retired / dead : no bets yesterday and not a new release        -> skipped
--   * established    : bets yesterday AND >= 5 bets in this clock hour on
--                      EVERY day of the last 7 (min 2 days of history) -> monitored
--   * new release    : first bet within the last 7 days; no hourly history
--                      yet, so monitored once it had >= 20 bets in the
--                      24 h before the window
--   * presenter studios with scheduled but irregular breaks are excluded
-- Value  : expected_bets = bets normally seen in one hour (established: same
--          clock hour average; new release: last-24h hourly average).
--          Only breaching games are returned, so an empty result = OK
-- Runs   : every 5 min, ~0.3-0.6 s
-- =====================================================================
WITH
    toStartOfMinute(now('UTC') - INTERVAL 2 MINUTE) AS win_end,
    win_end - INTERVAL 1 HOUR                       AS win_start,
    7                                               AS history_days,
    2                                               AS min_history_days,
    5                                               AS min_bets_per_history_day,
    7                                               AS new_release_days,
    20                                              AS min_bets_24h_new_release,
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

    -- lifecycle per game: first day with bets ever, bets yesterday (settlement day, UTC)
    game_life AS
    (
        SELECT gameId,
               min(day)                     AS first_bet_day,
               sumIf(day_bets, day = yesterday()) AS bets_yday
        FROM
        (
            SELECT gameId, day, sumMerge(countBetsState) AS day_bets
            FROM platform.agg_daily
            WHERE isTest = 0
            GROUP BY gameId, day
            HAVING day_bets > 0
        )
        GROUP BY gameId
    ),

    -- bets in the same 60-min clock window on each previous day
    per_day AS
    (
        SELECT
            gameId,
            intDiv(toUnixTimestamp(win_end) - toUnixTimestamp(minute) - 1, 86400) AS day_offset,
            uniqMerge(bets)                                             AS day_bets
        FROM bi_sandbox.bets_per_minute
        WHERE minute >= win_start - toIntervalDay(history_days)
          AND minute <  win_end   - INTERVAL 1 DAY
          AND (toUnixTimestamp(win_end) - toUnixTimestamp(minute) - 1) % 86400 < 3600
          AND wlId NOT IN test_wls
        GROUP BY gameId, day_offset
    ),

    hour_profile AS
    (
        SELECT gameId,
               countIf(day_bets >= min_bets_per_history_day) AS busy_days,
               round(avg(day_bets), 1)                       AS hour_avg_bets
        FROM per_day
        WHERE day_offset BETWEEN 1 AND covered_days
        GROUP BY gameId
    ),

    -- the 24 h right before the window (used for new releases and for game_type)
    prev_24h AS
    (
        SELECT gameId, any(source) AS src, uniqMerge(bets) AS bets_24h
        FROM bi_sandbox.bets_per_minute
        WHERE minute >= win_start - INTERVAL 1 DAY AND minute < win_start
          AND wlId NOT IN test_wls
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
    ),

    candidates AS
    (
        SELECT
            l.gameId                                                    AS gid,
            if(l.first_bet_day >= today() - new_release_days,
               'new release', 'established')                            AS lifecycle_stage,
            l.bets_yday                                                 AS bets_yday,
            ifNull(h.busy_days, 0)                                      AS busy_days,
            ifNull(h.hour_avg_bets, 0)                                  AS hour_avg_bets,
            ifNull(p.bets_24h, 0)                                       AS bets_24h,
            ifNull(p.src, '')                                           AS src,
            ifNull(t.bets_1h, 0)                                        AS bets_1h,
            ifNull(t.players_1h, 0)                                     AS players_1h
        FROM game_life AS l                      -- only games that ever had a bet (pre-launch skipped)
        LEFT JOIN hour_profile AS h ON h.gameId = l.gameId
        LEFT JOIN prev_24h     AS p ON p.gameId = l.gameId
        LEFT JOIN now_traffic  AS t ON t.gameId = l.gameId
        WHERE l.gameId IN (SELECT gameId FROM catalog)
          AND NOT has(excluded_games, toString(l.gameId))
    )

SELECT
    gid                                                                    AS game_id,
    dictGetOrDefault('pulse.games_d', 'name', toString(gid), gid)         AS game_name,
    src                                                                    AS game_type,
    lifecycle_stage                                                        AS lifecycle,
    -- bets normally seen in one hour
    if(lifecycle_stage = 'established', hour_avg_bets, round(bets_24h / 24, 1)) AS expected_bets
FROM candidates
WHERE bets_1h = 0                                -- AC2: exactly 0 bets ...
  AND players_1h = 0                             -- ... and 0 unique players
  AND (
        -- established game, played yesterday and always busy at this hour
        (lifecycle_stage = 'established'
         AND bets_yday > 0
         AND covered_days >= min_history_days
         AND busy_days = covered_days)
     OR
        -- new release that is live (played in the last 24 h)
        (lifecycle_stage = 'new release'
         AND bets_24h >= min_bets_24h_new_release)
      )
ORDER BY expected_bets DESC
SETTINGS join_use_nulls = 1
