-- =====================================================================
-- Context for the Game RTP spike alert: actual RTP over the last 24h
-- Use as query "C" in the SAME Grafana alert rule (not in the condition).
-- Labels are identical to query A (game_id, game_name, game_type, window,
-- threshold_pct), so Grafana matches each alert instance to its 24h RTP
-- and the Slack message can show the trend: window RTP vs 24h RTP.
-- Same sources and filters as query.sql; no volume gate (context only).
-- =====================================================================
WITH
    94.0                                         AS target_rtp_pct,
    toStartOfFifteenMinutes(now('UTC'))          AS window_end,
    window_end - INTERVAL 24 HOUR                AS start_24h,

    per_game AS
    (
        SELECT 'slot' AS source, gameId,
            toDecimal128(sum(betEur), 4)       AS bet_eur,
            toDecimal128(sum(winEur), 4)       AS win_eur
        FROM platform.agg_slots_ggr
        WHERE bucket >= start_24h AND bucket < window_end
        GROUP BY gameId

        UNION ALL

        SELECT 'live' AS source, gameId,
            toDecimal128(sum(convertedBet), 4) AS bet_eur,
            toDecimal128(sum(convertedWin), 4) AS win_eur
        FROM platform.bets FINAL
        WHERE createdAt >= start_24h AND createdAt < window_end
          AND status IN ('FINALIZED', 'COMPLETED')
          AND dictGetOrDefault('platform.whitelabels_d', 'isTest', toString(wlId), toUInt8(0)) = 0
          AND dictGetOrDefault('platform.currency_d', 'isFun', toString(currency), toUInt8(0)) = 0
          AND (isNull(freeSpins) OR freeSpins IN ('', '0'))
        GROUP BY gameId
    )

SELECT
    window_end                                                             AS time,
    gameId                                                                 AS game_id,
    dictGetOrDefault('platform.games_d', 'name', toString(gameId), gameId) AS game_name,
    source                                                                 AS game_type,
    concat(toString(w.1), 'h')                                             AS window,
    toString(target_rtp_pct + w.2)                                         AS threshold_pct,
    -- actual RTP of the game over the last 24h (single numeric column)
    round(toFloat64(100 * win_eur / bet_eur), 2)                           AS rtp_24h_pct
FROM per_game
-- one row per label set used by query A (4h -> +21 pp, 12h -> +14 pp)
ARRAY JOIN [ (toUInt8(4), 21.0), (toUInt8(12), 14.0) ] AS w
WHERE bet_eur > 0
ORDER BY game_id, window
LIMIT 1000
