# ClickHouse Materialized Views - Platform DBRE Guide

## Executive Summary

**Purpose:** Precompute expensive aggregations and joins to shift work from query time to insert/batch time  
**Performance Gain:** Sub-second queries on billions of rows by reading precomputed tables  
**Two Approaches:** Incremental (insert-triggered) and Refreshable (scheduled)  
**Key Trade-off:** Storage + compute overhead for dramatically faster analytics queries

---

## Problem Statement

### The Analytics Performance Challenge

**Without Materialized Views:**
- Same expensive aggregations run repeatedly on every query
- Billions of log entries or millions of events scanned each time
- Query latency increases linearly with data volume
- Dashboard refreshes consume excessive resources

**Example: Scanning 10M rows repeatedly**
```sql
SELECT
    toStartOfHour(Timestamp) AS Hour,
    sum(toUInt64OrDefault(LogAttributes['size'])) AS TotalBytes
FROM otel_logs
GROUP BY Hour
ORDER BY Hour DESC
LIMIT 5;
```
*This query rescans millions of rows on every dashboard load.*

**With Materialized Views:**
- Query reads ~100 precomputed hourly rows instead of 10M raw rows
- 100,000x reduction in rows scanned
- Sub-second latency regardless of source table size
- Consistent performance as data grows

---

## Materialized Views Types

### Comparison Matrix

| Feature | Incremental MV | Refreshable MV | Regular View |
|---------|---------------|----------------|--------------|
| **Trigger** | INSERT to source table | Scheduled (EVERY X) | None (query-time) |
| **Storage** | Physical table | Physical table | Query definition only |
| **Freshness** | Real-time (on insert) | Periodic (stale) | Real-time |
| **Use Case** | Streaming aggregations | Complex joins/batch | Query abstraction |
| **Multi-table** | Single source | Multi-table joins | Any |
| **Performance** | Fast reads | Fast reads | No improvement |
| **Backfill** | Manual (re-insert) | Automatic (refresh) | N/A |

---

## Incremental Materialized Views

### Architecture

**Concept:** INSERT-time trigger that runs SELECT on new data blocks

```
Source Table INSERT
        ↓
    MV SELECT runs on new block
        ↓
    Result INSERT into target table
        ↓
    Background merge (if SummingMergeTree/AggregatingMergeTree)
```

**Key Characteristics:**
- Not a static snapshot—continuously updates
- Processes only new data (incremental)
- Happens synchronously during INSERT
- No manual intervention required

### Implementation Pattern 1: Simple Aggregation

#### Scenario: Hourly Byte Tracking

**Step 1: Create target table**
```sql
CREATE TABLE bytes_per_hour
(
    Hour DateTime,
    TotalBytes UInt64
)
ENGINE = SummingMergeTree
ORDER BY Hour;
```

**Step 2: Create materialized view**
```sql
CREATE MATERIALIZED VIEW bytes_per_hour_mv
TO bytes_per_hour AS
SELECT
    toStartOfHour(Timestamp) AS Hour,
    sum(toUInt64OrDefault(LogAttributes['size'])) AS TotalBytes
FROM otel_logs
GROUP BY Hour;
```

**Step 3: Query precomputed table**
```sql
SELECT *
FROM bytes_per_hour
FINAL
ORDER BY Hour DESC
LIMIT 5;
```

**Performance Impact:**
- **Before:** Scan 10M+ rows per query
- **After:** Scan ~100-200 hourly rows per query
- **Latency:** Milliseconds vs. seconds

### Implementation Pattern 2: Complex Aggregations with Partial States

#### Scenario: Percentile and Average Statistics

**Target table with aggregate functions:**
```sql
CREATE TABLE post_stats_per_day
(
    Day Date,
    Score_quantiles AggregateFunction(quantile(0.999), Int32),
    AvgCommentCount AggregateFunction(avg, UInt8)
)
ENGINE = AggregatingMergeTree
ORDER BY Day;
```

