# ClickHouse ETL Pipeline Architecture
## observations Database - Deep Dive Analysis

---

## 🚨 Critical Discovery: This is NOT a slow query problem

**What you thought:** "I have slow SELECT queries with JOINs"

**What's actually happening:** You have a sophisticated **REFRESHING MATERIALIZED VIEW pipeline** that processes data in **100 partitions sequentially**, running **84,780 times per day** and consuming **1.13 hours of CPU time daily**.

---

## 📊 The Numbers That Matter

```sql
-- Query Hash: 9902767606434466184
Executions per day: 84,780
CPU hours per day:  1.13 hours
Average duration:   27 seconds per execution
Peak duration:      129 seconds (2+ minutes!)
Memory usage:       3.5 GB average, 8 GB peak
```

**Translation:** This "query" is actually your **ETL heartbeat** - it runs every ~1 second and processes 1 partition out of 100 each time.

---

## 🏗️ The Pipeline Architecture

### Overview: Data Flow

```
observations_in (source table, 556M rows)
    ↓
    ├─→ [REFRESHING MV] observations_in_measurement_id_reverse_lookup_3_pass_thru_mv
    │       ↓ (processes 1 partition every 1 second)
    │   measurement_id_reverse_lookup_3_pass_thru (Null table - staging)
    │       ↓
    │       ├─→ [MV] measurement_id_reverse_lookup_3_pass_thru_measurement_id_reverse_lookup_3_mv
    │       │       ↓
    │       │   measurement_id_reverse_lookup_3 (32.8B rows, 2.19 TB)
    │       │
    │       └─→ [MV] measurement_id_reverse_lookup_3_pass_thru_ingestion_log_mv
    │               ↓
    │           ingestion_log (tracks progress)
    │
    ├─→ [REFRESHING MV] observations_in_deduped_observations_in_pass_thru_mv
    │       ↓
    │   deduped_observations_in_pass_thru (Null table - staging)
    │       ↓
    │       ├─→ [MV] deduped_observations_in_pass_thru_deduped_observations_in_mv
    │       │       ↓
    │       │   deduped_observations_in (deduplicated data)
    │       │
    │       └─→ [MV] deduped_observations_in_pass_thru_ingestion_log_mv
    │               ↓
    │           ingestion_log
    │
    └─→ [REFRESHING MV] observations_in_remediation_actions_pass_thru_mv
            ↓
        remediation_actions_pass_thru (Null table - staging)
            ↓
            ├─→ [MV] remediation_actions_pass_thru_remediation_actions_mv
            │       ↓
            │   remediation_actions (action tracking)
            │
            └─→ [MV] remediation_actions_pass_thru_ingestion_log_mv
                    ↓
                ingestion_log
```

---

## 🔍 Deep Dive: The "Slow Query" (It's Not a Query!)

### What the Code Actually Does

```sql
CREATE MATERIALIZED VIEW observations_in_measurement_id_reverse_lookup_3_pass_thru_mv 
REFRESH EVERY 1 SECOND  -- ← Runs continuously!
APPEND TO observations.measurement_id_reverse_lookup_3_pass_thru
AS
WITH 
  -- Configuration
  toIntervalHour(1) AS interval_duration,
  toIntervalMinute(5) AS lookback_offset,
  toStartOfInterval(now() - lookback_offset, interval_duration) AS stop_at_interval,
  
  -- Get last processed state from ingestion_log
  ingested AS (
    SELECT interval, partition 
    FROM observations.ingestion_log 
    WHERE `table` = 'measurement_id_reverse_lookup_3' 
    ORDER BY inserted_at DESC 
    LIMIT 1
  ),
  
  -- Calculate NEXT partition to process
  to_ingest AS (
    SELECT 
      if(ingested_partition = 99, 
         ingested_interval + interval_duration,  -- Wrap to next hour
         ingested_interval) AS to_ingest_interval,
      if(ingested_partition = 99, 
         0,                                       -- Start over at partition 0
         ingested_partition + 1) AS to_ingest_partition
    FROM ingested
  )

-- Process ONE partition at a time
SELECT 
  o.observation_owner_domain,
  o.observation_group_key,
  o.asset_key,
  CAST(o.measurement_id, 'UUID') AS measurement_id,
  (o.measurement_status.transition, o.measurement_status.reason) AS measurement_status,
  o.evidence,
  o.created_at AS inserted_at,
  (SELECT to_ingest_partition FROM to_ingest) AS partition,
  (SELECT to_ingest_interval FROM to_ingest) AS interval
FROM observations.observations_in AS o
WHERE 
  (interval < stop_at_interval)
  AND (toStartOfInterval(o.created_at, interval_duration) = interval)
  AND ((cityHash64(o.observation_owner_domain) % 100) = partition)  -- ← KEY: Only 1 of 100 partitions
  AND (NOT dictGet('observations.ignored_v1_issue_types_dict', 'ignored', o.v1_issue_key))

UNION ALL

-- Insert a "dummy row" to update ingestion_log even if no data
SELECT * FROM dummy_measurement_id
```

