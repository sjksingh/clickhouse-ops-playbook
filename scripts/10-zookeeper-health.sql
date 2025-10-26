-- ============================================================================
-- 🔵 ZOOKEEPER HEALTH - Replication dependency
-- ============================================================================
-- Use: Page for replication issues / readonly replicas / ZK down
-- Action: Check ZK ensemble, restart ZK, check network
-- ============================================================================

-- Check if ZooKeeper is responsive from both replicas
SELECT 
    hostName() AS host,
    'ZooKeeper OK' AS status
FROM clusterAllReplicas('{cluster}', system, zookeeper)
WHERE path = '/'
LIMIT 2;

-- ============================================================================
-- ZooKeeper connection status per replica
-- ============================================================================
SELECT
    hostName() AS host,
    name AS metric,
    value
FROM clusterAllReplicas('{cluster}', system, asynchronous_metrics)
WHERE metric LIKE 'ZooKeeper%'
ORDER BY host, metric;

-- ============================================================================
-- ZooKeeper session info from replicas table
-- ============================================================================
SELECT
    hostName() AS host,
    database,
    table,
    is_session_expired,
    zookeeper_exception,
    last_queue_update,
    log_pointer
FROM clusterAllReplicas('{cluster}', system, replicas)
WHERE is_session_expired = 1
   OR zookeeper_exception != ''
ORDER BY host;

-- ============================================================================
-- ClickHouse paths in ZooKeeper (structure check)
-- ============================================================================
SELECT
    name,
    value,
    czxid,
    mzxid,
    ctime,
    mtime,
    numChildren
FROM clusterAllReplicas('{cluster}', system, zookeeper)
WHERE path = '/clickhouse'
LIMIT 10;

-- ============================================================================
-- ZooKeeper replica metadata
-- ============================================================================
SELECT
    database,
    table,
    hostName() AS host,
    zookeeper_path,
    replica_name,
    replica_path
FROM clusterAllReplicas('{cluster}', system, replicas)
ORDER BY database, table, host;