**Materialized view storing partial states:**
```sql
CREATE MATERIALIZED VIEW post_stats_mv
TO post_stats_per_day AS
SELECT
    toStartOfDay(CreationDate) AS Day,
    quantileState(0.999)(Score) AS Score_quantiles,
    avgState(CommentCount) AS AvgCommentCount
FROM posts_null
GROUP BY Day;
```

**Querying merged states:**
```sql
SELECT
    Day,
    quantileMerge(0.999)(Score_quantiles) AS P999_Score,
    avgMerge(AvgCommentCount) AS AvgComments
FROM post_stats_per_day
GROUP BY Day
ORDER BY Day DESC;
```

**State Functions Pattern:**
- **`*State()`** - Stores partial aggregation state
- **`*Merge()`** - Combines partial states into final result
- **Mergeable Types:** `sum`, `avg`, `quantile`, `uniq`, `groupArray`, etc.

### Table Engines for Incremental MVs

#### 1. SummingMergeTree
**Use Case:** Simple additive metrics (counters, sums)

```sql
CREATE TABLE metrics_summary
(
    metric_hour DateTime,
    metric_name String,
    metric_value UInt64
)
ENGINE = SummingMergeTree
ORDER BY (metric_hour, metric_name);
```

**Behavior:**
- Automatically sums numeric columns with same ORDER BY key
- Background merges combine rows
- Query with `FINAL` for fully merged results

#### 2. AggregatingMergeTree
**Use Case:** Complex aggregations (quantiles, averages, distinct counts)

```sql
CREATE TABLE complex_stats
(
    event_date Date,
    user_count AggregateFunction(uniq, UInt64),
    latency_p99 AggregateFunction(quantile(0.99), Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY event_date;
```

**Behavior:**
- Merges partial aggregation states using `*Merge()` functions
- Requires `AggregateFunction()` column types
- Use `*State()` in MV, `*Merge()` in queries

#### 3. ReplacingMergeTree
**Use Case:** Deduplication, latest-value-wins

```sql
CREATE TABLE latest_user_state
(
    user_id UInt64,
    last_seen DateTime,
    status String
)
ENGINE = ReplacingMergeTree(last_seen)
ORDER BY user_id;
```

**Behavior:**
- Keeps only one row per ORDER BY key
- Version column determines which row to keep
- Use `FINAL` for deduplicated results

---

## Refreshable Materialized Views

### Architecture

**Concept:** Scheduled full query re-execution

```
Schedule Trigger (EVERY X MINUTE/HOUR)
        ↓
    Full SELECT query executes
        ↓
    Result written to target table (REPLACE or APPEND)
        ↓
    Queries read precomputed table
```

### Basic Syntax

**Create with schedule:**
```sql
CREATE MATERIALIZED VIEW my_report_mv
REFRESH EVERY 5 MINUTE
TO my_report_table AS
SELECT
    date,
    product_id,
    sum(revenue) AS total_revenue
FROM sales
JOIN products USING (product_id)
GROUP BY date, product_id;
```

**Manual refresh:**
```sql
SYSTEM REFRESH VIEW my_report_mv;
```

**Monitor refresh status:**
```sql
SELECT
    view_name,
    last_success_time,
    last_refresh_time,
    status,
    exception
FROM system.view_refreshes
WHERE view_name = 'my_report_mv';
```

### Implementation Pattern: Denormalization with Joins

```sql
CREATE MATERIALIZED VIEW posts_with_links_mv
REFRESH EVERY 1 HOUR
TO posts_with_links AS
SELECT
    posts.*,
    arrayMap(p -> (p.1, p.2), 
        arrayFilter(p -> p.3 = 'Linked' AND p.2 != 0, Related)
    ) AS LinkedPosts,
    arrayMap(p -> (p.1, p.2), 
        arrayFilter(p -> p.3 = 'Duplicate' AND p.2 != 0, Related)
    ) AS DuplicatePosts
FROM posts
LEFT JOIN (
    SELECT
        PostId,
        groupArray((CreationDate, RelatedPostId, LinkTypeId)) AS Related
    FROM postlinks
    GROUP BY PostId
) AS postlinks ON posts.Id = postlinks.PostId;
```