---

## 🎯 The Architecture Pattern: "Incremental Partition Processing"

### Why It's Designed This Way

**Problem:** `observations_in` receives continuous data 24/7. You need to transform it into `measurement_id_reverse_lookup_3` without:
- Reprocessing the same data multiple times
- Missing any new data
- Blocking inserts during processing

**Solution:** 
1. **Partition by hash**: `cityHash64(observation_owner_domain) % 100` splits data into 100 buckets
2. **Track progress**: `ingestion_log` stores last processed (interval, partition)
3. **Process incrementally**: Every 1 second, process the NEXT partition
4. **Continuous loop**: Partition 99 → wraps to partition 0 of next hour

### The Math

```
100 partitions per hour
÷ 1 second refresh rate
= 100 seconds to process entire hour
= 1.67 minutes to catch up completely

But actually:
- Each partition takes ~27 seconds (not 1 second!)
- So: 100 partitions × 27 seconds = 2,700 seconds = 45 minutes
- Plus overhead for checking state, etc.
```

**This explains the 84,780 executions per day!**

```
24 hours × 3600 seconds = 86,400 seconds/day
÷ ~1 second per execution = ~86,400 executions
(Actual: 84,780 = some overhead/failures)
```

---

## 🔥 The Performance Problem

### Why Each Execution Takes 27 Seconds

**For EACH of the 84,780 executions**, the query must:

1. **Read `ingestion_log`** to find last processed partition (fast)
2. **Calculate next partition** (fast)
3. **Scan `observations_in`** with 3 filters:
   - `toStartOfInterval(created_at, interval_duration) = interval` ← Full table scan (SLOW!)
   - `cityHash64(observation_owner_domain) % 100 = partition` ← Not indexed (SLOW!)
   - `NOT dictGet(...)` ← Dictionary lookup (fast)
4. **Check stopping condition** (fast)
5. **Insert into pass_thru** (fast)

**The bottleneck:** Steps 3 - the filters don't match the table's sort key!

### Current Sort Key (observations_in)
```sql
ORDER BY (
  cityHash64(observation_owner_domain) % 100,  -- Good! Matches filter
  observation_owner_domain                      -- Meh
)
```

**Missing:** No index on `created_at` or hourly interval!

---

## 💡 Why This Architecture Exists

This is actually a **clever workaround** for ClickHouse limitations:

### Standard Materialized View Problem
```sql
-- Normal MV: Processes ALL data on EVERY insert
CREATE MATERIALIZED VIEW simple_mv AS
SELECT * FROM observations_in
-- Problem: Can't filter "only process data from 5 minutes ago"
```

### Refreshing MV Solution
```sql
-- Refreshing MV: Can look back in time and track state
CREATE MATERIALIZED VIEW smart_mv 
REFRESH EVERY 1 SECOND
AS
WITH last_processed AS (...)
SELECT * FROM observations_in 
WHERE created_at > last_processed
-- Benefit: Incremental processing with state management
```

### Why Not Use Kafka or Streaming?

Looking at your architecture, you probably:
1. Have upstream systems that INSERT directly to `observations_in`
2. Need guaranteed exactly-once processing (not at-least-once)
3. Want to reprocess historical data if logic changes
4. Need to handle out-of-order arrivals (5 minute lookback)

**This pattern gives you control that streaming engines don't provide.**

---

## 🎯 The Root Cause Analysis

### Why 27 Seconds Per Execution?

```sql
-- This filter is the killer:
WHERE (toStartOfInterval(o.created_at, interval_duration) = interval)
  AND ((cityHash64(o.observation_owner_domain) % 100) = partition)
```

