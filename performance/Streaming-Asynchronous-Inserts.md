# ClickHouse Streaming Asynchronous Inserts - Platform DBRE Guide

## Executive Summary

**Scale:** 16,000 events/sec average, peaks >100,000 events/sec  
**Platform:** Google Cloud Platform (GCP)  
**Ingestion:** Cloud Dataflow → ClickHouse  
**Format Evolution:** JSON → RowBinary (70-80% cost reduction)  
**Key Win:** Async inserts + proper monitoring = stable, cost-effective ingestion

---

## Architecture Overview

### Data Flow
```
Events → GCP Pub/Sub → Cloud Dataflow → ClickHouse Cluster
                              ↓
                      Dead Letter Queue (failed inserts)
```

### Technology Stack
- **Ingestion Framework:** Google Cloud Dataflow (Runner V1 - legacy)
- **ClickHouse Client:** Java Client v2
- **Data Format:** RowBinary (production), previously JSON and Apache Arrow
- **Custom Logic:** Dichotomous inserts with dead letter PubSub topic

---

## Performance Optimization Journey

### Phase 1: Apache Arrow (Deprecated)
- **Result:** Decent throughput
- **Blocker:** Required JVM option `JAVA_TOOL_OPTIONS="-add-opens=java.base/java.nio=org.apache.arrow.memory.core,ALL-UNNAMED"`
- **Impact:** Forced Runner V2 migration → 2x Dataflow costs
- **Instability:** Parallel ingestion tuning (workers/threads) never stabilized

### Phase 2: JSON Format (Temporary)
- **Action:** Reverted to JSON + legacy Runner V1
- **Result:** Platform stabilization
- **Status:** Transitional solution

### Phase 3: RowBinary Format (Current Production)
- **Network Bandwidth:** 70-80% reduction
- **Dataflow Cost:** Dramatic reduction (legacy runner compatible)
- **Scaling:** Resolved worker scaling issues
- **Batch Size:** Optimized to 3.5k rows (down from 30k max)
  - Flat memory usage
  - Significantly lower CPU usage
  - Enabled machine type downgrades

---

## ClickHouse Storage Architecture

### Storage Model
ClickHouse uses columnar storage where:
- Each column is stored in separate files
- Data is logically split into **granules**
- Writes create small immutable **parts**
- Background merges consolidate parts into larger ones

### Part Types

#### 1. Compact Parts
- All columns in one file
- Merge algorithm: **Horizontal**
- ~85% of merges
- Smaller size (see distribution below)

#### 2. Wide Parts
- Each column in separate file
- Merge algorithm: **Vertical**
- ~15% of merges
- Orders of magnitude larger than Compact parts

**Note:** `column_data_compressed_bytes` and `column_data_uncompressed_bytes` in `system.parts_columns` are calculated for Wide parts only.

### Part Lifecycle
Monitor via `system.part_log`:

```sql
SELECT 
   event_time,
   event_type,
   part_type,
   merge_reason,
   merge_algorithm,
   duration_ms,
   part_name,
   rows,
   read_rows,
   peak_memory_usage
FROM system.part_log
WHERE event_date = '2025-09-01'
  AND database = 'my_database'
  AND table = 'my_table'
  AND (part_name = 'my_part_name' OR has(merged_from, 'my_part_name'))
```

**Typical Sequence:**
1. `NewPart` - New part created
2. `DownloadPart` - Replicated to other nodes (simultaneous with GCS backend)
3. `MergeParts` - Part merged into larger part (e.g., 1,249 rows → 104,772 total read)
4. `RemovePart` - Old part deleted from all nodes

---

## Asynchronous Inserts Implementation

### Java Client Configuration

```java
.serverSetting("async_insert", "1")
.serverSetting("wait_for_async_insert", "1")
.serverSetting("async_insert_max_data_size", "104857600")  // 100MB
.serverSetting("async_insert_busy_timeout_min_ms", "500")
.serverSetting("async_insert_busy_timeout_max_ms", "5000")
```

### Behavior Characteristics

**Batch Aggregation:**
- Multiple insert batches combined into single flush
- Dataflow batch: 3.5k rows average (30k max)
- ClickHouse creates parts: 40-60k rows
- Merge operations: 130k to 1M+ rows

**Materialized View Cascade:**
- Base table: `unicollect.session_event`
- MV: `unicollect.session_campaign` (un-nested form)
- MV generates more small parts than base table
- All cascades tracked in `system.part_log`

---

## Monitoring Implementation

### System Tables Used
1. `system.asynchronous_insert_log` - Async insert requests
2. `system.query_log` - Flush query execution
3. `system.part_log` - Part creation and merges

### Monitoring View Architecture