### APPEND vs REPLACE Modes

#### REPLACE Mode (Default)
```sql
CREATE MATERIALIZED VIEW daily_snapshot_mv
REFRESH EVERY 1 DAY
TO daily_snapshot AS
SELECT
    today() AS snapshot_date,
    status,
    count(*) AS cnt
FROM users
GROUP BY status;
```

**Behavior:** Each refresh **overwrites** target table completely

**Use Cases:**
- Cached query results
- Current state reports
- Latest dashboard data

#### APPEND Mode
```sql
CREATE MATERIALIZED VIEW daily_snapshot_mv
REFRESH EVERY 1 DAY
APPEND
TO daily_snapshot AS
SELECT
    today() AS snapshot_date,
    status,
    count(*) AS cnt
FROM users
GROUP BY status;
```

**Behavior:** Each refresh **adds** new rows

**Use Cases:**
- Time-series snapshots
- Audit trails
- Trend analysis

---

## Decision Framework

### Choosing the Right Approach

| Criteria | Incremental MV | Refreshable MV |
|----------|----------------|----------------|
| **Freshness needed** | Real-time | Can tolerate staleness |
| **Source tables** | Single table | Multiple tables with joins |
| **Update pattern** | Streaming/continuous | Batch/periodic |
| **Aggregation complexity** | Simple to moderate | Any complexity |
| **Backfill handling** | Manual re-insert | Automatic on refresh |

### Use Case Matrix

| Use Case | Recommended MV Type | Engine | Refresh |
|----------|-------------------|--------|---------|
| Real-time metrics dashboard | Incremental | SummingMergeTree | On INSERT |
| Streaming log aggregations | Incremental | SummingMergeTree | On INSERT |
| P99 latency tracking | Incremental | AggregatingMergeTree | On INSERT |
| Unique user counts | Incremental | AggregatingMergeTree | On INSERT |
| Multi-table denormalization | Refreshable | MergeTree | EVERY 1 HOUR |
| Nightly batch reports | Refreshable APPEND | MergeTree | EVERY 1 DAY |
| Top-N leaderboards | Refreshable REPLACE | MergeTree | EVERY 5 MINUTE |

---

## Design Best Practices

### 1. Align GROUP BY with ORDER BY

**Correct:**
```sql
ENGINE = SummingMergeTree
ORDER BY (metric_hour, metric_name);

-- MV GROUP BY matches ORDER BY
GROUP BY metric_hour, metric_name;
```

**Incorrect:**
```sql
ENGINE = SummingMergeTree
ORDER BY (metric_hour, metric_name);

-- MV GROUP BY doesn't match - won't merge properly
GROUP BY metric_hour;
```

### 2. Monitor Resource Usage

**Track incremental MV impact:**
```sql
SELECT
    query,
    type,
    event_time,
    query_duration_ms,
    read_rows,
    written_rows
FROM system.query_log
WHERE query LIKE '%INSERT INTO%'
  AND type = 'QueryFinish'
  AND event_time >= now() - INTERVAL 1 HOUR
ORDER BY query_duration_ms DESC
LIMIT 10;
```

**Track refreshable MV execution:**
```sql
SELECT
    view_name,
    status,
    last_refresh_time,
    next_refresh_time,
    read_rows,
    total_milliseconds / 1000 AS duration_seconds
FROM system.view_refreshes
ORDER BY last_refresh_time DESC;
```

### 3. Handle Backfills

**Incremental MVs require manual backfill:**
```sql
-- MV only processes NEW inserts
-- Backfill existing data:
INSERT INTO target_table
SELECT <same query as MV>
FROM source_table;
```

**Refreshable MVs backfill automatically:**
```sql
-- First refresh computes full historical data
SYSTEM REFRESH VIEW my_mv;
```

### 4. Choose Appropriate Engines

