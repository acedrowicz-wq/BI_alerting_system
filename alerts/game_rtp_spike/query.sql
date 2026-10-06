-- =====================================================================
-- Alert: Game RTP spike vs 94% target (rolling 4h / 12h)
-- Source : ProdCH · platform.agg_slots_ggr (15-min buckets per game /
--          casino / player; settled real-money slot actions in EUR;
--          test casinos + fun currencies already excluded; TTL 8 days)
-- Grain  : one row per (game_id, window) that passes the volume gate
-- Value  : rtp_excess_pp  -> alert when > 0
-- Runs   : every 5 min, ~0.1-0.5 s, reads ~2 M rows (whole table, TTL-bounded)
-- =====================================================================
WITH
    94.0                                         AS target_rtp_pct,
    -- evaluate on COMPLETE 15-min buckets only (stable value, no partial bucket)
    toStartOfFifteenMinutes(now('UTC'))          AS window_end,
    window_end - INTERVAL 4 HOUR                 AS start_4h,
    window_end - INTERVAL 12 HOUR                AS start_12h,

    -- 1) per player, both windows in a single pass
    per_player AS
    (
        SELECT
            gameId,
            wlId,
            wlUserId,
            sumIf(betEur,  bucket >= start_4h) AS bet_4h,
            sumIf(winEur,  bucket >= start_4h) AS win_4h,
            sumIf(actions, bucket >= start_4h) AS act_4h,
            sum(betEur)                        AS bet_12h,
            sum(winEur)                        AS win_12h,
            sum(actions)                       AS act_12h
        FROM platform.agg_slots_ggr
        WHERE bucket >= start_12h
          AND bucket <  window_end
        GROUP BY gameId, wlId, wlUserId
    ),

    -- 2) unpivot to (player, window) and roll up per game
    per_game AS
    (
        SELECT
            gameId,
            w.1                                         AS window_hours,
            sum(w.2)                                    AS bet_eur,
            sum(w.3)                                    AS win_eur,
            sum(w.4)                                    AS actions,
            countIf(w.2 > 0)                            AS players,
            -- biggest single net winner (high-roller) in the window
            greatest(max(w.3 - w.2), toDecimal128(0, 4)) AS top_player_net_win_eur
        FROM per_player
        ARRAY JOIN [ (toUInt8(4),  bet_4h,  win_4h,  act_4h),
                     (toUInt8(12), bet_12h, win_12h, act_12h) ] AS w
        GROUP BY gameId, window_hours
    ),

    -- 3) RTP metrics + per-window thresholds and volume gate
    scored AS
    (
        SELECT
            gameId,
            window_hours,
            bet_eur,
            win_eur,
            actions,
            players,
            top_player_net_win_eur,
            100 * win_eur / bet_eur                                   AS rtp_raw_pct,
            -- RTP with the biggest winner neutralised (his net win removed):
            -- a single high-roller jackpot cannot trigger the alert on its own
            100 * (win_eur - top_player_net_win_eur) / bet_eur        AS rtp_ex_top_pct,
            -- "drastically exceeds 94%": +21 pp on 4h (=115%), +14 pp on 12h (=108%)
            target_rtp_pct + if(window_hours = 4, 21.0, 14.0)         AS alert_threshold_pct,
            -- volume gate (AC2)
            if(window_hours = 4, 10000,  30000)                       AS min_bet_eur,
            if(window_hours = 4, 50,     100)                         AS min_players,
            if(window_hours = 4, 5000,   15000)                       AS min_actions
        FROM per_game
        WHERE bet_eur > 0
    )

SELECT
    window_end                                                          AS time,
    gameId                                                              AS game_id,
    dictGetOrDefault('platform.games_d', 'name', toString(gameId), gameId) AS game_name,
    concat(toString(window_hours), 'h')                                 AS window,
    toString(alert_threshold_pct)                                       AS threshold_pct,
    -- ---- single numeric column = alert value (query A) ----------------
    round(toFloat64(rtp_ex_top_pct) - alert_threshold_pct, 2)           AS rtp_excess_pp
    -- ---- detail queries for the Slack message: duplicate this query as
    --      B / C / D / E and replace the line above with ONE of:
    -- round(toFloat64(rtp_raw_pct), 2)                                 AS rtp_raw_pct          -- B
    -- round(toFloat64(rtp_ex_top_pct), 2)                              AS rtp_ex_top_pct       -- C
    -- round(toFloat64(bet_eur), 0)                                     AS bet_eur              -- D
    -- toFloat64(players)                                               AS players              -- E
FROM scored
WHERE bet_eur  >= min_bet_eur
  AND players  >= min_players
  AND actions  >= min_actions
ORDER BY rtp_excess_pp DESC
LIMIT 500