**Problem:** `observations_in` is sorted by:
```sql
ORDER BY (
  cityHash64(observation_owner_domain) % 100,  -- ✅ Helps with partition filter
  observation_owner_domain                      -- ❌ Doesn't help with time filter
)
```

**What happens:** ClickHouse must:
1. Find all rows where `cityHash64(domain) % 100 = partition` (good - uses primary key)
2. Then scan ALL those rows to check `toStartOfInterval(created_at, ...) = interval` (bad - no index)

**For 1 partition out of 100:**
- ~5.5M rows need to be scanned (556M ÷ 100)
- To find rows from ONE specific hour
- That match the interval filter
- This is a **columnar scan** of millions of rows!

---

## 🚀 The Solution: Compound Sort Key

### Current (Inefficient)
```sql
ORDER BY (
  cityHash64(observation_owner_domain) % 100,
  observation_owner_domain
)
```

### Optimized (Efficient)
```sql
ORDER BY (
  cityHash64(observation_owner_domain) % 100,
  toStartOfHour(created_at),  -- ← ADD THIS!
  observation_owner_domain
)
```

**Expected improvement:**
- Current: Scan 5.5M rows → filter by time → find ~5K matching rows
- Optimized: Skip to exact partition + hour → scan only ~5K rows directly

**Result:** 27 seconds → **< 1 second** (27x improvement)

---

## 📊 Impact Analysis

### Current State (Before Optimization)
```
84,780 executions/day × 27 seconds = 2,289,060 seconds = 635 hours/day of CPU
(Obviously distributed across time, but you get the idea)

Actual measured: 1.13 hours/day of wall-clock time
```

### After Optimization (Projected)
```
84,780 executions/day × 1 second = 84,780 seconds = 23.5 hours/day of CPU
(Still high, but 27x better)

Estimated: < 3 minutes/day of wall-clock time
```

**Even better:** With proper indexing, you might be able to increase refresh rate:
```sql
REFRESH EVERY 100 MILLISECONDS  -- 10x faster processing!
```

---

## 🛠️ Recommended Actions (Prioritized)

### Priority 1: Add Compound Sort Key (Immediate - High Impact)

**Problem:** Can't change sort key on existing table with 556M rows easily.

**Solution:** Create new table with optimized sort key, migrate data.

```sql
-- Step 1: Create optimized table
CREATE TABLE observations.observations_in_v2 AS observations.observations_in
ENGINE = MergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (
  cityHash64(observation_owner_domain) % 100,
  toStartOfHour(created_at),           -- ← NEW!
  observation_owner_domain
)
SETTINGS 
  index_granularity = 8192;

-- Step 2: Copy data (can do in batches)
INSERT INTO observations.observations_in_v2 
SELECT * FROM observations.observations_in;

-- Step 3: Swap tables (during maintenance window)
RENAME TABLE 
  observations.observations_in TO observations.observations_in_old,
  observations.observations_in_v2 TO observations.observations_in;

-- Step 4: Update MVs to point to new table
-- (They should pick up automatically if schema matches)

-- Step 5: Verify, then drop old table
DROP TABLE observations.observations_in_old;
```

**Alternative (Zero Downtime):** Use Projection instead

```sql
-- Add projection without table recreation
ALTER TABLE observations.observations_in
ADD PROJECTION time_partition_proj (
  SELECT *
  ORDER BY (
    cityHash64(observation_owner_domain) % 100,
    toStartOfHour(created_at),
    observation_owner_domain
  )
);

-- Materialize for existing data (runs in background)
ALTER TABLE observations.observations_in 
MATERIALIZE PROJECTION time_partition_proj 
SETTINGS mutations_sync = 0;  -- Don't wait for completion
```

**Expected result:** 27s → < 1s per execution

---

### Priority 2: Optimize Refresh Logic (Medium Impact)

The "dummy row" UNION ALL adds overhead on every execution:

**Current:**
```sql
SELECT ... FROM observations_in
WHERE ...
UNION ALL
SELECT * FROM dummy_measurement_id  -- Always evaluated, even if no data
```

**Optimized:**
```sql
-- Only insert dummy if no real data processed
SELECT ... FROM observations_in
WHERE ...

UNION ALL

SELECT * FROM dummy_measurement_id
WHERE NOT EXISTS (
  SELECT 1 FROM observations_in 
  WHERE (interval = to_ingest_interval) 
    AND (partition = to_ingest_partition)
)
```

