-- ============================================================================
-- 🔴 SLOW QUERY HOTSPOTS - What's slow RIGHT NOW
-- ============================================================================
-- Use: Page for high query latency / user complaints
-- Action: Identify slow query patterns, check indexes, optimize queries
-- ============================================================================

SELECT
    query_kind,
    normalized_query_hash,
    arrayJoin(tables) AS table_name,
    count(*) AS slow_queries,
    round(avg(query_duration_ms)) AS avg_ms,
    round(max(query_duration_ms)) AS max_ms,
    round(quantile(0.95)(query_duration_ms)) AS p95_ms,
    round(avg(memory_usage / 1024 / 1024)) AS avg_mem_mb,
    round(avg(read_rows)) AS avg_rows_read,
    any(substring(query, 1, 150)) AS sample_query
FROM clusterAllReplicas('{cluster}', system, query_log)
WHERE event_time >= now() - INTERVAL 5 MINUTES
  AND type = 'QueryFinish' 
  AND user = 'factor-observations'
  AND query_duration_ms > 2000
  AND tables != []
GROUP BY query_kind, normalized_query_hash, table_name
ORDER BY slow_queries DESC, max_ms DESC
LIMIT 20;

-- ============================================================================
-- Top slow queries by total time consumed (impact on cluster)
-- ============================================================================
SELECT
    normalized_query_hash,
    count(*) AS executions,
    round(sum(query_duration_ms) / 1000) AS total_seconds,
    round(avg(query_duration_ms)) AS avg_ms,
    round(max(query_duration_ms)) AS max_ms,
    any(substring(query, 1, 150)) AS sample_query
FROM clusterAllReplicas('{cluster}', system, query_log)
WHERE event_time >= now() - INTERVAL 15 MINUTES
  AND type = 'QueryFinish'
  AND query_duration_ms > 1000
  AND user = 'factor-observations'
GROUP BY normalized_query_hash
ORDER BY total_seconds DESC
LIMIT 10;
