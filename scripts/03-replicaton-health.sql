-- ============================================================================
-- 🟡 REPLICATION HEALTH - Readonly replicas & lag
-- ============================================================================
-- Use: Page for readonly tables / replication issues
-- Action: Check ZK connection, restart replicas, investigate queue
-- Docs: See troubleshooting/readonly-tables.md
-- ============================================================================

-- Readonly replicas or high lag (CRITICAL)
SELECT
    hostName() AS host,
    database,
    table,
    is_readonly,
    absolute_delay AS lag_seconds,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    part_mutations_in_queue,
    is_session_expired,
    zookeeper_exception,
    last_queue_update,
    log_pointer
FROM clusterAllReplicas('{cluster}', system, replicas)
WHERE is_readonly = 1 
   OR absolute_delay > 60 
   OR queue_size > 100
ORDER BY is_readonly DESC, absolute_delay DESC;

-- ============================================================================
-- All replicas overview (check both replicas health)
-- ============================================================================
SELECT
    database,
    table,
    hostName() AS host,
    is_readonly,
    absolute_delay AS lag_seconds,
    queue_size,
    inserts_in_queue,
    is_session_expired,
    active_replicas,
    total_replicas
FROM clusterAllReplicas('{cluster}', system, replicas)
ORDER BY database, table, host;

-- ============================================================================
-- Replication queue details (what's blocking?)
-- ============================================================================
SELECT
    database,
    table,
    hostName() AS host,
    type,
    create_time,
    num_tries,
    last_exception,
    postpone_reason,
    source_replica
FROM clusterAllReplicas('{cluster}', system, replication_queue)
WHERE last_exception != ''
   OR num_tries > 5
   OR create_time < now() - INTERVAL 10 MINUTES
ORDER BY create_time ASC
LIMIT 20;