#### Step 1: Extract Async Insert Logs
```sql
flush_data AS (
    SELECT
        flush_time,
        flush_query_id,  -- Groups multiple inserts
        query_id,        -- Individual insert request
        rows             -- Rows per request
    FROM system.asynchronous_insert_log
    WHERE toDate(event_date) BETWEEN toDate(min_date) AND toDate(max_date)
      AND toDateTime(event_time) BETWEEN toDateTime(min_datetime) AND toDateTime(max_datetime)
      AND database = database_name
      AND table = table_name
)
```

#### Step 2: Retrieve Flush Execution
```sql
query_data AS (
    SELECT
        query_id,          -- Maps to flush_query_id
        query_kind,        -- Always 'AsyncInsertFlush'
        read_rows,         -- Rows read during flush
        written_rows       -- Rows written during flush
    FROM system.query_log
    WHERE toDate(event_date) BETWEEN toDate(min_date) AND toDate(max_date)
      AND toDateTime(event_time) BETWEEN toDateTime(min_datetime) AND toDateTime(max_datetime)
      AND type = 'QueryFinish'
)
```

#### Step 3: Summarize Flush Operations
```sql
flush_summarize AS (
    SELECT
        fd.flush_time,
        fd.flush_query_id,
        query_data.query_kind,
        toJSONString(mapFromArrays(
            groupArray(query_id),
            groupArray(toInt16(rows))
        )) AS queries_to_rows_json,  -- Request mapping
        sum(fd.rows) AS total_requested,
        query_data.read_rows AS flush_read_rows,
        query_data.written_rows AS flush_written_rows
    FROM flush_data AS fd
    LEFT JOIN query_data ON fd.flush_query_id = query_data.query_id
    GROUP BY fd.flush_time, flush_query_id, query_kind, flush_read_rows, flush_written_rows
)
```

#### Step 4: Track Part Creation
```sql
part_logs AS (
    SELECT
        query_id,                  -- Flush query ID
        database, table,
        event_type,                -- Always 'NewPart'
        merge_reason,              -- Always 'NotAMerge'
        part_name,
        part_type,                 -- Usually 'Compact'
        sum(rows) AS written_rows,
        sum(bytes_uncompressed) AS bytes
    FROM system.part_log
    WHERE toDate(event_date) BETWEEN toDate(min_date) AND toDate(max_date)
      AND toDateTime(event_time) BETWEEN toDateTime(min_datetime) AND toDateTime(max_datetime)
    GROUP BY query_id, database, table, part_name, event_type, merge_reason, part_type
)
```

#### Step 5: Capture Merge Operations
```sql
merged_parts AS (
    SELECT 
        merged_from,    -- Source part names
        duration_ms,    -- Merge duration
        rows,           -- Merged part rows
        read_rows       -- Rows read for merge
    FROM system.part_log
    ARRAY JOIN merged_from
    WHERE toDate(event_date) BETWEEN toDate(min_date) AND toDate(max_date)
      AND toDateTime(event_time) BETWEEN toDateTime(min_datetime) AND toDateTime(max_datetime)
      AND event_type = 'MergeParts'
)
```

#### Step 6: Complete Monitoring View
```sql
CREATE OR REPLACE VIEW monitoring.async_inserts_tracking AS
WITH 
    {min_date:String} AS min_date,
    {max_date:String} AS max_date,
    {min_datetime:String} AS min_datetime,
    {max_datetime:String} AS max_datetime,
    {database_name:String} AS database_name,
    {table_name:String} AS table_name,
    flush_data AS (...),
    query_data AS (...),
    flush_summarize AS (...),
    part_logs AS (...),
    merged_parts AS (...)
SELECT
    fs.flush_time,
    fs.flush_query_id,
    fs.query_kind,
    pl.event_type,
    pl.part_type,
    pl.merge_reason,
    fs.total_requested AS to_insert_rows,
    fs.flush_read_rows,
    fs.flush_written_rows,
    fs.queries_to_rows_json,
    pl.database,
    pl.table,
    pl.written_rows,
    pl.part_name,
    mp.duration_ms AS merge_duration,
    mp.rows AS merged_rows,
    sum(mp.rows) OVER(PARTITION BY fs.flush_query_id) AS total_merged_rows,
    mp.read_rows
FROM flush_summarize AS fs
LEFT JOIN part_logs AS pl ON fs.flush_query_id = pl.query_id
LEFT JOIN merged_parts AS mp ON pl.part_name = mp.merged_from
ORDER BY fs.flush_query_id, pl.database, pl.table, pl.event_type
COMMENT 'Asynchronous inserts monitoring';
```

---

## Grafana Dashboard Query

