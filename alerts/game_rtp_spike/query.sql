-- =====================================================================
-- Alert: Game RTP spike vs 94% target (rolling 4h / 12h) — ALL games
-- Source : ProdCH
--   slot -> platform.agg_slots_ggr (15-min buckets per game / casino /
--           player; settled real-money actions in EUR; test casinos and
--           fun currencies already excluded; TTL 8 days)
--   live -> platform.bets FINAL (settled bets; sort key starts with
--           toStartOfHour(createdAt) so the 12h filter prunes to ~12 h)
-- Grain  : one row per (game_id, window) that BREACHES (volume gate passed
--          and RTP excl. top winner > threshold); empty result = all OK
-- Value  : rtp_actual_pct (actual RTP in the window) -> alert when > 0
-- Runs   : every 5 min, ~0.1-0.5 s
-- =====================================================================
WITH
    94.0                                         AS target_rtp_pct,
    -- evaluate on COMPLETE 15-min buckets only (stable value, no partial bucket)
    toStartOfFifteenMinutes(now('UTC'))          AS window_end,
    window_end - INTERVAL 4 HOUR                 AS start_4h,
    window_end - INTERVAL 12 HOUR                AS start_12h,

    -- 1) per player, both windows in a single pass — slots + live
    per_player AS
    (
        SELECT
            'slot'                                                   AS source,
            gameId, wlId, wlUserId,
            toDecimal128(sumIf(betEur, bucket >= start_4h), 4)       AS bet_4h,
            toDecimal128(sumIf(winEur, bucket >= start_4h), 4)       AS win_4h,
            sumIf(actions, bucket >= start_4h)                       AS cnt_4h,
            toDecimal128(sum(betEur), 4)                             AS bet_12h,
            toDecimal128(sum(winEur), 4)                             AS win_12h,
            sum(actions)                                             AS cnt_12h
        FROM platform.agg_slots_ggr
        WHERE bucket >= start_12h
          AND bucket <  window_end
        GROUP BY gameId, wlId, wlUserId

        UNION ALL

        SELECT
            'live'                                                   AS source,
            gameId, wlId, wlUserId,
            toDecimal128(sumIf(convertedBet, createdAt >= start_4h), 4) AS bet_4h,
            toDecimal128(sumIf(convertedWin, createdAt >= start_4h), 4) AS win_4h,
            countIf(createdAt >= start_4h)                           AS cnt_4h,
            toDecimal128(sum(convertedBet), 4)                       AS bet_12h,
            toDecimal128(sum(convertedWin), 4)                       AS win_12h,
            count()                                                  AS cnt_12h
        FROM platform.bets FINAL
        WHERE createdAt >= start_12h
          AND createdAt <  window_end
          AND status IN ('FINALIZED', 'COMPLETED')
          AND dictGetOrDefault('platform.whitelabels_d', 'isTest', toString(wlId), toUInt8(0)) = 0
          AND dictGetOrDefault('platform.currency_d', 'isFun', toString(currency), toUInt8(0)) = 0
          AND (isNull(freeSpins) OR freeSpins IN ('', '0'))          -- real money only
        GROUP BY gameId, wlId, wlUserId
    ),

    -- 2) unpivot to (player, window) and roll up per game
    per_game AS
    (
        SELECT
            source,
            gameId,
            w.1                                          AS window_hours,
            sum(w.2)                                     AS bet_eur,
            sum(w.3)                                     AS win_eur,
            sum(w.4)                                     AS actions,        -- slot: actions, live: bets
            countIf(w.2 > 0)                             AS players,
            -- biggest single net winner (high-roller) in the window
            greatest(max(w.3 - w.2), toDecimal128(0, 4)) AS top_player_net_win_eur
        FROM per_player
        ARRAY JOIN [ (toUInt8(4),  bet_4h,  win_4h,  cnt_4h),
                     (toUInt8(12), bet_12h, win_12h, cnt_12h) ] AS w
        GROUP BY source, gameId, window_hours
    ),

    -- 3) RTP metrics + per-window thresholds and per-source volume gate
    scored AS
    (
        SELECT
            source, gameId, window_hours, bet_eur, win_eur, actions, players, top_player_net_win_eur,
            100 * win_eur / bet_eur                                   AS rtp_raw_pct,
            -- RTP with the biggest winner neutralised (his net win removed):
            -- a single high-roller jackpot cannot trigger the alert on its own
            100 * (win_eur - top_player_net_win_eur) / bet_eur        AS rtp_ex_top_pct,
            -- "drastically exceeds 94%": +21 pp on 4h (=115%), +14 pp on 12h (=108%)
            target_rtp_pct + if(window_hours = 4, 21.0, 14.0)         AS alert_threshold_pct,
            -- volume gate (AC2); live games have ~10-50x lower volume than slots
            multiIf(source = 'slot', if(window_hours = 4, 10000, 30000),
                                     if(window_hours = 4, 3000,  8000))  AS min_bet_eur,
            multiIf(source = 'slot', if(window_hours = 4, 50,    100),
                                     if(window_hours = 4, 20,    30))    AS min_players,
            multiIf(source = 'slot', if(window_hours = 4, 5000,  15000),
                                     if(window_hours = 4, 300,   600))   AS min_actions
        FROM per_game
        WHERE bet_eur > 0
    )

SELECT
    window_end                                                             AS time,
    gameId                                                                 AS game_id,
    dictGetOrDefault('platform.games_d', 'name', toString(gameId), gameId) AS game_name,
    source                                                                 AS game_type,
    concat(toString(window_hours), 'h')                                    AS window,
    toString(alert_threshold_pct)                                          AS threshold_pct,
    -- actual (raw) RTP of the game in the window = the single numeric column (alert value)
    round(toFloat64(rtp_raw_pct), 2)                                       AS rtp_actual_pct
FROM scored
WHERE bet_eur >= min_bet_eur
  AND players >= min_players
  AND actions >= min_actions
  -- breach: RTP still above threshold after neutralising the top winner
  AND rtp_ex_top_pct > alert_threshold_pct
ORDER BY rtp_actual_pct DESC
LIMIT 500