| Aggregation Type | Column Type | Engine | Query Function |
|-----------------|-------------|--------|----------------|
| Sum, Count | `UInt64` | SummingMergeTree | `sum()` |
| Average | `AggregateFunction(avg, Float64)` | AggregatingMergeTree | `avgMerge()` |
| Quantiles | `AggregateFunction(quantile(0.99), Float64)` | AggregatingMergeTree | `quantileMerge(0.99)()` |
| Unique Count | `AggregateFunction(uniq, UInt64)` | AggregatingMergeTree | `uniqMerge()` |

### 5. Start Simple

**Phase 1: Basic aggregation**
```sql
SELECT date, count(*) AS cnt
FROM source
GROUP BY date;
```

**Phase 2: Add dimensions**
```sql
SELECT date, category, region, count(*) AS cnt
FROM source
GROUP BY date, category, region;
```

**Phase 3: Complex aggregations**
```sql
SELECT
    date,
    category,
    sum(revenue) AS total_revenue,
    quantileState(0.99)(response_time) AS p99_response
FROM source
GROUP BY date, category;
```

---

## Production Implementation Patterns

### Pattern 1: Lambda Architecture (Hot + Cold Path)

**Hot Path:** Real-time metrics (Incremental MV)
```sql
CREATE TABLE metrics_hot (...)
ENGINE = SummingMergeTree
ORDER BY (metric_hour, metric_name);

CREATE MATERIALIZED VIEW metrics_hot_mv TO metrics_hot AS
SELECT toStartOfHour(ts) AS metric_hour, name, sum(value)
FROM events
GROUP BY metric_hour, name;
```

**Cold Path:** Historical with joins (Refreshable MV)
```sql
CREATE MATERIALIZED VIEW metrics_cold_mv
REFRESH EVERY 1 DAY
TO metrics_cold AS
SELECT toDate(e.ts) AS day, e.name, sum(e.value), m.description
FROM events e
JOIN metadata m ON e.name = m.name
GROUP BY day, e.name, m.description;
```

### Pattern 2: Multi-Stage Aggregation Pipeline

**Stage 1: Raw → Hourly**
```sql
CREATE MATERIALIZED VIEW stage1_hourly_mv TO stage1_hourly AS
SELECT toStartOfHour(ts) AS hour, dim1, sum(val) AS hourly_sum
FROM raw_events
GROUP BY hour, dim1;
```

**Stage 2: Hourly → Daily**
```sql
CREATE MATERIALIZED VIEW stage2_daily_mv
REFRESH EVERY 1 HOUR
TO stage2_daily AS
SELECT toDate(hour) AS day, dim1, sum(hourly_sum) AS daily_sum
FROM stage1_hourly
GROUP BY day, dim1;
```

### Pattern 3: Deduplication + Aggregation

**Step 1: Deduplicate**
```sql
CREATE TABLE events_dedup (...)
ENGINE = ReplacingMergeTree(timestamp)
ORDER BY event_id;

CREATE MATERIALIZED VIEW events_dedup_mv TO events_dedup AS
SELECT * FROM raw_events;
```

**Step 2: Aggregate**
```sql
CREATE MATERIALIZED VIEW hourly_metrics_mv TO hourly_metrics AS
SELECT toStartOfHour(timestamp) AS hour, sum(value)
FROM events_dedup FINAL
GROUP BY hour;
```

---

## Troubleshooting Guide

### Issue 1: Target Table Empty After MV Creation

**Cause:** MV created after data exists in source

**Solution:**
```sql
-- Backfill from source
INSERT INTO target_table
SELECT <same query as MV>
FROM source_table;
```

### Issue 2: Refreshable MV Stuck Running

**Check:**
```sql
SELECT query_id, query, elapsed, memory_usage
FROM system.processes
WHERE query LIKE '%REFRESH%';

-- Kill if needed
KILL QUERY WHERE query_id = '<query_id>';
```

### Issue 3: SummingMergeTree Not Summing

**Cause:** Background merges pending

**Solution:**
```sql
-- Force merge
OPTIMIZE TABLE summing_table FINAL;

-- Or use FINAL in queries
SELECT * FROM summing_table FINAL;
```

