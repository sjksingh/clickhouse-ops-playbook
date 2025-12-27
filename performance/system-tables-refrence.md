# ClickHouse SRE Runbook: System Tables Reference

## Quick Reference

**Knowledge Cutoff:** January 2025  
**Source:** [ClickHouse System Tables Blog](https://clickhouse.com/blog/clickhouse-debugging-issues-with-system-tables)  
**Documentation:** [System Tables Docs](https://clickhouse.com/docs/en/operations/system-tables/)

---

## 1. Configuration & Settings

### 1.1 Identify Non-Default Settings

**Use Case:** First step in troubleshooting - identify configuration drift

**System Table:** `system.settings`

```sql
-- Show all settings changed from defaults
SELECT 
    name,
    value,
    description,
    type
FROM system.settings
WHERE changed = 1
ORDER BY name;
```

**What to Check:**
- `max_threads` - CPU utilization settings
- `max_memory_usage` - Memory limits per query
- `max_insert_threads` - Parallel insert configuration
- `distributed_*` settings - Cluster behavior

**Action Items:**
- Document why each setting was changed
- Compare against ClickHouse recommendations
- Check if settings align with hardware specs

---

## 2. Query Performance & Troubleshooting

### 2.1 Long-Running Queries

**Use Case:** Identify queries causing performance issues

**System Table:** `system.query_log`

```sql
-- Top 10 longest-running queries
SELECT
    type,
    event_time,
    query_duration_ms,
    initial_query_id,
    formatReadableSize(memory_usage) AS memory,
    ProfileEvents['UserTimeMicroseconds'] AS userCPU,
    ProfileEvents['SystemTimeMicroseconds'] AS systemCPU,
    normalizedQueryHash(query) AS normalized_query_hash,
    substring(normalizeQuery(query), 1, 200) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
ORDER BY query_duration_ms DESC
LIMIT 10;
```

**Action Items:**
- Review query patterns with `normalized_query_hash`
- Check if indexes/primary keys are used effectively
- Look for full table scans
- Consider query optimization or adding projections

### 2.2 Memory-Intensive Queries

**Use Case:** Identify queries at risk of OOM

```sql
-- Top queries by memory usage
SELECT
    type,
    event_time,
    formatReadableSize(memory_usage) AS memory,
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) AS read_size,
    initial_query_id,
    substring(normalizeQuery(query), 1, 150) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
ORDER BY memory_usage DESC
LIMIT 20;
```

**Warning Thresholds:**
- Memory > 80% of `max_memory_usage` setting
- Memory > 50GB for individual queries (adjust based on node size)

**Action Items:**
- Review GROUP BY and JOIN operations
- Check if LIMIT clauses are missing
- Consider increasing `max_bytes_before_external_group_by`
- Use sampling for large aggregations

### 2.3 Failed Queries

**Use Case:** Troubleshoot query failures

```sql
-- Recent failed queries with details
SELECT
    type,
    query_start_time,
    query_id,
    exception,
    stack_trace,
    normalizeQuery(query) AS normalized_query,
    formatReadableSize(memory_usage) AS memory,
    user,
    client_name
FROM system.query_log
WHERE type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
  AND event_date >= today() - 1
ORDER BY query_start_time DESC
LIMIT 50;
```

**Common Error Patterns:**
- `MEMORY_LIMIT_EXCEEDED` - Increase memory limits or optimize query
- `UNKNOWN_IDENTIFIER` - Schema/column issues
- `TIMEOUT_EXCEEDED` - Query taking too long
- `QUERY_WAS_CANCELLED` - Manual cancellation or system shutdown

### 2.4 Currently Running Queries

**Use Case:** Real-time monitoring of active queries

**System Table:** `system.processes`

```sql
-- Active queries with resource usage
SELECT
    query_id,
    user,
    elapsed,
    formatReadableSize(memory_usage) AS memory,
    formatReadableSize(peak_memory_usage) AS peak_memory,
    read_rows,
    formatReadableSize(read_bytes) AS read_size,
    substring(query, 1, 100) AS query_preview
FROM system.processes
WHERE query NOT LIKE '%system.processes%'
ORDER BY elapsed DESC;
```

**Action Items:**
- Kill runaway queries: `KILL QUERY WHERE query_id = '...'`
- Monitor for queries approaching memory limits

---

## 3. Storage & Parts Management

### 3.1 Disk Space Usage by Table

**Use Case:** Capacity planning and identifying space hogs

**System Table:** `system.parts`

```sql
-- Disk usage per table with compression stats
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS total_disk_space,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 3) AS compression_ratio,
    sum(rows) AS total_rows,
    count() AS num_parts
FROM system.parts
WHERE database NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema')
  AND active = 1
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC;
```

**Warning Thresholds:**
- Disk usage > 70% of capacity
- Compression ratio > 0.5 (poor compression)
- num_parts > 1000 per partition (too many small parts)

**Action Items:**
- Consider TTL policies for old data
- Review codec selection for better compression
- Schedule manual `OPTIMIZE TABLE` if needed

### 3.2 Part Creation Monitoring

**Use Case:** Verify insert operations are creating parts

**System Table:** `system.part_log`

```sql
-- Recent part creation activity
SELECT
    event_time,
    database,
    table,
    event_type,
    rows,
    formatReadableSize(bytes_uncompressed) AS size_uncompressed,
    part_name,
    duration_ms
FROM system.part_log
WHERE event_type = 'NewPart'
  AND event_date >= today() - 1
ORDER BY event_time DESC
LIMIT 100;
```

**What to Monitor:**
- Part creation should occur regularly during inserts
- Gap in part creation = potential insert failure
- Very small parts (< 1000 rows) = inefficient inserts

### 3.3 Part Errors

**Use Case:** Identify failing merge/mutation operations

```sql
-- Part errors in the last 30 days
SELECT
    event_date,
    event_type,
    database,
    table,
    error AS error_code,
    errorCodeToName(error) AS error_name,
    count() AS error_count,
    any(exception) AS sample_error_message
FROM system.part_log
WHERE error != 0
  AND event_date > today() - 30
GROUP BY event_date, event_type, database, table, error
ORDER BY event_date DESC, error_count DESC;
```

**Common Errors:**
- `MEMORY_LIMIT_EXCEEDED` (241) - Increase memory or reduce merge intensity
- `ABORTED` (236) - Manual cancellation or resource constraints
- `QUERY_WAS_CANCELLED` (394) - System shutdown during operation
- `INSERT_WAS_DEDUPLICATED` (389) - Expected for ReplicatedMergeTree

---

## 4. MergeTree Settings & Optimization (CRITICAL)

### 4.1 Understanding the Insert/Query Performance Trade-Off

**Core Principle:**  
MergeTree creates "parts" on each INSERT. Too many parts = slow queries. Too few parts = slow inserts (merge overhead).

**The Balance:**
```
HIGH INSERT SPEED               HIGH QUERY SPEED
     ↓                               ↓
More parts allowed          Fewer parts (aggressive merge)
Less merge resources        More merge resources
Fast writes                 Fast reads
Slow reads                  Slow writes
```

### 4.2 Critical MergeTree Settings

#### A. parts_to_throw_insert (SAFETY LIMIT)

**Location:** `/etc/clickhouse-server/config.d/merge_tree.xml`

**What it does:** Maximum parts per partition before rejecting INSERTs

```xml
<merge_tree>
    <parts_to_throw_insert>300</parts_to_throw_insert>  <!-- Default: 300 -->
    <parts_to_delay_insert>150</parts_to_delay_insert>  <!-- Default: 150 -->
</merge_tree>
```

**Configuration by Workload Type:**

| Workload Type | parts_to_throw | parts_to_delay | Rationale |
|---------------|----------------|----------------|-----------|
| **Streaming/Real-time** | 500-600 | 250-300 | High insert rate, need buffer |
| **Batch ETL** | 200-300 | 100-150 | Periodic loads, prioritize queries |
| **Mixed/Balanced** | 350-400 | 175-200 | Compromise between both |

**For 1-Shard/2-Replica Setup:**
```xml
<!-- Recommended for high-throughput streaming -->
<merge_tree>
    <parts_to_throw_insert>500</parts_to_throw_insert>
    <parts_to_delay_insert>250</parts_to_delay_insert>
    <max_bytes_to_merge_at_max_space_in_pool>161061273600</max_bytes_to_merge_at_max_space_in_pool> <!-- 150GB -->
</merge_tree>
```

#### B. background_pool_size (MERGE THREADS)

**What it does:** Number of threads for background merges

```xml
<background_pool_size>16</background_pool_size>  <!-- Default: 16 -->
<background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>  <!-- Default: 2 -->
```

**Calculation:**  
Total concurrent merge tasks = `background_pool_size × background_merges_mutations_concurrency_ratio`

**Tuning by Hardware:**

| Hardware Profile | background_pool_size | Notes |
|------------------|----------------------|-------|
| 8-16 CPU cores, HDD | 8-12 | Conservative for spinning disk |
| 16-32 cores, SSD | 16-20 | Balanced |
| 32+ cores, NVMe SSD | 24-32 | Aggressive for high-throughput |

**For Your 1-Shard/2-Replica Setup:**
```xml
<!-- Assuming modern hardware with SSD/NVMe -->
<background_pool_size>20</background_pool_size>
<background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>
<!-- This allows 40 concurrent merge tasks -->
```

#### C. max_bytes_to_merge_at_max_space_in_pool

**What it does:** Maximum size of parts that can be merged together

```xml
<merge_tree>
    <max_bytes_to_merge_at_max_space_in_pool>161061273600</max_bytes_to_merge_at_max_space_in_pool>  <!-- 150GB default -->
</merge_tree>
```

**When to increase:**
- Tables with very large parts (> 50GB per part)
- Adequate disk I/O bandwidth available

### 4.3 Active Merge Monitoring

#### A. In-Progress Merges with ETA

**System Table:** `system.merges`

```sql
-- Active merges with detailed progress
SELECT
    database,
    table,
    round(elapsed, 0) AS elapsed_seconds,
    round(progress * 100, 2) AS percent_complete,
    formatReadableTimeDelta((elapsed / progress) - elapsed) AS ETA,
    num_parts AS parts_merging,
    formatReadableSize(total_size_bytes_compressed) AS merge_size,
    formatReadableSize(bytes_read_uncompressed) AS bytes_read,
    formatReadableSize(bytes_written_uncompressed) AS bytes_written,
    formatReadableSize(memory_usage) AS memory,
    result_part_name,
    is_mutation
FROM system.merges
ORDER BY elapsed DESC;
```

**Warning Signs:**
- Merge running > 1 hour with progress < 50%
- Memory usage > 10GB for single merge
- Multiple merges on same table (resource contention)

#### B. Merge Queue Depth Analysis

```sql
-- Comprehensive part count analysis by partition
SELECT
    database,
    table,
    partition,
    count() AS num_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed_size,
    min(modification_time) AS oldest_part,
    max(modification_time) AS newest_part,
    formatReadableTimeDelta(now() - min(modification_time)) AS oldest_part_age
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system')
GROUP BY database, table, partition
HAVING num_parts > 50
ORDER BY num_parts DESC;
```

**Critical Thresholds:**

| Part Count | Status | Action Required |
|------------|--------|-----------------|
| < 100 | ✅ Healthy | Monitor normally |
| 100-200 | ⚠️ Warning | Investigate merge settings |
| 200-300 | 🔴 Critical | Immediate attention - check merge pool |
| > 300 | 🚨 Emergency | Risk of INSERT failures, tune urgently |

#### C. Background Pool Utilization

```sql
-- Check if merge threads are saturated
SELECT
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN (
    'BackgroundPoolTask',
    'BackgroundMergesAndMutationsPoolTask',
    'BackgroundMergesAndMutationsPoolSize',
    'BackgroundSchedulePoolTask'
)
ORDER BY metric;
```

**Interpretation:**
- If `BackgroundPoolTask` ≈ `background_pool_size` → Threads saturated, consider increasing
- If `BackgroundMergesAndMutationsPoolTask` > 10 → Queue building up

#### D. Merge Performance History

```sql
-- Analyze merge performance over last 24 hours
SELECT
    toStartOfHour(event_time) AS hour,
    database,
    table,
    count() AS merge_count,
    avg(duration_ms) / 1000 AS avg_duration_sec,
    max(duration_ms) / 1000 AS max_duration_sec,
    sum(rows_read) AS total_rows_merged,
    formatReadableSize(sum(bytes_read_uncompressed)) AS total_data_merged
FROM system.part_log
WHERE event_type = 'MergeParts'
  AND event_date >= today() - 1
GROUP BY hour, database, table
ORDER BY hour DESC, merge_count DESC;
```

### 4.4 Mutation Operations (ALTER TABLE)

#### A. Active Mutations with Progress

**System Table:** `system.mutations`

```sql
-- Detailed mutation status
SELECT
    database,
    table,
    mutation_id,
    command,
    create_time,
    parts_to_do_names,
    parts_to_do,
    is_done,
    latest_failed_part,
    latest_fail_time,
    latest_fail_reason,
    formatReadableTimeDelta(now() - create_time) AS running_time
FROM system.mutations
WHERE is_done = 0
ORDER BY create_time ASC;
```

**Action Items:**
- Mutations block merges on affected parts
- Long-running mutations (>1 hour) need investigation
- Kill stuck mutations: `KILL MUTATION WHERE database='...' AND table='...' AND mutation_id='...'`

#### B. Mutation Errors from part_log

```sql
-- Failed mutation attempts
SELECT
    event_date,
    database,
    table,
    mutation_id,
    error AS error_code,
    errorCodeToName(error) AS error_name,
    count() AS failure_count,
    any(exception) AS sample_error
FROM system.part_log
WHERE event_type = 'MutatePart'
  AND error != 0
  AND event_date >= today() - 7
GROUP BY event_date, database, table, mutation_id, error
ORDER BY event_date DESC, failure_count DESC;
```

### 4.5 Tuning Workflow for Merge Settings

#### Step 1: Establish Baseline

```sql
-- Baseline metrics snapshot
SELECT
    'parts_per_table' AS metric,
    avg(part_count) AS avg_value,
    max(part_count) AS max_value
FROM (
    SELECT database, table, count() AS part_count
    FROM system.parts
    WHERE active = 1 AND database NOT IN ('system')
    GROUP BY database, table
)
UNION ALL
SELECT
    'active_merges',
    count(),
    count()
FROM system.merges
UNION ALL
SELECT
    'merge_pool_utilization',
    value,
    value
FROM system.metrics
WHERE metric = 'BackgroundPoolTask';
```

#### Step 2: Identify Bottleneck

**Symptoms and Solutions:**

| Symptom | Root Cause | Solution |
|---------|------------|----------|
| "Too many parts" errors | Insert rate > merge rate | Increase `parts_to_throw_insert` |
| High part counts (>200) | Insufficient merge capacity | Increase `background_pool_size` |
| Slow queries, fast inserts | Too many unmerged parts | Decrease `parts_to_throw_insert`, increase merges |
| Slow inserts, fast queries | Over-aggressive merging | Increase `parts_to_throw_insert` |
| BackgroundPoolTask at max | Thread saturation | Increase `background_pool_size` |

#### Step 3: Apply Changes and Monitor

1. **Edit config:** `/etc/clickhouse-server/config.d/merge_tree.xml`
2. **Reload config:** `SYSTEM RELOAD CONFIG` (no restart needed for most settings)
3. **Monitor for 30+ minutes** (full merge cycle)
4. **Compare metrics** against baseline

#### Step 4: Common Configuration Templates

**Template 1: High-Volume Streaming (e.g., Kafka, logs)**
```xml
<merge_tree>
    <parts_to_throw_insert>600</parts_to_throw_insert>
    <parts_to_delay_insert>300</parts_to_delay_insert>
    <max_bytes_to_merge_at_max_space_in_pool>161061273600</max_bytes_to_merge_at_max_space_in_pool>
</merge_tree>
<background_pool_size>24</background_pool_size>
<background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>
```

**Template 2: Batch ETL Workloads**
```xml
<merge_tree>
    <parts_to_throw_insert>200</parts_to_throw_insert>
    <parts_to_delay_insert>100</parts_to_delay_insert>
    <max_bytes_to_merge_at_max_space_in_pool>161061273600</max_bytes_to_merge_at_max_space_in_pool>
</merge_tree>
<background_pool_size>16</background_pool_size>
<background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>
```

**Template 3: Balanced Mixed Workload (RECOMMENDED for 1-shard/2-replica)**
```xml
<merge_tree>
    <parts_to_throw_insert>400</parts_to_throw_insert>
    <parts_to_delay_insert>200</parts_to_delay_insert>
    <max_bytes_to_merge_at_max_space_in_pool>161061273600</max_bytes_to_merge_at_max_space_in_pool>
</merge_tree>
<background_pool_size>20</background_pool_size>
<background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>
```

### 4.6 Emergency Procedures

#### A. System Under "Too Many Parts" Attack

```sql
-- 1. Check which tables are affected
SELECT database, table, partition, count() AS parts
FROM system.parts
WHERE active = 1
GROUP BY database, table, partition
HAVING parts > 200
ORDER BY parts DESC;

-- 2. Stop inserts temporarily (if needed)
-- SYSTEM STOP DISTRIBUTED SENDS database.table;  -- For distributed tables

-- 3. Force immediate merge (use with caution)
OPTIMIZE TABLE database.table PARTITION 'partition_id' FINAL;

-- 4. Monitor merge progress
SELECT * FROM system.merges;
```

#### B. Merge Pool Stuck/Saturated

```sql
-- 1. Check what merges are running
SELECT * FROM system.merges ORDER BY elapsed DESC;

-- 2. Check for blocking operations
SELECT * FROM system.processes WHERE query LIKE '%OPTIMIZE%' OR query LIKE '%ALTER%';

-- 3. If needed, stop merges temporarily
SYSTEM STOP MERGES database.table;

-- 4. Resume when ready
SYSTEM START MERGES database.table;
```

### 4.7 Part Count Alerts (Prometheus/Grafana)

```sql
-- Alert query: Part count exceeds threshold
SELECT
    database,
    table,
    partition,
    count() AS part_count
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system')
GROUP BY database, table, partition
HAVING part_count > 200  -- Adjust threshold
ORDER BY part_count DESC;
```

**Recommended Alert Thresholds:**
- **Warning:** > 150 parts per partition
- **Critical:** > 250 parts per partition
- **Emergency:** > 350 parts per partition

---

## 5. ZooKeeper / ClickHouse Keeper Monitoring (3-Node Cluster)

### 5.1 ZooKeeper Health Fundamentals

**Your Setup:** 3-node ZooKeeper ensemble (quorum-based)
- **Quorum:** 2 out of 3 nodes must be healthy
- **1 node failure:** Cluster stays operational
- **2 node failures:** Cluster becomes read-only, no new writes

### 5.2 ZooKeeper Connection Status

#### A. Check ZK Connectivity from ClickHouse

**System Table:** `system.zookeeper_connection`

```sql
-- ZooKeeper connection health
SELECT
    name,
    host,
    port,
    index,
    is_expired,
    session_uptime_elapsed_seconds,
    zookeeper_log_index
FROM system.zookeeper_connection
FORMAT Vertical;
```

**Critical Fields:**
- `is_expired = 1` → Session lost, replication will fail
- `session_uptime_elapsed_seconds < 60` → Frequent reconnections
- Multiple nodes with `is_expired = 1` → ZK cluster issues

#### B. ZooKeeper System Metrics

```sql
-- ZK-related metrics
SELECT
    metric,
    value,
    description
FROM system.asynchronous_metrics
WHERE metric LIKE '%ZooKeeper%'
ORDER BY metric;
```

**Key Metrics:**
- `ZooKeeperRequest` - Pending requests to ZK
- `ZooKeeperSession` - Active sessions
- `ZooKeeperWatch` - Active watches

### 5.3 ZooKeeper Node Health Checks

#### A. Four-Letter Word Commands (Direct ZK Query)

**From ClickHouse server shell:**

```bash
# Check if ZK is alive (imok)
echo ruok | nc localhost 2181
# Expected output: imok

# Get ZK status (leader/follower)
echo stat | nc localhost 2181

# Check ZK configuration
echo conf | nc localhost 2181

# Monitor connections
echo cons | nc localhost 2181

# Watch command stats
echo mntr | nc localhost 2181
```

**Critical `mntr` Metrics:**

| Metric | Healthy Range | Critical Threshold |
|--------|---------------|-------------------|
| `zk_outstanding_requests` | < 10 | > 100 |
| `zk_avg_latency` | < 10ms | > 100ms |
| `zk_num_alive_connections` | > 0 | 0 |
| `zk_packets_received` | Increasing | Flat (no activity) |

#### B. Automated Health Check Script

```bash
#!/bin/bash
# zk_health_check.sh

ZK_HOSTS=("zk1:2181" "zk2:2181" "zk3:2181")

for host in "${ZK_HOSTS[@]}"; do
    echo "=== Checking $host ==="
    
    # Check if responding
    status=$(echo ruok | nc -w 2 ${host/:/ })
    echo "Status: $status"
    
    # Get role (leader/follower)
    role=$(echo stat | nc -w 2 ${host/:/ } | grep Mode | awk '{print $2}')
    echo "Role: $role"
    
    # Check latency
    latency=$(echo mntr | nc -w 2 ${host/:/ } | grep zk_avg_latency | awk '{print $2}')
    echo "Avg Latency: ${latency}ms"
    echo ""
done
```

### 5.4 ZooKeeper Queue Monitoring in ClickHouse

#### A. Replication Queue Analysis

**System Table:** `system.replication_queue`

```sql
-- Detailed replication queue status
SELECT
    database,
    table,
    replica_name,
    position,
    node_name,
    type,
    create_time,
    required_quorum,
    source_replica,
    is_currently_executing,
    num_tries,
    num_postponed,
    postpone_reason,
    last_exception,
    formatReadableTimeDelta(now() - create_time) AS age
FROM system.replication_queue
WHERE num_tries > 0
ORDER BY create_time ASC, num_tries DESC
LIMIT 50;
```

**Warning Patterns:**

| Pattern | Issue | Action |
|---------|-------|--------|
| `num_tries > 10` | Persistent failure | Check `last_exception` |
| `postpone_reason != ''` | Task postponed | Review reason field |
| `is_currently_executing = 0` AND old age | Stuck in queue | Check ZK connectivity |
| Many entries with same `last_exception` | Systemic issue | Review ZK logs |

#### B. Queue Summary by Table

```sql
-- Queue summary per table
SELECT
    database,
    table,
    count() AS queue_size,
    countIf(is_currently_executing) AS executing_now,
    countIf(num_tries > 3) AS failed_attempts,
    countIf(num_tries > 10) AS critical_failures,
    max(num_tries) AS max_tries,
    min(create_time) AS oldest_entry,
    formatReadableTimeDelta(now() - min(create_time)) AS max_lag,
    uniqExact(last_exception) AS unique_errors
FROM system.replication_queue
GROUP BY database, table
ORDER BY queue_size DESC;
```

**Alert Thresholds:**
- ⚠️ `queue_size > 100`
- 🔴 `max_lag > 300 seconds` (5 minutes)
- 🚨 `critical_failures > 5`

### 5.5 ZooKeeper Data Inspection

#### A. Check Znode Sizes and Counts

```sql
-- WARNING: This queries ZK directly and can be slow
-- Inspect ZK structure for a table
SELECT
    name,
    path,
    ctime,
    mtime,
    numChildren,
    dataLength
FROM system.zookeeper
WHERE path = '/clickhouse/tables/{shard}/database.table'
ORDER BY dataLength DESC;
```

**Common Paths:**
- `/clickhouse/tables/{shard}/{database.table}/` - Table metadata
- `/clickhouse/tables/{shard}/{database.table}/log` - Replication log
- `/clickhouse/tables/{shard}/{database.table}/replicas/{replica}` - Replica state

#### B. Check for Stale Znodes

```sql
-- Find old entries in ZK log (potential cleanup needed)
SELECT
    name,
    ctime,
    mtime,
    formatReadableTimeDelta(now() - toDateTime(substring(toString(ctime), 1, 10))) AS age,
    dataLength
FROM system.zookeeper
WHERE path = '/clickhouse/tables/{shard}/database.table/log'
  AND toDateTime(substring(toString(ctime), 1, 10)) < now() - INTERVAL 7 DAY
ORDER BY ctime ASC
LIMIT 20;
```

### 5.6 ZooKeeper Session Monitoring

#### A. Session Expirations

```sql
-- Check for recent session expirations
SELECT
    event_time,
    thread_id,
    query_id,
    message
FROM system.text_log
WHERE message LIKE '%ZooKeeper%session%expired%'
  AND event_date >= today() - 1
ORDER BY event_time DESC;
```

**Common Causes:**
- Network instability between CH and ZK
- ZK overload (high latency)
- CH server under heavy load (can't maintain heartbeat)

#### B. Connection Flapping Detection

```sql
-- Detect frequent ZK reconnections
SELECT
    toStartOfMinute(event_time) AS minute,
    count() AS connection_events
FROM system.text_log
WHERE (message LIKE '%ZooKeeper%connected%' OR message LIKE '%ZooKeeper%disconnect%')
  AND event_date >= today()
GROUP BY minute
HAVING connection_events > 5
ORDER BY minute DESC;
```

### 5.7 ZooKeeper Performance Impact on Replication

#### A. Replication Lag Detection

**System Table:** `system.replicas`

```sql
-- Comprehensive replica health check
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    part_mutations_in_queue,
    log_max_index,
    log_pointer,
    log_max_index - log_pointer AS log_entries_behind,
    total_replicas,
    active_replicas,
    formatReadableTimeDelta(absolute_delay) AS formatted_delay
FROM system.replicas
WHERE database NOT IN ('system')
ORDER BY absolute_delay DESC;
```

**Critical Checks for 1-Shard/2-Replica:**

| Condition | Severity | Action |
|-----------|----------|--------|
| `is_readonly = 1` | 🚨 CRITICAL | Replica can't accept writes, check ZK |
| `is_session_expired = 1` | 🚨 CRITICAL | Lost ZK connection |
| `absolute_delay > 300` | 🔴 HIGH | Replication lagging 5+ minutes |
| `active_replicas < 2` | 🔴 HIGH | One replica offline (no redundancy) |
| `log_entries_behind > 1000` | ⚠️ WARNING | Significant replication backlog |

#### B. Lag Trends Over Time

```sql
-- Replication lag history from metric_log
SELECT
    toStartOfHour(event_time) AS hour,
    database,
    table,
    avg(value) AS avg_absolute_delay,
    max(value) AS max_absolute_delay,
    count() AS samples
FROM system.metric_log
WHERE metric = 'ReplicasMaxAbsoluteDelay'
  AND event_date >= today() - 1
GROUP BY hour, database, table
ORDER BY hour DESC, max_absolute_delay DESC;
```

### 5.8 ZooKeeper Troubleshooting Playbook

#### Problem 1: "Session Expired" Errors

**Symptoms:**
```sql
SELECT * FROM system.replicas WHERE is_session_expired = 1;
```

**Diagnosis Steps:**

1. **Check ZK cluster health:**
```bash
echo mntr | nc zk1 2181 | grep zk_avg_latency
echo mntr | nc zk2 2181 | grep zk_avg_latency
echo mntr | nc zk3 2181 | grep zk_avg_latency
```

2. **Check network connectivity:**
```bash
# From ClickHouse server
ping -c 5 zk1
ping -c 5 zk2
ping -c 5 zk3

# Check for packet loss
mtr zk1 -r -c 100
```

3. **Review ClickHouse ZK settings:**
```sql
SELECT * FROM system.settings WHERE name LIKE '%zookeeper%';
```

**Resolution:**
```sql
-- Restart replica if session expired
SYSTEM RESTART REPLICA database.table;
```

#### Problem 2: Replication Queue Stuck

**Symptoms:**
```sql
SELECT database, table, queue_size
FROM system.replicas
WHERE queue_size > 100;
```

**Diagnosis:**

```sql
-- Check what's stuck
SELECT
    type,
    source_replica,
    last_exception,
    count() AS stuck_count
FROM system.replication_queue
WHERE num_tries > 10
GROUP BY type, source_replica, last_exception;
```

**Resolution:**

```sql
-- Option 1: Clear specific failed entries (careful!)
-- SYSTEM DROP REPLICA 'replica_name' FROM TABLE database.table;

-- Option 2: Restart replication
SYSTEM RESTART REPLICAS;

-- Option 3: Sync from another replica (last resort)
SYSTEM SYNC REPLICA database.table STRICT;
```

#### Problem 3: ZooKeeper High Latency

**Symptoms:**
```bash
echo mntr | nc localhost 2181 | grep zk_avg_latency
# Output: zk_avg_latency   150  # > 100ms is concerning
```

**Common Causes:**
- Disk I/O bottleneck on ZK data directory
- Insufficient ZK memory (JVM heap)
- Network saturation
- Too many znodes (ZK data cleanup needed)

**Check ZK disk I/O:**
```bash
# On ZK server
iostat -x 1 10 | grep sda  # Replace with your ZK data disk
```

**Check ZK memory:**
```bash
# On ZK server
free -h
ps aux | grep zookeeper | grep -v grep
```

### 5.9 ZooKeeper Maintenance Tasks

#### A. ZooKeeper Log Cleanup (Replication Log)

**Check log size:**
```sql
SELECT
    count() AS log_entries,
    formatReadableSize(sum(dataLength)) AS total_size
FROM system.zookeeper
WHERE path = '/clickhouse/tables/{shard}/database.table/log';
```

**Manual cleanup (if needed):**
```sql
-- ClickHouse automatically cleans old log entries
-- Check cleanup settings
SELECT * FROM system.settings WHERE name LIKE '%replicated_deduplication%';

-- Force cleanup (use with caution)
SYSTEM CLEANUP TABLE database.table;
```

#### B. Monitor ZK Disk Usage

```bash
# On ZK servers
df -h /var/lib/zookeeper  # Or your ZK data directory
du -sh /var/lib/zookeeper/*

# Check ZK snapshot and log files
ls -lh /var/lib/zookeeper/version-2/
```

**Alert Threshold:** ZK disk > 80% full

### 5.10 ZooKeeper Alerts (Prometheus/Grafana)

```sql
-- Alert: Replica session expired
SELECT
    database,
    table,
    replica_name
FROM system.replicas
WHERE is_session_expired = 1;

-- Alert: High replication lag
SELECT
    database,
    table,
    absolute_delay
FROM system.replicas
WHERE absolute_delay > 300;  -- 5 minutes

-- Alert: Large replication queue
SELECT
    database,
    table,
    queue_size
FROM system.replicas
WHERE queue_size > 100;
```

### 5.11 ZooKeeper Configuration Best Practices

**Recommended ClickHouse ZK Settings:**

```xml
<!-- /etc/clickhouse-server/config.d/zookeeper.xml -->
<zookeeper>
    <node>
        <host>zk1.domain.com</host>
        <port>2181</port>
    </node>
    <node>
        <host>zk2.domain.com</host>
        <port>2181</port>
    </node>
    <node>
        <host>zk3.domain.com</host>
        <port>2181</port>
    </node>
    
    <!-- Session timeout (default: 30000ms) -->
    <session_timeout_ms>30000</session_timeout_ms>
    
    <!-- Connection timeout (default: 10000ms) -->
    <operation_timeout_ms>10000</operation_timeout_ms>
    
    <!-- Enable compression for large data transfers -->
    <compression>true</compression>
</zookeeper>
```

**ZooKeeper Server Settings (zoo.cfg):**

```properties
# Tick time in milliseconds (heartbeat interval)
tickTime=2000

# Init and sync limits (in ticks)
initLimit=10
syncLimit=5

# Data directory
dataDir=/var/lib/zookeeper

# Client port
clientPort=2181

# Server list (for 3-node cluster)
server.1=zk1:2888:3888
server.2=zk2:2888:3888
server.3=zk3:2888:3888

# Performance tuning
maxClientCnxns=0
autopurge.snapRetainCount=3
autopurge.purgeInterval=24
```

---

## 6. 1-Shard / 2-Replica Architecture (Your Setup)

### 6.1 Architecture Overview

**Your Configuration:**
```
┌─────────────┐         ┌─────────────┐
│  Replica 1  │ ←──┬──→ │  Replica 2  │
│  (Primary)  │    │    │  (Secondary)│
└─────────────┘    │    └─────────────┘
       ↓           │           ↓
    [Shard 1]      │      [Shard 1]
                   │
                   ↓
           ┌───────────────┐
           │   ZooKeeper   │
           │  (3 nodes)    │
           └───────────────┘
```

**Key Characteristics:**
- **1 Shard:** All data on one shard (no horizontal partitioning)
- **2 Replicas:** Full data redundancy
- **3 ZK Nodes:** Quorum-based coordination
- **HA:** Can survive 1 replica failure + 1 ZK node failure

### 6.2 Table Configuration for 2-Replica Setup

#### A. ReplicatedMergeTree Table Definition

```sql
-- Create replicated table on BOTH replicas
CREATE TABLE events_replicated ON CLUSTER '{cluster}'
(
    event_time DateTime,
    user_id UInt64,
    event_type String,
    -- more columns...
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/events_replicated',  -- ZK path
    '{replica}'                                       -- Replica name
)
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time)
SETTINGS
    -- Replication settings
    replicated_deduplication_window = 100,           -- Default: 100
    replicated_deduplication_window_seconds = 604800, -- 7 days
    
    -- For high availability
    min_replicated_logs_to_keep = 10,
    max_replicated_logs_to_keep = 1000,
    
    -- Part movement
    old_parts_lifetime = 480,  -- 8 minutes (default: 480)
    
    -- Merge settings (see section 4)
    parts_to_throw_insert = 400,
    parts_to_delay_insert = 200;
```

**Key Settings Explained:**

| Setting | Purpose | Recommendation for 2-Replica |
|---------|---------|------------------------------|
| `replicated_deduplication_window` | How many recent blocks to check for duplicates | 100-200 (higher for idempotent inserts) |
| `replicated_deduplication_window_seconds` | Time window for deduplication | 604800 (7 days) - increase for delayed data |
| `min_replicated_logs_to_keep` | Minimum replication log entries | 10 (ensures recent history) |
| `max_replicated_logs_to_keep` | Maximum log entries before cleanup | 1000 (prevents ZK bloat) |

#### B. Distributed Table for Load Balancing

```sql
-- Create distributed table for read load balancing
CREATE TABLE events_distributed ON CLUSTER '{cluster}'
AS events_replicated
ENGINE = Distributed(
    '{cluster}',          -- Cluster name
    currentDatabase(),    -- Database
    events_replicated,    -- Local table
    rand()                -- Sharding key (not relevant for 1 shard, but required)
)
SETTINGS
    fsync_after_insert = 1,  -- Ensure durability
    fsync_directories = 1;
```

### 6.3 Critical Monitoring for 2-Replica Setup

#### A. Replica Synchronization Status

```sql
-- MUST RUN: Daily health check for 2-replica setup
SELECT
    database,
    table,
    replica_name,
    is_leader,
    is_readonly,
    is_session_expired,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    log_max_index - log_pointer AS entries_behind,
    total_replicas,
    active_replicas,
    
    -- CRITICAL for 2-replica: Both must be active
    CASE
        WHEN active_replicas = 2 THEN '✅ Both replicas active'
        WHEN active_replicas = 1 THEN '⚠️ ONE REPLICA DOWN - NO REDUNDANCY!'
        ELSE '🚨 BOTH REPLICAS DOWN'
    END AS replication_status,
    
    formatReadableTimeDelta(absolute_delay) AS lag
FROM system.replicas
WHERE database NOT IN ('system')
ORDER BY active_replicas ASC, absolute_delay DESC;
```

**Interpretation:**
- ✅ `active_replicas = 2` → Healthy, full redundancy
- ⚠️ `active_replicas = 1` → **DEGRADED** - One replica down, NO FAULT TOLERANCE
- 🚨 `active_replicas < 1` → **OUTAGE** - Service disruption

#### B. Quorum Insert Verification

```sql
-- Verify INSERT quorum settings
SELECT
    name,
    value
FROM system.settings
WHERE name IN (
    'insert_quorum',
    'insert_quorum_timeout',
    'insert_quorum_parallel',
    'select_sequential_consistency'
)
ORDER BY name;
```

**Recommended Settings for 2-Replica:**

```sql
-- For CRITICAL data (requires both replicas to acknowledge)
SET insert_quorum = 2;                    -- Both replicas must confirm
SET insert_quorum_timeout = 60000;       -- 60 seconds timeout
SET insert_quorum_parallel = 1;          -- Allow parallel quorum inserts

-- For READS
SET select_sequential_consistency = 1;   -- Ensure read-after-write consistency
```

**Trade-offs:**

| Setting | Benefit | Cost |
|---------|---------|------|
| `insert_quorum = 2` | Guaranteed durability (both replicas) | Slower inserts, fails if 1 replica down |
| `insert_quorum = 1` | Faster inserts, works with 1 replica | Potential data loss if primary fails before replication |
| `select_sequential_consistency = 1` | Read-after-write consistency | Slightly slower reads |

### 6.4 Failure Scenarios & Recovery

#### Scenario 1: One Replica Down

**Detection:**
```sql
SELECT * FROM system.replicas WHERE active_replicas = 1;
```

**Impact:**
- ⚠️ **NO REDUNDANCY** - Single point of failure
- ✅ Service continues normally (reads and writes)
- ⚠️ If `insert_quorum = 2`, inserts will FAIL

**Recovery Steps:**

1. **Check which replica is down:**
```sql
SELECT
    replica_name,
    is_readonly,
    is_session_expired,
    last_queue_update
FROM system.replicas
WHERE active_replicas = 1;
```

2. **On the failed replica server:**
```bash
# Check ClickHouse service
systemctl status clickhouse-server

# Check logs
tail -f /var/log/clickhouse-server/clickhouse-server.err.log

# Check ZK connectivity
echo ruok | nc zk1 2181
```

3. **Restart replica:**
```bash
systemctl restart clickhouse-server
```

4. **Force sync (if needed):**
```sql
-- On the recovered replica
SYSTEM RESTART REPLICAS;
SYSTEM SYNC REPLICA database.table;
```

5. **Monitor catch-up:**
```sql
SELECT
    database,
    table,
    absolute_delay,
    queue_size,
    formatReadableTimeDelta(absolute_delay) AS lag
FROM system.replicas;
```

#### Scenario 2: ZooKeeper Node Down

**Your 3-node ZK can tolerate 1 failure (quorum = 2/3)**

**Detection:**
```bash
# Check ZK ensemble status
for host in zk1 zk2 zk3; do
    echo "=== $host ==="
    echo stat | nc $host 2181 | grep Mode
done
```

**Impact:**
- ✅ ClickHouse continues normally (2 ZK nodes still form quorum)
- ⚠️ If another ZK node fails → **CLUSTER READ-ONLY**

**Recovery:**
```bash
# On failed ZK node
systemctl restart zookeeper

# Verify it rejoined
echo stat | nc zk-failed-node 2181
```

#### Scenario 3: Both Replicas Down (DISASTER)

**Impact:**
- 🚨 **COMPLETE OUTAGE**
- No reads or writes possible

**Recovery Priority:**

1. **Bring up ANY ONE replica first:**
```bash
# On healthier replica (check which has more recent data)
systemctl start clickhouse-server
```

2. **Check data integrity:**
```sql
-- On recovered replica
SELECT database, table, count() AS parts
FROM system.parts
WHERE active = 1
GROUP BY database, table;
```

3. **Bring up second replica:**
```bash
systemctl start clickhouse-server
```

4. **Verify sync:**
```sql
SELECT * FROM system.replicas;
SYSTEM SYNC REPLICA database.table;
```

### 6.5 Best Practices for 1-Shard/2-Replica

#### A. Insert Strategy

**Option 1: Insert to Distributed Table (RECOMMENDED)**
```sql
-- Inserts are automatically balanced across both replicas
INSERT INTO events_distributed VALUES (...);
```

**Benefits:**
- Automatic load balancing
- Better write throughput
- Fault tolerance (continues if 1 replica down, with `insert_quorum = 1`)

**Option 2: Insert to Specific Replica**
```sql
-- Insert to replica 1 only (replication happens automatically)
INSERT INTO events_replicated VALUES (...);
```

**Benefits:**
- Guaranteed single point of truth
- Simpler to reason about

#### B. Query Strategy

**For High Availability:**
```sql
-- Query distributed table (load balanced across replicas)
SELECT * FROM events_distributed WHERE ...;
```

**For Specific Replica:**
```sql
-- Direct query to replica (useful for debugging)
SELECT * FROM events_replicated WHERE ...;
```

#### C. Monitoring Queries for Daily Health Checks

```sql
-- DAILY CHECK #1: Replica health
SELECT
    database,
    table,
    active_replicas,
    absolute_delay,
    queue_size,
    is_readonly,
    is_session_expired
FROM system.replicas
WHERE database NOT IN ('system')
ORDER BY active_replicas ASC, absolute_delay DESC;

-- DAILY CHECK #2: Replication lag
SELECT
    database,
    table,
    replica_name,
    formatReadableTimeDelta(absolute_delay) AS lag,
    queue_size
FROM system.replicas
WHERE absolute_delay > 60;  -- More than 1 minute lag

-- DAILY CHECK #3: Failed replication tasks
SELECT
    database,
    table,
    type,
    last_exception,
    num_tries
FROM system.replication_queue
WHERE num_tries > 10;
```

### 6.6 Configuration Files for 1-Shard/2-Replica

#### A. Cluster Configuration

**File:** `/etc/clickhouse-server/config.d/cluster.xml`

```xml
<remote_servers>
    <production_cluster>
        <shard>
            <internal_replication>true</internal_replication>
            <replica>
                <host>replica1.domain.com</host>
                <port>9000</port>
                <user>default</user>
                <password>your_password</password>
            </replica>
            <replica>
                <host>replica2.domain.com</host>
                <port>9000</port>
                <user>default</user>
                <password>your_password</password>
            </replica>
        </shard>
    </production_cluster>
</remote_servers>
```

#### B. Macros Configuration

**File:** `/etc/clickhouse-server/config.d/macros.xml`

**On Replica 1:**
```xml
<macros>
    <cluster>production_cluster</cluster>
    <shard>01</shard>
    <replica>replica1</replica>
</macros>
```

**On Replica 2:**
```xml
<macros>
    <cluster>production_cluster</cluster>
    <shard>01</shard>
    <replica>replica2</replica>
</macros>
```

### 6.7 Disaster Recovery Procedures

#### A. Backup Strategy

```bash
#!/bin/bash
# Daily backup script (run on BOTH replicas)

BACKUP_DIR="/backups/clickhouse/$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

# Backup metadata
clickhouse-client --query="SELECT create_table_query FROM system.tables WHERE database NOT IN ('system')" > $BACKUP_DIR/schema.sql

# Backup data using clickhouse-backup tool (recommended)
clickhouse-backup create daily_backup_$(date +%Y%m%d)
clickhouse-backup upload daily_backup_$(date +%Y%m%d)
```

#### B. Point-in-Time Recovery

```sql
-- Create backup table before risky operation
CREATE TABLE events_backup AS events_replicated;

-- If something goes wrong, restore
INSERT INTO events_replicated SELECT * FROM events_backup;
```

### 6.8 Alerts for 1-Shard/2-Replica Setup

```sql
-- CRITICAL ALERT: Only 1 replica active (NO REDUNDANCY)
SELECT
    database,
    table,
    active_replicas
FROM system.replicas
WHERE active_replicas < 2;

-- WARNING ALERT: Replication lag > 5 minutes
SELECT
    database,
    table,
    absolute_delay
FROM system.replicas
WHERE absolute_delay > 300;

-- CRITICAL ALERT: Replica is read-only
SELECT
    database,
    table,
    replica_name
FROM system.replicas
WHERE is_readonly = 1;
```

---

## 7. Replication & Distribution

### 7.1 Replication Queue

**Use Case:** Monitor replication lag and failures

**System Table:** `system.replication_queue`

```sql
-- Replication queue status per table
SELECT
    database,
    table,
    count() AS queue_size,
    countIf(is_currently_executing) AS executing,
    countIf(num_tries > 3) AS failed_attempts,
    max(num_tries) AS max_tries,
    min(create_time) AS oldest_entry,
    formatReadableTimeDelta(now() - min(create_time)) AS max_lag
FROM system.replication_queue
GROUP BY database, table
ORDER BY queue_size DESC;
```

**Warning Thresholds:**
- Queue size > 100 entries
- Max lag > 5 minutes
- Multiple entries with `num_tries > 10`

**Action Items:**
- Check network connectivity between replicas
- Review `last_exception` field for specific errors
- Verify ZooKeeper/ClickHouse Keeper health
- Consider `SYSTEM RESTART REPLICA` for stuck tables

### 5.2 Replica Status

**Use Case:** Verify replica health and synchronization

**System Table:** `system.replicas`

```sql
-- Replica synchronization status
SELECT
    database,
    table,
    is_leader,
    is_readonly,
    is_session_expired,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    log_max_index,
    log_pointer,
    total_replicas,
    active_replicas
FROM system.replicas
WHERE absolute_delay > 0 OR queue_size > 0
ORDER BY absolute_delay DESC;
```

**Critical Checks:**
- `is_readonly = 1` - Replica can't accept writes
- `is_session_expired = 1` - Lost connection to Keeper
- `absolute_delay > 300` - Significant replication lag
- `active_replicas < total_replicas` - Some replicas offline

### 5.3 Distribution Queue

**Use Case:** Monitor distributed table insert queues

**System Table:** `system.distribution_queue`

```sql
-- Distributed table pending batches
SELECT
    database,
    table,
    data_path,
    is_blocked,
    error_count,
    data_files,
    data_compressed_bytes,
    last_exception
FROM system.distribution_queue
WHERE data_files > 0 OR is_blocked = 1
ORDER BY data_files DESC;
```

**Action Items:**
- `is_blocked = 1` - Check remote shard availability
- High `error_count` - Review `last_exception`
- Growing `data_files` - Network or remote shard issues

---

## 6. CPU & Memory Monitoring

### 6.1 Current Metrics Snapshot

**Use Case:** Real-time resource utilization

**System Tables:** `system.metrics`, `system.asynchronous_metrics`

```sql
-- Key resource metrics
SELECT
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN (
    'Query',
    'Merge',
    'BackgroundPoolTask',
    'MemoryTracking',
    'MaxPartCountForPartition'
)
ORDER BY metric;

-- CPU and memory from async metrics
SELECT
    metric,
    value
FROM system.asynchronous_metrics
WHERE metric IN (
    'jemalloc.resident',
    'jemalloc.allocated',
    'OSMemoryTotal',
    'OSMemoryAvailable',
    'LoadAverage1',
    'LoadAverage5',
    'LoadAverage15'
)
ORDER BY metric;
```

### 6.2 Historical Metrics

**Use Case:** Trend analysis and capacity planning

**System Table:** `system.metric_log`

```sql
-- Memory and CPU trends (last 24 hours)
SELECT
    toStartOfHour(event_time) AS hour,
    avg(CurrentMetrics['MemoryTracking']) AS avg_memory_usage,
    max(CurrentMetrics['MemoryTracking']) AS peak_memory_usage,
    avg(CurrentMetrics['Query']) AS avg_concurrent_queries,
    max(CurrentMetrics['Query']) AS peak_concurrent_queries
FROM system.metric_log
WHERE event_date >= today() - 1
GROUP BY hour
ORDER BY hour DESC;
```

### 6.3 Memory Usage by Query

**Use Case:** Identify memory leaks or inefficient queries

```sql
-- Top memory consumers (current)
SELECT
    query_id,
    user,
    formatReadableSize(memory_usage) AS current_memory,
    formatReadableSize(peak_memory_usage) AS peak_memory,
    elapsed,
    substring(query, 1, 100) AS query_preview
FROM system.processes
ORDER BY memory_usage DESC
LIMIT 10;
```

---

## 7. Network & I/O

### 7.1 Disk Performance

**System Table:** `system.disks`

```sql
-- Disk space and performance
SELECT
    name,
    path,
    formatReadableSize(free_space) AS free_space,
    formatReadableSize(total_space) AS total_space,
    round(free_space / total_space * 100, 2) AS free_percent,
    formatReadableSize(unreserved_space) AS unreserved
FROM system.disks
ORDER BY free_percent ASC;
```

**Warning Thresholds:**
- Free space < 20%
- Free space < 100GB

### 7.2 Part Movement Tracking

**Use Case:** Monitor data movement between disks/volumes

**System Table:** `system.moves`

```sql
-- Active part moves
SELECT
    database,
    table,
    elapsed,
    target_disk_name,
    part_name,
    formatReadableSize(part_size) AS size,
    round(elapsed, 2) AS seconds_elapsed
FROM system.moves
ORDER BY elapsed DESC;
```

---

## 8. Error Analysis

### 8.1 Error Frequency

**Use Case:** Identify recurring errors

**System Table:** `system.errors`

```sql
-- Most common errors
SELECT
    name,
    code,
    value AS occurrences,
    last_error_time,
    last_error_message
FROM system.errors
WHERE value > 0
ORDER BY value DESC
LIMIT 20;
```

**Action Priority:**
- Focus on errors with high `value`
- Review `last_error_message` for context
- Check `last_error_trace` for stack traces

---

## 9. Cluster-Wide Queries

### 9.1 Query All Nodes

**Use Case:** Gather metrics from entire cluster

```sql
-- Running queries across all replicas
SELECT
    hostName() AS host,
    count() AS active_queries,
    sum(memory_usage) AS total_memory,
    max(elapsed) AS longest_query
FROM clusterAllReplicas(default, system.processes)
GROUP BY host
ORDER BY active_queries DESC;
```

```sql
-- Replication lag across cluster
SELECT
    hostName() AS host,
    database,
    table,
    absolute_delay,
    queue_size
FROM clusterAllReplicas(default, system.replicas)
WHERE absolute_delay > 0
ORDER BY absolute_delay DESC;
```

---

## 10. Common Error Codes Reference

| Code | Name | Typical Cause | Action |
|------|------|---------------|--------|
| 23 | CANNOT_READ_FROM_ISTREAM | Corrupted data / network issue | Check part integrity |
| 47 | UNKNOWN_IDENTIFIER | Missing column / typo | Verify schema |
| 236 | ABORTED | Operation cancelled | Check system load |
| 241 | MEMORY_LIMIT_EXCEEDED | Query too large | Increase limits or optimize |
| 389 | INSERT_WAS_DEDUPLICATED | Duplicate insert | Expected behavior |
| 394 | QUERY_WAS_CANCELLED | User/system cancellation | Review why cancelled |
| 1000 | POCO_EXCEPTION | Network/connection error | Check network |

---

## 11. Alert Thresholds (Recommendations)

### Critical Alerts
- Disk usage > 90%
- Replication lag > 10 minutes
- `is_readonly = 1` on any replica
- Failed queries > 10% of total in last hour
- Memory usage > 90% of node capacity
- **Active replicas < 2 in 2-replica setup** (NO REDUNDANCY)
- **Part count > 350 per partition** (approaching INSERT failure)
- **ZK session expired** (`is_session_expired = 1`)
- **ZK nodes down ≥ 2** (quorum lost)
- **Background merge pool saturated** for > 10 minutes

### Warning Alerts
- Disk usage > 70%
- Replication queue > 100 entries
- Merge running > 1 hour
- More than 200 active parts per partition
- Query duration > 5 minutes (adjust per use case)
- **Active replicas = 1** in 2-replica setup (degraded mode)
- **Replication lag > 5 minutes**
- **Part count > 200 per partition**
- **ZK average latency > 50ms**
- **Failed replication tasks with num_tries > 5**

---

## 12. Quick Diagnostic Script

```sql
-- Comprehensive health check
SELECT 'CURRENT_QUERIES' AS check_type, count() AS value FROM system.processes
UNION ALL
SELECT 'ACTIVE_MERGES', count() FROM system.merges
UNION ALL
SELECT 'REPLICATION_QUEUE', count() FROM system.replication_queue
UNION ALL
SELECT 'FAILED_QUERIES_1H', count() 
FROM system.query_log 
WHERE type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
  AND event_time > now() - INTERVAL 1 HOUR
UNION ALL
SELECT 'READONLY_REPLICAS', countIf(is_readonly = 1) FROM system.replicas
UNION ALL
SELECT 'EXPIRED_ZK_SESSIONS', countIf(is_session_expired = 1) FROM system.replicas
UNION ALL
SELECT 'ACTIVE_REPLICAS_MIN', min(active_replicas) FROM system.replicas WHERE database NOT IN ('system')
UNION ALL
SELECT 'MAX_PARTS_PER_PARTITION', max(part_count) FROM (
    SELECT count() AS part_count FROM system.parts WHERE active = 1 GROUP BY database, table, partition
)
UNION ALL
SELECT 'MAX_REPLICATION_LAG_SEC', max(absolute_delay) FROM system.replicas
UNION ALL
SELECT 'DISK_USAGE_PCT', round((1 - min(free_space / total_space)) * 100, 2) FROM system.disks
UNION ALL
SELECT 'BACKGROUND_POOL_UTILIZATION', value FROM system.metrics WHERE metric = 'BackgroundPoolTask'
UNION ALL
SELECT 'ZK_CONNECTION_HEALTHY', countIf(is_expired = 0) FROM system.zookeeper_connection;
```

**Healthy Output Should Show:**
- `READONLY_REPLICAS`: 0
- `EXPIRED_ZK_SESSIONS`: 0
- `ACTIVE_REPLICAS_MIN`: 2 (for 2-replica setup)
- `MAX_PARTS_PER_PARTITION`: < 200
- `MAX_REPLICATION_LAG_SEC`: < 60
- `DISK_USAGE_PCT`: < 70
- `ZK_CONNECTION_HEALTHY`: Should equal number of ZK nodes

---

## 13. Additional Resources

- **Official Docs:** https://clickhouse.com/docs/en/operations/system-tables/
- **Settings Reference:** https://clickhouse.com/docs/en/operations/settings/
- **Error Codes:** https://github.com/ClickHouse/ClickHouse/blob/master/src/Common/ErrorCodes.cpp
- **System Tables Blog:** https://clickhouse.com/blog/clickhouse-debugging-issues-with-system-tables
- **MergeTree Settings:** https://chistadata.com/mergetree-settings-clickhouse-performance/
- **Replication Guide:** https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication
- **ZooKeeper Configuration:** https://clickhouse.com/docs/en/operations/tips/#zookeeper

---

## 16. Quick Reference Cheat Sheet

### Daily Health Checks (Run Every Morning)

```bash
#!/bin/bash
# daily_health_check.sh

echo "=== ClickHouse Daily Health Check ==="
echo ""

# 1. Check replica status
echo "1. REPLICA STATUS:"
clickhouse-client --query="
SELECT database, table, active_replicas, absolute_delay, is_readonly
FROM system.replicas 
WHERE database NOT IN ('system')
FORMAT PrettyCompact"
echo ""

# 2. Check part counts
echo "2. PART COUNTS (Top 5):"
clickhouse-client --query="
SELECT database, table, partition, count() AS parts
FROM system.parts 
WHERE active = 1 
GROUP BY database, table, partition 
HAVING parts > 50
ORDER BY parts DESC 
LIMIT 5 
FORMAT PrettyCompact"
echo ""

# 3. Check active merges
echo "3. ACTIVE MERGES:"
clickhouse-client --query="
SELECT database, table, elapsed, progress 
FROM system.merges 
FORMAT PrettyCompact"
echo ""

# 4. Check ZK health
echo "4. ZOOKEEPER STATUS:"
for host in zk1 zk2 zk3; do
    echo -n "$host: "
    echo ruok | nc -w 2 $host 2181
done
echo ""

# 5. Check disk usage
echo "5. DISK USAGE:"
clickhouse-client --query="
SELECT name, round(free_space/total_space*100,2) AS free_pct 
FROM system.disks 
FORMAT PrettyCompact"
echo ""

echo "=== Health Check Complete ==="
```

### Emergency Commands

```sql
-- Stop all merges (emergency brake)
SYSTEM STOP MERGES;

-- Restart specific replica
SYSTEM RESTART REPLICA database.table;

-- Sync replica from leader
SYSTEM SYNC REPLICA database.table STRICT;

-- Kill long-running query
KILL QUERY WHERE query_id = '...';

-- Kill mutation
KILL MUTATION WHERE database='...' AND table='...' AND mutation_id='...';

-- Clear replication queue (DANGEROUS - last resort)
-- SYSTEM DROP REPLICA 'replica_name' FROM TABLE database.table;
```

### Performance Tuning Quick Reference

| Symptom | Likely Cause | Quick Fix |
|---------|--------------|-----------|
| Slow inserts | Too aggressive merging | Increase `parts_to_throw_insert` |
| Slow queries | Too many parts | Increase `background_pool_size` |
| "Too many parts" error | Merges can't keep up | Increase both settings above |
| High memory usage | Large merges | Decrease `max_bytes_to_merge_at_max_space_in_pool` |
| Replication lag | ZK latency or network | Check ZK health, network |
| Insert failures | Quorum not met | Check replica status, adjust `insert_quorum` |

---

## Notes

- Always test queries in non-production first
- System tables in `system` database are read-only
- Most system log tables use MergeTree and persist to disk
- Use `FORMAT Vertical` for detailed single-row inspection
- Cluster queries require `clusterAllReplicas()` function