### Example: Monitor Materialized View Cascade
```sql
SELECT
    flush_time,
    CONCAT(database, '.', table) AS table,
    sum(written_rows) AS total_written,      -- Sum across multiple NewPart events
    median(merge_duration) AS med_merge_duration,
    sum(merged_rows) AS total_merged         -- Sum across multiple NewPart events
FROM monitoring.async_inserts_tracking(
    min_date = '${__from:date:YYYY-MM-DD}',
    max_date = '${__to:date:YYYY-MM-DD}',
    min_datetime = '${__from:date:YYYY-MM-DD HH:mm:SS}',
    max_datetime = '${__to:date:YYYY-MM-DD HH:mm:SS}',
    database_name = '${database}',
    table_name = '${table}'
)
WHERE table = '${session_event_mvs}'
GROUP BY flush_query_id, flush_time, table
ORDER BY flush_time ASC
```

---

## Key Metrics to Monitor

### Ingestion Health
- **Flush frequency:** Time between flush operations
- **Batch aggregation ratio:** Requested rows vs. flushed rows
- **Part creation rate:** NewPart events per minute
- **Dead letter queue depth:** Failed insert backlog

### Performance Indicators
- **Merge duration:** Median and P99 merge times
- **Part type distribution:** Compact vs. Wide ratio
- **Merge algorithm distribution:** Horizontal vs. Vertical
- **Read amplification:** `read_rows / written_rows` ratio

### Resource Utilization
- **Network bandwidth:** PSC throughput
- **CPU usage:** Dataflow workers and ClickHouse nodes
- **Memory usage:** Worker and node memory consumption
- **Part count:** Active parts per table (merge backlog indicator)

---

## Operational Runbook

### Troubleshooting High Merge Latency

1. **Check part accumulation:**
   ```sql
   SELECT table, count(*) AS part_count
   FROM system.parts
   WHERE active = 1
   GROUP BY table
   ORDER BY part_count DESC
   ```

2. **Identify merge bottlenecks:**
   ```sql
   SELECT 
       table,
       merge_algorithm,
       quantile(0.99)(duration_ms) AS p99_duration,
       count(*) AS merge_count
   FROM system.part_log
   WHERE event_type = 'MergeParts'
     AND event_date >= today() - 1
   GROUP BY table, merge_algorithm
   ```

3. **Review merge settings:**
   - `max_bytes_to_merge_at_max_space_in_pool`
   - `number_of_free_entries_in_pool_to_lower_max_size_of_merge`
   - `max_replicated_merges_in_queue`

### Handling Insert Failures

1. **Monitor dead letter queue** for non-transient failures
2. **Review error patterns** in Dataflow logs
3. **Check ClickHouse capacity:** CPU, memory, disk I/O
4. **Validate network connectivity** via PSC metrics

### Batch Size Tuning

Start with these parameters and adjust based on metrics:
- **Initial batch:** 3.5k rows
- **Window:** 30 seconds
- **Max data size:** 100MB
- **Timeout range:** 500-5000ms

Monitor CPU and memory impact, then adjust batch size if:
- CPU consistently >70%: Reduce batch size
- CPU consistently <30%: Increase batch size
- Parts accumulating: Increase flush timeout

---

## Cost Optimization Summary

### Network Costs
- **JSON → RowBinary:** 70-80% reduction in PSC bandwidth
- **Impact:** Proportional reduction in GCP network egress charges

### Compute Costs
- **Runner V2 → V1:** Avoided 2x Dataflow cost increase
- **Batch optimization:** Enabled machine type downgrades
- **CPU reduction:** 3.5k row batches vs. 30k max batches

### Trade-offs Avoided
- Apache Arrow performance gains insufficient to justify Runner V2 costs
- Instability of parallel worker tuning not worth operational burden

---

## Future Considerations

### Areas for Further Investigation
1. **Apache Arrow deep dive:** Dedicated analysis of Arrow implementation trade-offs
2. **Merge strategy tuning:** Optimize Compact→Wide transition thresholds
3. **Materialized view optimization:** Reduce part proliferation in MVs
4. **Multi-region replication:** Monitoring extensions for distributed deployments

### Potential Improvements
- Auto-scaling Dataflow workers based on ClickHouse merge backlog
- Dynamic batch size adjustment based on event velocity
- Predictive alerting on merge saturation
- Custom metrics for cascading materialized view health

---

## References

- **Source Article:** [Medium - AB Tasty Tech Blog](https://medium.com/the-ab-tasty-tech-blog/streaming-asynchronous-inserts-monitoring-in-clickhouse-c1378bd8b159)
- **ClickHouse Docs:** [Asynchronous Inserts](https://clickhouse.com/docs/en/optimize/asynchronous-inserts)
- **System Tables:** `system.asynchronous_insert_log`, `system.query_log`, `system.part_log`

---