### Issue 4: High Memory During INSERT

**Causes:**
- Too many MVs on one table
- Complex aggregations
- Large batches

**Solutions:**
- Reduce insert batch size
- Simplify MV logic
- Break into multiple stages

### Issue 5: Stale Refreshable MV Data

**Check status:**
```sql
SELECT * FROM system.view_refreshes 
WHERE view_name = 'my_mv';

-- Manual refresh
SYSTEM REFRESH VIEW my_mv;
```

---

## Performance Benchmarks

### Incremental MV Example

**Scenario:** 1 billion log entries, hourly aggregations

| Metric | Without MV | With MV | Improvement |
|--------|-----------|---------|-------------|
| Query latency | 12.5s | 0.015s | 833x faster |
| Rows scanned | 1,000,000,000 | 8,760 | 114,155x fewer |
| Memory used | 45 GB | 12 MB | 3,750x less |

### Refreshable MV Example

**Scenario:** Multi-table join, 100M rows

| Metric | Query-Time Join | Refreshable MV | Improvement |
|--------|----------------|----------------|-------------|
| Query latency | 45s | 0.8s | 56x faster |
| CPU during query | 16 cores | <1 core | 16x less |
| Data freshness | Real-time | 5 min stale | Trade-off |

---

## Key Monitoring Metrics

### Incremental MV Health
- Target table freshness (compare max timestamps)
- Insert latency impact
- Target table size growth
- Merge lag

### Refreshable MV Health
- Refresh success rate
- Refresh duration
- Time since last successful refresh
- Exception count

### Sample Dashboard Queries

**MV Lag Monitoring:**
```sql
SELECT
    'source' AS tbl,
    max(timestamp) AS max_ts
FROM source_table
UNION ALL
SELECT
    'target' AS tbl,
    max(hour) AS max_ts
FROM target_table;
```

**Refresh Status:**
```sql
SELECT
    view_name,
    status,
    last_success_time,
    exception
FROM system.view_refreshes
WHERE status != 'Finished'
ORDER BY last_refresh_time DESC;
```

**Target Table Growth:**
```sql
SELECT
    table,
    formatReadableSize(sum(bytes)) AS size,
    sum(rows) AS total_rows
FROM system.parts
WHERE active = 1
  AND database = 'analytics'
GROUP BY table
ORDER BY sum(bytes) DESC;
```

---

## Migration Checklist

- [ ] Identify expensive queries (>1s execution)
- [ ] Choose MV type (incremental vs refreshable)
- [ ] Select target engine (Summing, Aggregating, etc.)
- [ ] Design target schema (align GROUP BY with ORDER BY)
- [ ] Create target table
- [ ] Create materialized view
- [ ] Backfill historical data (if needed)
- [ ] Test queries against target table
- [ ] Monitor resource usage
- [ ] Update application to use target table
- [ ] Set up monitoring dashboards
- [ ] Configure alerts
- [ ] Document MV logic

---

## Key Takeaways

1. **Precompute aggressively:** Move work from query time to insert/batch time
2. **Choose the right MV type:** Incremental for real-time, Refreshable for complex joins
3. **Match engine to use case:** SummingMergeTree for simple sums, AggregatingMergeTree for complex aggregations
4. **Align GROUP BY with ORDER BY:** Critical for efficient merges
5. **Start simple, iterate:** Begin with basic aggregations, add complexity gradually
6. **Monitor actively:** Track refresh status, lag, and resource usage
7. **Production patterns:** Consider Lambda architecture, multi-stage pipelines, and deduplication patterns

---

## References

- **Source Article:** [Medium - How ClickHouse Materialized Views Supercharge Analytics](https://medium.com/@siddiqueahmad/how-clickhouse-materialized-views-supercharge-analytics-00c632fc6c5c)
- **ClickHouse Docs:** [Materialized Views](https://clickhouse.com/docs/en/guides/developer/cascading-materialized-views)
- **System Tables:** `system.view_refreshes`, `system.query_log`, `system.parts`


---
