-- ============================================================================
-- 🟡 LONG-RUNNING QUERIES - What's stuck RIGHT NOW
-- ============================================================================
-- Use: Page for stuck queries / high CPU / need to kill queries
-- Action: Review query, kill if needed, optimize
-- ============================================================================

-- Queries running >60 seconds
SELECT
    hostName() AS host,
    query_id,
    user,
    elapsed,
    formatReadableSize(memory_usage) AS memory,
    formatReadableSize(peak_memory_usage) AS peak_memory,
    read_rows,
    formatReadableSize(read_bytes) AS read_data,
    written_rows,
    formatReadableSize(written_bytes) AS written_data,
    substring(query, 1, 250) AS query_snippet
FROM clusterAllReplicas('{cluster}', system, processes)
WHERE query NOT LIKE '%system.processes%'
  AND query NOT LIKE '%system.query_log%'
  AND elapsed > 60
ORDER BY elapsed DESC;

-- ============================================================================
-- All running queries (see current load)
-- ============================================================================
SELECT
    hostName() AS host,
    query_id,
    user,
    elapsed,
    formatReadableSize(memory_usage) AS memory,
    read_rows,
    substring(query, 1, 150) AS query_snippet
FROM clusterAllReplicas('{cluster}', system, processes)
WHERE query NOT LIKE '%system.processes%'
  AND query NOT LIKE '%system.query_log%'
ORDER BY elapsed DESC;

-- ============================================================================
-- Query distribution by user (identify heavy users)
-- ============================================================================
SELECT
    user,
    count() AS active_queries,
    formatReadableSize(sum(memory_usage)) AS total_memory,
    round(avg(elapsed)) AS avg_elapsed_sec,
    max(elapsed) AS max_elapsed_sec
FROM clusterAllReplicas('{cluster}', system, processes)
WHERE query NOT LIKE '%system.processes%'
  AND query NOT LIKE '%system.query_log%'
GROUP BY user
ORDER BY active_queries DESC;
