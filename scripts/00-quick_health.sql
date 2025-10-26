-- ============================================================================
-- 🚨 QUICK HEALTH CHECK - Run this FIRST
-- ============================================================================
-- Single shard, 2 replicas, 3 ZK ensemble
-- Expected: All checks return 0 or empty results
-- ============================================================================

-- 🔴 CRITICAL: Readonly replicas (should be 0)
SELECT
    'READONLY_REPLICAS' AS check_name,
    count(*) AS issue_count,
    groupArray(concat(database, '.', table, ' on ', hostName())) AS affected_tables
FROM clusterAllReplicas('{cluster}', system, replicas)
WHERE is_readonly = 1;

-- 🔴 CRITICAL: Recent errors (last 5 min, should be 0)
SELECT
    'RECENT_ERRORS' AS check_name,
    count(*) AS issue_count,
    groupArray(DISTINCT exception_code) AS error_codes
FROM clusterAllReplicas('{cluster}', system, query_log)
WHERE event_time >= now() - INTERVAL 5 MINUTES
  AND type = 'ExceptionWhileProcessing';

-- 🔴 CRITICAL: Replication lag >60s (should be 0)
SELECT
    'REPLICATION_LAG' AS check_name,
    count(*) AS issue_count,
    groupArray(concat(database, '.', table, ': ', toString(absolute_delay), 's')) AS lagging_tables
FROM clusterAllReplicas('{cluster}', system, replicas)
WHERE absolute_delay > 60;

-- 🟡 WARNING: Memory pressure >85% (should be 0)
SELECT
    'MEMORY_PRESSURE' AS check_name,
    count(*) AS issue_count,
    groupArray(concat(host, ': ', toString(memory_pct), '%')) AS high_memory_hosts
FROM (
    SELECT
        hostName() AS host,
        round((max(if(metric = 'CGroupMemoryUsed', value, 0)) / 
               max(if(metric = 'CGroupMemoryTotal', value, 1))) * 100, 1) AS memory_pct
    FROM clusterAllReplicas('{cluster}', system, asynchronous_metrics)
    WHERE metric IN ('CGroupMemoryUsed', 'CGroupMemoryTotal')
    GROUP BY host
    HAVING memory_pct > 85
);

-- 🟡 WARNING: Too many parts >300 (merge backlog)
SELECT
    'MERGE_BACKLOG' AS check_name,
    count(*) AS issue_count,
    groupArray(concat(database, '.', table, ': ', toString(active_parts), ' parts')) AS backlogged_tables
FROM (
    SELECT
        database,
        table,
        count() AS active_parts
    FROM clusterAllReplicas('{cluster}', system, parts)
    WHERE active = 1
    GROUP BY database, table
    HAVING active_parts > 300
);

-- 🟡 WARNING: Stuck mutations >10min (should be 0)
SELECT
    'STUCK_MUTATIONS' AS check_name,
    count(*) AS issue_count,
    groupArray(concat(database, '.', table, ': ', mutation_id)) AS stuck_mutations
FROM clusterAllReplicas('{cluster}', system, mutations)
WHERE is_done = 0
  AND create_time < now() - INTERVAL 10 MINUTES;

-- 🟢 INFO: Disk space >80% (should be 0)
SELECT
    'DISK_SPACE' AS check_name,
    count(*) AS issue_count,
    groupArray(concat(host, ' ', disk, ': ', toString(used_pct), '%')) AS high_disk_hosts
FROM (
    SELECT
        hostName() AS host,
        name AS disk,
        round((total_space - free_space) / total_space * 100, 1) AS used_pct
    FROM clusterAllReplicas('{cluster}', system, disks)
    WHERE used_pct > 80
);

-- ============================================================================
-- ✅ If all issue_count = 0, you're good. Otherwise, run specific diagnostics.
-- ============================================================================
