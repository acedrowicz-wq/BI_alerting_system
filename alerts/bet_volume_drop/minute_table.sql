-- =====================================================================
-- Per-minute bet volume rollup (slots + live) for volume / outage alerts
-- Run ONCE by a ClickHouse admin (needs CREATE on bi_sandbox; the BI and
-- Grafana users are read-only). Order: 1) table, 2) both MVs, 3) backfill.
--
-- Grain : minute x source x game x casino. ~0.5 M rows/day, TTL 8 days.
-- Count : uniqState(mongoId), so PeerDB re-inserting a row on every status
--         update does not double count (approximate, ~1% error; irrelevant
--         for ratio alerts).
-- Bets  : slots = actions with betSize > 0; live = every bet row.
-- Test casinos are NOT filtered here (wlId is kept), filter at query time.
-- =====================================================================

-- 1) target table
CREATE TABLE IF NOT EXISTS bi_sandbox.bets_per_minute
(
    minute  DateTime('UTC'),
    source  LowCardinality(String),           -- 'slot' | 'live'
    gameId  LowCardinality(String),
    wlId    LowCardinality(String),
    bets    AggregateFunction(uniq, String)  -- read with uniqMerge(bets)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMMDD(minute)
ORDER BY (minute, source, gameId, wlId)
TTL minute + INTERVAL 8 DAY
COMMENT 'Bets per minute per game and casino (slots + live). Read with uniqMerge(bets). Feeds the BI bet-volume-drop alert.';

-- 2a) slots
CREATE MATERIALIZED VIEW IF NOT EXISTS bi_sandbox.bets_per_minute_slot_mv
TO bi_sandbox.bets_per_minute AS
SELECT
    toStartOfMinute(createdAt)       AS minute,
    'slot'                           AS source,
    gameId,
    ifNull(wlId, '')                 AS wlId,
    uniqState(toString(mongoId))     AS bets
FROM platform.slot_actions
WHERE betSize > 0
GROUP BY minute, gameId, wlId;

-- 2b) live
CREATE MATERIALIZED VIEW IF NOT EXISTS bi_sandbox.bets_per_minute_live_mv
TO bi_sandbox.bets_per_minute AS
SELECT
    toStartOfMinute(createdAt)       AS minute,
    'live'                           AS source,
    gameId,
    ifNull(wlId, '')                 AS wlId,
    uniqState(toString(mongoId))     AS bets
FROM platform.bets
GROUP BY minute, gameId, wlId;

-- 3) backfill the last 2 days (the alert needs 25 h of history).
--    Run right AFTER creating the MVs. Overlap with rows the MVs already
--    caught is harmless: uniq states of the same mongoId merge, not add up.
INSERT INTO bi_sandbox.bets_per_minute
SELECT toStartOfMinute(createdAt), 'slot', gameId, ifNull(wlId, ''), uniqState(toString(mongoId))
FROM platform.slot_actions
WHERE createdAt >= now() - INTERVAL 2 DAY AND createdAt < toStartOfMinute(now())
  AND betSize > 0
GROUP BY 1, 3, 4;

INSERT INTO bi_sandbox.bets_per_minute
SELECT toStartOfMinute(createdAt), 'live', gameId, ifNull(wlId, ''), uniqState(toString(mongoId))
FROM platform.bets
WHERE createdAt >= now() - INTERVAL 2 DAY AND createdAt < toStartOfMinute(now())
GROUP BY 1, 3, 4;

-- 4) let Grafana read it
GRANT SELECT ON bi_sandbox.bets_per_minute TO monitor_user;
