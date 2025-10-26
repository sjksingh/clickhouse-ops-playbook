-- ============================================================================
-- 🟡 STUCK/FAILED MUTATIONS - Schema changes blocking
-- ============================================================================
-- Use: Page for failed ALTER/UPDATE/DELETE operations
-- Action: Check failed parts, kill stuck mutations, investigate errors
-- ============================================================================

-- Stuck mutations (>10 minutes and not done)
SELECT
    hostName() AS host,
    database,
    table,
    mutation_id,
    command,
    create_time,
    parts_to_do,
    is_done,
    latest_failed_part,
    latest_fail_time,
    latest_fail_reason
FROM clusterAllReplicas('{cluster}', system, mutations)
WHERE is_done = 0
  AND create_time < now() - INTERVAL 10 MINUTES
ORDER BY create_time ASC
LIMIT 20;

-- ============================================================================
-- All active mutations (see what's running)
-- ============================================================================
SELECT
    hostName() AS host,
    database,
    table,
    mutation_id,
    command,
    create_time,
    parts_to_do,
    is_done,
    latest_fail_time
FROM clusterAllReplicas('{cluster}', system, mutations)
WHERE is_done = 0
ORDER BY create_time ASC;

-- ============================================================================
-- Recent mutation history (last hour)
-- ============================================================================
SELECT
    database,
    table,
    mutation_id,
    command,
    create_time,
    parts_to_do_names,
    is_done,
    latest_failed_part,
    substring(latest_fail_reason, 1, 150) AS fail_reason_short
FROM clusterAllReplicas('{cluster}', system, mutations)
WHERE create_time >= now() - INTERVAL 1 HOUR
ORDER BY create_time DESC
LIMIT 30;