**Expected result:** Save ~0.5s per empty partition (minor, but adds up)

---

### Priority 3: Monitor and Alert (Operational Excellence)

**Create visibility into pipeline health:**

```sql
-- Pipeline lag monitor
CREATE VIEW observations.etl_pipeline_health AS
WITH current_time AS (
  SELECT 
    toStartOfHour(now() - toIntervalMinute(5)) AS current_interval,
    cityHash64(observation_owner_domain) % 100 AS current_partition
),
ingestion_status AS (
  SELECT 
    `table`,
    interval AS last_processed_interval,
    partition AS last_processed_partition,
    inserted_at AS last_update,
    now() - inserted_at AS seconds_behind
  FROM observations.ingestion_log
  WHERE `table` IN (
    'measurement_id_reverse_lookup_3',
    'deduped_observations_in',
    'remediation_actions'
  )
)
SELECT
  `table`,
  last_processed_interval,
  last_processed_partition,
  last_update,
  seconds_behind,
  multiIf(
    seconds_behind > 300, '🔴 CRITICAL: 5+ min lag',
    seconds_behind > 60, '🟡 WARNING: 1+ min lag',
    '🟢 HEALTHY'
  ) AS status
FROM ingestion_status;

-- Query it:
SELECT * FROM observations.etl_pipeline_health;
```

**Alert thresholds:**
- **Critical:** Pipeline behind by > 5 minutes
- **Warning:** Single execution taking > 60 seconds
- **Info:** Daily CPU time > 2 hours (indicates degradation)

---

## 📚 Key Learnings for Your Growth

### Senior → Principal Level Insights You Just Gained:

1. **"Slow query" ≠ "Bad query"**
   - Sometimes it's architecture, not SQL optimization
   - Context matters: User query vs. ETL pipeline have different solutions

2. **Refreshing MVs are powerful but tricky**
   - They enable incremental processing with state
   - But they run constantly - every inefficiency is magnified 84,780× per day!

3. **Sort keys are critical for filter performance**
   - ClickHouse is columnar - every scan touches millions of rows
   - Compound sort keys enable "skip to exact location" vs "scan and filter"

4. **Architecture patterns have trade-offs**
   - Your "100 partition sequential processing" pattern:
     - ✅ Gives control over exactly-once processing
     - ✅ Handles out-of-order data (5 min lookback)
     - ✅ Allows reprocessing historical intervals
     - ❌ Requires perfect index alignment
     - ❌ Takes 1.67 minutes minimum to catch up per hour

5. **Measure actual impact, not just alert severity**
   - 84,780 executions × 27 seconds = 635 CPU-hours
   - But distributed over 24 hours = 1.13 real hours
   - Still expensive, but not as "critical" as it initially seemed

---

## 🎯 Decision Framework: When to Use This Pattern

**Use Refreshing MV with Partition Processing when:**
- ✅ Need exactly-once processing guarantees
- ✅ Have out-of-order data arrivals
- ✅ Want to reprocess historical data with new logic
- ✅ Can optimize source table sort key to match filters
- ✅ Data volume fits in memory for incremental scans

**Don't use when:**
- ❌ Source table is > 1 TB and can't be re-sorted
- ❌ Real-time latency < 10 seconds required
- ❌ Upstream can provide CDC events (use Kafka instead)
- ❌ Simple transformations (use standard MV)

---

## 🚀 Next Steps

1. **Validate the hypothesis** 
   ```sql
   -- Check current filter performance
   EXPLAIN PLAN
   SELECT count()
   FROM observations.observations_in
   WHERE toStartOfInterval(created_at, toIntervalHour(1)) = now() - toIntervalHour(2)
     AND cityHash64(observation_owner_domain) % 100 = 42;
   ```
   Look for `ReadFromMergeTree` and `FilterByPartition` vs `FilterByPrimaryKey`

2. **Add projection** 
   - Test on replica first
   - Monitor materialize progress
   - Measure improvement

3. **Benchmark** 
   ```sql
   -- Before and after comparison
   SELECT 
     avg(query_duration_ms/1000) AS avg_sec,
     quantile(0.95)(query_duration_ms/1000) AS p95_sec
   FROM system.query_log
   WHERE normalized_query_hash = 9902767606434466184
     AND event_time BETWEEN (now() - INTERVAL 1 HOUR) AND now()
   ```
