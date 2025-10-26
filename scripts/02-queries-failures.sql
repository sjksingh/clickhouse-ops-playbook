-- ============================================================================
-- 🔴 QUERY FAILURES - What's BROKEN
-- ============================================================================
-- Use: Page for application errors / failed queries
-- Action: Check error codes, common patterns, affected users
-- ============================================================================

-- Recent failures (last hour)
SELECT
    exception_code,
    count(*) AS error_count,
    any(substring(exception, 1, 200)) AS sample_error,
    groupArray(DISTINCT user) AS affected_users,
    min(event_time) AS first_seen,
    max(event_time) AS last_seen
FROM clusterAllReplicas('{cluster}', system, query_log)
WHERE event_time >= now() - INTERVAL 1 HOUR
  AND type = 'ExceptionWhileProcessing'
GROUP BY exception_code
ORDER BY error_count DESC
LIMIT 10;

-- ============================================================================
-- Errors by table (identify problematic tables)
-- ============================================================================
SELECT
    arrayJoin(tables) AS table_name,
    exception_code,
    count(*) AS error_count,
    any(substring(exception, 1, 150)) AS sample_error
FROM clusterAllReplicas('{cluster}', system, query_log)
WHERE event_time >= now() - INTERVAL 1 HOUR
  AND type = 'ExceptionWhileProcessing'
  AND tables != []
GROUP BY table_name, exception_code
ORDER BY error_count DESC
LIMIT 15;

-- ============================================================================
-- Recent error timeline (spikes indicate incidents)
-- ============================================================================
SELECT
    toStartOfMinute(event_time) AS minute,
    count(*) AS errors,
    groupUniqArray(5)(exception_code) AS error_codes
FROM clusterAllReplicas('{cluster}', system, query_log)
WHERE event_time >= now() - INTERVAL 30 MINUTES
  AND type = 'ExceptionWhileProcessing'
GROUP BY minute
ORDER BY minute DESC
LIMIT 30;
