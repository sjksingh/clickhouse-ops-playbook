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

## 4. Merge & Mutation Operations

### 4.1 Active Merges

**Use Case:** Monitor merge progress and identify bottlenecks

**System Table:** `system.merges`

```sql
-- In-progress merges with ETA
SELECT
    database,
    table,
    round(elapsed, 0) AS elapsed_seconds,
    round(progress * 100, 2) AS percent_complete,
    formatReadableTimeDelta((elapsed / progress) - elapsed) AS ETA,
    num_parts AS parts_merging,
    formatReadableSize(total_size_bytes_compressed) AS merge_size,
    formatReadableSize(memory_usage) AS memory,
    result_part_name
FROM system.merges
ORDER BY elapsed DESC;
```

**Warning Signs:**
- Merge running > 1 hour with low progress
- Multiple large merges competing for resources
- Memory usage approaching node limits

**Action Items:**
- Adjust `background_pool_size` if queue is backing up
- Check disk I/O with `system.disks` and `system.asynchronous_metrics`
- Consider `STOP MERGES` temporarily during critical operations

### 4.2 Merge Queue Depth

**Use Case:** Detect merge backlog

```sql
-- Tables with most parts (potential merge backlog)
SELECT
    database,
    table,
    count() AS num_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE active = 1
  AND database NOT IN ('system')
GROUP BY database, table
HAVING num_parts > 100
ORDER BY num_parts DESC;
```

**Thresholds:**
- > 300 parts per partition = significant backlog
- > 1000 parts = critical, performance degraded

### 4.3 Long-Running Mutations

**Use Case:** Track ALTER/UPDATE/DELETE operations

**System Table:** `system.mutations`

```sql
-- Active mutations with progress
SELECT
    database,
    table,
    mutation_id,
    command,
    create_time,
    parts_to_do,
    is_done,
    latest_failed_part,
    latest_fail_reason,
    formatReadableTimeDelta(now() - create_time) AS running_time
FROM system.mutations
WHERE is_done = 0
ORDER BY create_time ASC;
```

**Action Items:**
- Mutations can block merges - monitor closely
- Kill stuck mutations: `KILL MUTATION WHERE mutation_id = '...'`
- Review `latest_fail_reason` for errors

---

## 5. Replication & Distribution

### 5.1 Replication Queue

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

### Warning Alerts
- Disk usage > 70%
- Replication queue > 100 entries
- Merge running > 1 hour
- More than 500 active parts per partition
- Query duration > 5 minutes (adjust per use case)

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
SELECT 'DISK_USAGE_PCT', round((1 - min(free_space / total_space)) * 100, 2) FROM system.disks;
```

---

## 13. Additional Resources

- **Official Docs:** https://clickhouse.com/docs/en/operations/system-tables/
- **Settings Reference:** https://clickhouse.com/docs/en/operations/settings/
- **Error Codes:** https://github.com/ClickHouse/ClickHouse/blob/master/src/Common/ErrorCodes.cpp
- **Blog Post:** https://clickhouse.com/blog/clickhouse-debugging-issues-with-system-tables

---

## Notes

- Always test queries in non-production first
- System tables in `system` database are read-only
- Most system log tables use MergeTree and persist to disk
- Use `FORMAT Vertical` for detailed single-row inspection
- Cluster queries require `clusterAllReplicas()` function
