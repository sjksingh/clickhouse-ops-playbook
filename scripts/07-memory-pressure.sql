-- ============================================================================
-- 🟡 MEMORY PRESSURE - OOM risk
-- ============================================================================
-- Use: Page for OOM kills / high memory usage alerts
-- Action: Kill heavy queries, adjust limits, restart if needed
-- ============================================================================

-- Memory metrics per host
SELECT
    hostName() AS host,
    formatReadableSize(value) AS memory_value,
    metric
FROM clusterAllReplicas('{cluster}', system, asynchronous_metrics)
WHERE metric IN (
    'MemoryResident',
    'CGroupMemoryUsed', 
    'CGroupMemoryTotal',
    'jemalloc.resident',
    'jemalloc.allocated',
    'MemoryTracking'
)
ORDER BY host, metric;

-- ============================================================================
-- Memory utilization percentage per host (>80% is concerning)
-- ============================================================================
SELECT
    hostName() AS host,
    formatReadableSize(max(if(metric = 'CGroupMemoryUsed', value, 0))) AS used,
    formatReadableSize(max(if(metric = 'CGroupMemoryTotal', value, 0))) AS total,
    round((max(if(metric = 'CGroupMemoryUsed', value, 0)) / 
           max(if(metric = 'CGroupMemoryTotal', value, 1))) * 100, 1) AS memory_pct
FROM clusterAllReplicas('{cluster}', system, asynchronous_metrics)
WHERE metric IN ('CGroupMemoryUsed', 'CGroupMemoryTotal')
GROUP BY host
ORDER BY memory_pct DESC;

-- ============================================================================
-- Top memory consuming queries (running now)
-- ============================================================================
SELECT
    hostName() AS host,
    query_id,
    user,
    formatReadableSize(memory_usage) AS memory,
    formatReadableSize(peak_memory_usage) AS peak_memory,
    elapsed,
    read_rows,
    substring(query, 1, 150) AS query_snippet
FROM clusterAllReplicas('{cluster}', system, processes)
WHERE query NOT LIKE '%system.processes%'
  AND query NOT LIKE '%system.query_log%'
ORDER BY memory_usage DESC
LIMIT 10;

-- ============================================================================
-- Historical high memory queries (last hour)
-- ============================================================================
SELECT
    formatReadableSize(peak_memory_usage) AS peak_memory,
    query_duration_ms,
    read_rows,
    user,
    substring(query, 1, 150) AS query_snippet,
    event_time
FROM clusterAllReplicas('{cluster}', system, query_log)
WHERE event_time >= now() - INTERVAL 1 HOUR
  AND type = 'QueryFinish'
  AND peak_memory_usage > 1024 * 1024 * 1024
ORDER BY peak_memory_usage DESC
LIMIT 15;
