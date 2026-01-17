# ClickHouse S3Queue: Fundamental Guide

---

## Table of Contents

1. [What is S3Queue?](#what-is-s3queue)
2. [When to Use S3Queue (and When NOT To)](#when-to-use-s3queue)
3. [S3Queue Settings Explained](#s3queue-settings-explained)
4. [Architecture Comparison](#architecture-comparison)
5. [Best Practices](#best-practices)
6. [Common Pitfalls](#common-pitfalls)
7. [Migration Patterns](#migration-patterns)
8. [Appendix: Complete Configuration Reference](#appendix-complete-configuration-reference)

---

## What is S3Queue?

### Overview

**S3Queue** is a ClickHouse table engine that automatically monitors an S3 bucket/path for new files and ingests them into ClickHouse.

### How It Works

```
┌─────────────┐
│   S3 Bucket │
│             │
│ ├─ file1.parquet  ──┐
│ ├─ file2.parquet  ──┤
│ ├─ file3.parquet  ──┤
│ └─ file4.parquet  ──┤
└─────────────┘       │
                      │ S3Queue monitors
                      │ and auto-ingests
                      ↓
            ┌──────────────────┐
            │   ClickHouse     │
            │   S3Queue Table  │
            └──────────────────┘
                      │
                      │ Tracks processed
                      │ files in ZooKeeper
                      ↓
            ┌──────────────────┐
            │   ZooKeeper      │
            │   /s3queue/      │
            │   ├─ file1 ✓     │
            │   ├─ file2 ✓     │
            │   └─ file3 ✓     │
            └──────────────────┘
```

### Key Components

1. **File Monitoring:** Continuously polls S3 paths for new files
2. **Automatic Ingestion:** Reads and inserts data automatically
3. **Deduplication:** Tracks processed files to prevent reprocessing
4. **ZooKeeper Storage:** Stores file tracking metadata

### Official Purpose

> "S3Queue enables continuous ingestion of data arriving in S3 with automatic deduplication."
> 
> — ClickHouse Documentation

**Use Case:** Event-driven, streaming, or unpredictable file arrivals in S3.

---

## When to Use S3Queue (and When NOT To)

### ✅ Use S3Queue When:

#### Scenario 1: True Streaming from S3

**Pattern:**
- Files arrive unpredictably throughout the day
- Need near-real-time ingestion (within minutes)
- Cannot predict when next file will arrive
- Small to medium file count (<100k total files)

**Example:**
```
IoT sensor data uploaded as events occur:
s3://iot-data/sensors/device_123/2024-01-16-14-23-45.json
s3://iot-data/sensors/device_456/2024-01-16-14-24-12.json
s3://iot-data/sensors/device_789/2024-01-16-14-25-03.json
(arrivals are random, need immediate processing)
```

**Why S3Queue fits:**
- Files arrive continuously, not on schedule
- Need automatic monitoring
- Can't predict file arrival times

---

#### Scenario 2: Event-Driven Architecture

**Pattern:**
- Other systems/services write to S3 when events happen
- You need to react immediately to new data
- File arrival is triggered by external events
- No control over timing

**Example:**
```
ML model outputs uploaded after training completes:
s3://ml-outputs/model_training/run_abc123/results.parquet
s3://ml-outputs/model_training/run_def456/results.parquet
(training completes at unpredictable times)
```

**Why S3Queue fits:**
- Event-driven, not schedule-driven
- Need to process as soon as file appears
- External systems control timing

---

#### Scenario 3: Multi-Source S3 Ingestion

**Pattern:**
- Many different sources/systems write to same S3 location
- Files arrive from various sources at different times
- Need unified ingestion mechanism
- Cannot coordinate schedules across sources

**Example:**
```
Multiple data pipelines writing to shared bucket:
s3://shared/pipeline_a/output_*.parquet
s3://shared/pipeline_b/output_*.parquet
s3://shared/pipeline_c/output_*.parquet
(each pipeline runs independently)
```

**Why S3Queue fits:**
- Handles multiple uncoordinated sources
- Single ingestion point
- No need to track individual pipeline schedules

---

### ❌ Do NOT Use S3Queue When:

#### Scenario 1: Batch/Scheduled Ingestion ⚠️ **MOST COMMON MISTAKE**

**Pattern:**
- Files arrive on predictable schedule (daily, hourly, every 5 minutes)
- Date/time partitioned paths
- You control when files are created
- High file count over time (millions)

**Example (THIS IS YOUR CASE):**
```
Daily batch processing with date partitions:
s3://data-lake/events/effective_date=20240101/*.parquet
s3://data-lake/events/effective_date=20240102/*.parquet
s3://data-lake/events/effective_date=20240103/*.parquet
...
s3://data-lake/events/effective_date=20260116/*.parquet

Pattern: New partition created daily at 2 AM
```

**Why S3Queue is WRONG:**
- Files arrive on schedule (daily 2 AM) → Use scheduled INSERT instead
- Date-partitioned → Each partition is complete, won't change
- S3Queue monitors old partitions forever (wasted resources)
- Tracks millions of files in ZooKeeper (bloat)

**Better Approach:**
```sql
-- Scheduled daily at 3 AM (after files are ready)
INSERT INTO events_table
SELECT * FROM s3('s3://data-lake/events/effective_date={yesterday}/*.parquet', 'Parquet');
```

---

#### Scenario 2: Historical Data / One-Time Loads

**Pattern:**
- Processing existing data already in S3
- One-time migration or backfill
- Data is static, won't change
- Don't need ongoing monitoring

**Example:**
```
Migrating historical data to ClickHouse:
s3://archive/2020/*.parquet
s3://archive/2021/*.parquet
s3://archive/2022/*.parquet
(data is complete, no new files will appear)
```

**Why S3Queue is WRONG:**
- One-time load doesn't need continuous monitoring
- S3Queue will keep monitoring empty paths forever
- Wastes ZooKeeper space tracking old files

**Better Approach:**
```sql
-- One-time INSERT
INSERT INTO historical_table
SELECT * FROM s3('s3://archive/*/*.parquet', 'Parquet');
```

---

#### Scenario 3: Low-Frequency Updates

**Pattern:**
- Files updated weekly, monthly, or less frequently
- Predictable update schedule
- Small number of files
- Can easily schedule ingestion

**Example:**
```
Monthly report files:
s3://reports/monthly/2024-01.parquet
s3://reports/monthly/2024-02.parquet
(new file appears 1st of each month)
```

**Why S3Queue is WRONG:**
- Monitoring 24/7 for monthly updates is overkill
- Simple monthly cron job is more efficient
- Unnecessary ZooKeeper overhead

**Better Approach:**
```bash
# Monthly cron job (1st of month at 9 AM)
0 9 1 * * clickhouse-client --query "INSERT INTO reports SELECT * FROM s3('s3://reports/monthly/{this_month}.parquet', 'Parquet')"
```

---

## S3Queue Settings Explained

### Complete Settings with Detailed Comments

```sql
CREATE TABLE example_s3queue
(
    -- Your column definitions
    event_time DateTime,
    event_type String,
    user_id UInt64,
    data String
)
ENGINE = S3Queue(
    -- S3 path pattern (supports wildcards and date ranges)
    's3://bucket-name/path/to/files/*.parquet',
    
    -- File format (Parquet, CSV, JSONEachRow, etc.)
    'Parquet'
)
SETTINGS
    -- ==================================================================
    -- PROCESSING MODE
    -- ==================================================================
    mode = 'unordered',
    /* Processing mode determines how files are tracked and processed.
     *
     * Options:
     *   - 'ordered': Files processed in lexicographical order by filename.
     *                Maintains strict ordering, slower processing.
     *                Use for: Time-series data where order matters.
     *   
     *   - 'unordered': Files processed in any order, parallel processing.
     *                  Faster, no ordering guarantees.
     *                  Use for: Most cases where file order doesn't matter.
     *
     * Recommendation: Use 'unordered' unless you specifically need ordering.
     * Why: Better performance, parallel processing, more scalable.
     */
    
    -- ==================================================================
    -- FILE RETENTION IN S3
    -- ==================================================================
    after_processing = 'keep',
    /* What happens to S3 file after successful ingestion.
     *
     * Options:
     *   - 'keep': File remains in S3 after processing.
     *             ClickHouse only marks it as processed in ZooKeeper.
     *   
     *   - 'delete': File is deleted from S3 after processing.
     *               Permanent deletion - cannot be recovered.
     *
     * Recommendation: Use 'keep' unless you're certain files should be deleted.
     * Why: 
     *   - Keeps audit trail in S3
     *   - Allows reprocessing if needed
     *   - Safer (can't accidentally lose data)
     *   - S3 is cheap storage
     *
     * WARNING: 'delete' is PERMANENT. Only use if:
     *   - You have the data elsewhere
     *   - Files are truly temporary/ephemeral
     *   - You understand the risk
     */
    
    -- ==================================================================
    -- FILE TRACKING TTL (CRITICAL - THIS CAUSED THE INCIDENT)
    -- ==================================================================
    s3queue_tracked_file_ttl_sec = 604800,  -- 7 DAYS
    /* How long to track processed files in ZooKeeper before cleanup.
     *
     * Value: Time in seconds (0 = infinite)
     *   - 86400 = 1 day
     *   - 604800 = 7 days (RECOMMENDED)
     *   - 2592000 = 30 days
     *   - 0 = INFINITE (NEVER USE THIS)
     *
     * What it does:
     *   - After processing file "abc.parquet", ClickHouse creates a znode
     *     in ZooKeeper: /clickhouse/s3queue/{table}/processed/abc.parquet
     *   - This znode prevents reprocessing the same file
     *   - After TTL expires, the znode is deleted (file can be reprocessed)
     *
     * Why TTL matters:
     *   - TTL = 0 means znodes NEVER expire
     *   - Result: Unlimited ZooKeeper growth
     *   - Our incident: 7.1M znodes, 3.3GB snapshots, system failure
     *
     * How to choose TTL:
     *   1. How long might duplicate files appear in S3?
     *   2. What's your S3 eventual consistency window?
     *   3. How far back might you replay/backfill?
     *
     * Recommendations:
     *   - Streaming/real-time data: 1-3 days (86400-259200)
     *   - Daily batch data: 7 days (604800) 
     *   - Weekly batch data: 14-30 days (1209600-2592000)
     *   - NEVER use 0 (infinite)
     *
     * Example calculation:
     *   If you process 10,000 files/day with 7-day TTL:
     *   - Steady state: 70,000 znodes
     *   - ZK snapshot: ~35 MB
     *   - Manageable and safe
     *
     * CRITICAL: This is the MOST IMPORTANT setting.
     * Setting this to 0 caused a P1 incident with 7.1M znodes.
     */
    
    -- ==================================================================
    -- FILE TRACKING LIMIT
    -- ==================================================================
    s3queue_tracked_files_limit = 100000,  -- 100K FILES
    /* Maximum number of files to track in ZooKeeper simultaneously.
     *
     * Value: Number of files (default: 1000)
     *   - 50000 = 50K files
     *   - 100000 = 100K files (RECOMMENDED for most cases)
     *   - 1000000 = 1M files (only for extreme high-volume)
     *   - 10000000 = 10M files (NEVER USE - too high)
     *
     * What it does:
     *   - Hard cap on number of znodes created per table
     *   - When limit is reached, oldest entries are removed
     *   - Works in conjunction with TTL
     *
     * Relationship with TTL:
     *   - If you process 15,000 files/day with 7-day TTL:
     *     Expected znodes: 15,000 × 7 = 105,000
     *     Set limit to: 150,000 (1.5x headroom)
     *
     * How to calculate:
     *   1. Estimate files processed per day: X
     *   2. Multiply by TTL in days: X × TTL_days
     *   3. Add 50% headroom: (X × TTL_days) × 1.5
     *
     * Examples:
     *   - 1,000 files/day, 7-day TTL: 1000 × 7 × 1.5 = 10,500 → set 20,000
     *   - 10,000 files/day, 7-day TTL: 10000 × 7 × 1.5 = 105,000 → set 150,000
     *   - 100,000 files/day, 3-day TTL: 100000 × 3 × 1.5 = 450,000 → set 500,000
     *
     * Recommendations:
     *   - Start conservative: 100,000 for most workloads
     *   - Monitor actual usage
     *   - Increase if needed based on monitoring
     *
     * WARNING: Setting too high (like 10M) defeats the purpose.
     * Our incident had limit=10M, allowing unbounded growth.
     */
    
    -- ==================================================================
    -- CLEANUP INTERVALS
    -- ==================================================================
    s3queue_cleanup_interval_min_ms = 300000,  -- 5 MINUTES
    s3queue_cleanup_interval_max_ms = 400000,  -- 6.67 MINUTES
    /* How often ClickHouse runs cleanup to remove expired znodes.
     *
     * Values: Time in milliseconds
     *   - 60000 = 1 minute
     *   - 300000 = 5 minutes (RECOMMENDED minimum)
     *   - 600000 = 10 minutes
     *   - 3600000 = 1 hour (too infrequent)
     *
     * How cleanup works:
     *   1. Every 5-7 minutes (randomized between min/max)
     *   2. ClickHouse scans all znodes in /clickhouse/s3queue/{table}/processed/
     *   3. For each znode, checks: (now - created_time) > TTL?
     *   4. If yes: Delete znode from ZooKeeper
     *   5. If no: Keep znode
     *
     * Why randomized interval (min vs max)?
     *   - Prevents thundering herd if multiple tables cleanup simultaneously
     *   - Spreads ZooKeeper load over time
     *   - Better for system stability
     *
     * Relationship with TTL:
     *   - TTL defines WHEN files should be cleaned (age threshold)
     *   - Cleanup interval defines HOW OFTEN we check
     *   - Files are cleaned: First cleanup run after TTL expires
     *
     * Example timeline:
     *   - File processed: 2026-01-01 00:00
     *   - TTL: 7 days (604800 seconds)
     *   - File expires: 2026-01-08 00:00
     *   - Cleanup runs: Every 5-7 minutes
     *   - File deleted: 2026-01-08 00:00-00:07 (first cleanup after expiry)
     *
     * Recommendations:
     *   - Min: 300000 (5 minutes) - frequent enough for timely cleanup
     *   - Max: 400000 (6.67 minutes) - randomization buffer
     *   - Don't set too low (<60000) - wastes CPU scanning constantly
     *   - Don't set too high (>600000) - cleanup becomes sluggish
     *
     * Trade-offs:
     *   - More frequent (1 min): 
     *       ✅ Faster cleanup, tighter control
     *       ❌ More CPU usage, more ZK load
     *   
     *   - Less frequent (30 min):
     *       ✅ Lower CPU/ZK load
     *       ❌ Slower cleanup, znodes linger longer
     *
     * For our incident fix:
     *   - With 7.1M znodes to clean
     *   - Cleanup interval: 5-7 minutes
     *   - Processing rate: ~1000 znodes/second
     *   - Expected cleanup time: 1-2 hours total
     */
    
    -- ==================================================================
    -- ADDITIONAL SETTINGS
    -- ==================================================================
    s3queue_loading_retries = 20,
    /* Number of times to retry processing a file if it fails.
     *
     * Value: Number of retries (default: 0)
     *   - 0 = No retries (fail immediately)
     *   - 10 = Retry 10 times
     *   - 20 = Retry 20 times (RECOMMENDED)
     *
     * When retries happen:
     *   - Network errors reading from S3
     *   - Temporary S3 throttling
     *   - Transient ClickHouse issues
     *   - Parsing errors (if data is malformed)
     *
     * Recommendation: Set to 10-20 for production systems.
     * Why: Handles transient failures gracefully without manual intervention.
     */
    
    s3queue_processing_threads_num = 5,
    /* Number of parallel threads for processing S3 files.
     *
     * Value: Number of threads (default: 1)
     *   - 1 = Sequential processing (one file at a time)
     *   - 5 = 5 files processed in parallel (RECOMMENDED)
     *   - 10 = 10 files in parallel (for high volume)
     *
     * Trade-offs:
     *   - More threads:
     *       ✅ Faster processing throughput
     *       ❌ Higher memory usage
     *       ❌ More concurrent S3 requests (watch rate limits)
     *   
     *   - Fewer threads:
     *       ✅ Lower resource usage
     *       ❌ Slower processing
     *
     * Recommendation: 
     *   - Start with 5
     *   - Increase if files are backing up
     *   - Decrease if hitting S3 rate limits or memory issues
     */
    
    s3queue_enable_logging_to_s3queue_log = 1,
    /* Enable logging of S3Queue operations to system.s3queue_log table.
     *
     * Value: 0 or 1
     *   - 0 = Logging disabled
     *   - 1 = Logging enabled (RECOMMENDED)
     *
     * What gets logged:
     *   - File processing start/end times
     *   - Success/failure status
     *   - Error messages if processing fails
     *   - Number of rows inserted
     *
     * Why enable:
     *   - Debugging when files fail to process
     *   - Monitoring ingestion rate
     *   - Audit trail of what was processed when
     *
     * Query logs:
     *   SELECT * FROM system.s3queue_log 
     *   WHERE event_time > now() - INTERVAL 1 HOUR
     *   ORDER BY event_time DESC;
     *
     * Recommendation: Always enable (1) in production.
     */
    
    s3queue_polling_min_timeout_ms = 1000,  -- 1 SECOND
    s3queue_polling_max_timeout_ms = 10000, -- 10 SECONDS
    /* How often to check S3 for new files when queue is empty.
     *
     * Values: Time in milliseconds
     *   - 1000 = 1 second (aggressive)
     *   - 10000 = 10 seconds (conservative)
     *
     * How polling works:
     *   - If files found: Process immediately, poll again soon (min timeout)
     *   - If no files: Wait longer before next poll (max timeout)
     *   - Uses exponential backoff between min and max
     *
     * Trade-offs:
     *   - Shorter timeout (1s):
     *       ✅ Faster detection of new files
     *       ❌ More S3 API calls (costs money)
     *       ❌ Higher S3 rate limit usage
     *   
     *   - Longer timeout (60s):
     *       ✅ Fewer S3 API calls
     *       ❌ Higher latency detecting new files
     *
     * Recommendation:
     *   - Real-time needs: min=1000, max=10000
     *   - Near-real-time: min=5000, max=30000
     *   - Batch/scheduled: Consider not using S3Queue at all
     */
    
    s3queue_polling_backoff_ms = 10000; -- 10 SECONDS
    /* Additional wait time after processing batch before next S3 poll.
     *
     * Value: Time in milliseconds
     *   - 0 = No additional backoff
     *   - 10000 = 10 seconds (RECOMMENDED)
     *   - 60000 = 1 minute
     *
     * When used:
     *   - After successfully processing a batch of files
     *   - Before starting next S3 list operation
     *   - Helps prevent rapid S3 API calls
     *
     * Recommendation: Set to 10-30 seconds to avoid S3 rate limits.
     */
```

---

## Architecture Comparison

### Pattern 1: S3Queue (Continuous Monitoring)

**Architecture:**
```
┌─────────────────────────────────────────────────────┐
│  S3 Bucket                                          │
│  ├─ file_001.parquet ──┐                            │
│  ├─ file_002.parquet ──┤ Files arrive              │
│  ├─ file_003.parquet ──┤ unpredictably              │
│  └─ file_004.parquet ──┤                            │
└─────────────────────────┼───────────────────────────┘
                          │
                          │ S3Queue polls every 1-10s
                          │ Auto-ingests when found
                          ↓
              ┌────────────────────────┐
              │   ClickHouse           │
              │   S3Queue Table        │
              │   (Continuous Monitor) │
              └────────────────────────┘
                          │
                          │ Tracks in ZooKeeper
                          ↓
              ┌────────────────────────┐
              │   ZooKeeper            │
              │   /s3queue/processed/  │
              │   ├─ file_001 ✓        │
              │   ├─ file_002 ✓        │
              │   └─ file_003 ✓        │
              └────────────────────────┘
```

**When to use:**
- Event-driven file arrivals
- Need real-time processing (<1 minute latency)
- Cannot predict file timing

**ZooKeeper overhead:**
- 1 znode per processed file
- With proper TTL: 50k-150k znodes per table
- With TTL=0 (misconfigured): Millions of znodes ⚠️

---

### Pattern 2: Scheduled INSERT (Recommended for Batch)

**Architecture:**
```
┌─────────────────────────────────────────────────────┐
│  S3 Bucket                                          │
│  ├─ date=2024-01-01/*.parquet                       │
│  ├─ date=2024-01-02/*.parquet                       │
│  ├─ date=2024-01-03/*.parquet                       │
│  └─ date=2024-01-04/*.parquet                       │
└─────────────────────────────────────────────────────┘
                          ↑
                          │
            ┌─────────────┴────────────────┐
            │  Airflow/Cron                │
            │  Daily at 3 AM:              │
            │  INSERT INTO table           │
            │  SELECT * FROM s3(...)       │
            └─────────────┬────────────────┘
                          │
                          ↓
              ┌────────────────────────┐
              │   ClickHouse           │
              │   Regular MergeTree    │
              │   (No S3Queue)         │
              └────────────────────────┘
```

**When to use:**
- Predictable file arrival (daily, hourly, etc.)
- Date/time partitioned data
- Batch processing acceptable

**ZooKeeper overhead:**
- ~100 znodes per table (just table metadata)
- No per-file tracking needed
- Much lower operational overhead

---

### Pattern 3: S3 Table Function (Ad-hoc/One-time)

**Architecture:**
```
┌─────────────────────────────────────────────────────┐
│  S3 Bucket                                          │
│  └─ historical_data/*.parquet                       │
└─────────────────────────────────────────────────────┘
                          ↑
                          │
            ┌─────────────┴────────────────┐
            │  Manual Query or Script      │
            │  INSERT INTO table           │
            │  SELECT * FROM s3(           │
            │    's3://bucket/path/*',     │
            │    'Parquet'                 │
            │  )                           │
            └─────────────┬────────────────┘
                          │
                          ↓
              ┌────────────────────────┐
              │   ClickHouse           │
              │   Regular MergeTree    │
              └────────────────────────┘
```

**When to use:**
- One-time data load
- Historical backfill
- Ad-hoc analysis
- No ongoing monitoring needed

**ZooKeeper overhead:**
- Zero (no tracking)
- Simplest approach

---

## Best Practices

### 1. Always Set a Reasonable TTL

**❌ BAD:**
```sql
s3queue_tracked_file_ttl_sec = 0  -- INFINITE, WILL CAUSE INCIDENT
```

**✅ GOOD:**
```sql
s3queue_tracked_file_ttl_sec = 604800  -- 7 days
```

**Calculation guide:**
```
Ask yourself:
1. How long might duplicate files appear? (Usually: hours to days)
2. How far back might I need to replay? (Usually: days to weeks)
3. What's my S3 consistency window? (Usually: seconds to minutes)

Answer = Your TTL (round up for safety, add 2-3x buffer)

Example:
- Might replay last 3 days of data
- TTL = 3 days × 2.5 buffer = 7 days (604800 seconds)
```

---

### 2. Calculate Proper File Tracking Limit

**Formula:**
```
tracked_files_limit = (files_per_day × TTL_in_days) × 1.5

Example:
- Process 10,000 files/day
- TTL = 7 days
- Limit = 10,000 × 7 × 1.5 = 105,000
- Set to: 150,000 (round up for headroom)
```

**❌ BAD:**
```sql
s3queue_tracked_files_limit = 10000000  -- 10M, way too high
```

**✅ GOOD:**
```sql
s3queue_tracked_files_limit = 150000  -- Based on calculation
```

---

### 3. Enable Monitoring and Logging

**Always enable:**
```sql
s3queue_enable_logging_to_s3queue_log = 1
```

**Monitor regularly:**
```sql
-- Check processing rate
SELECT 
    toStartOfHour(event_time) as hour,
    count() as files_processed,
    countIf(status = 'Processed') as successful,
    countIf(status = 'Failed') as failed
FROM system.s3queue_log
WHERE event_time > now() - INTERVAL 24 HOUR
GROUP BY hour
ORDER BY hour DESC;

-- Check for errors
SELECT *
FROM system.s3queue_log
WHERE status = 'Failed'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC;
```

---

### 4. Monitor ZooKeeper Growth

**Set up alerts:**
```sql
-- Alert if znode count exceeds threshold
SELECT 
    extract(path, '^/clickhouse/s3queue/[^/]+/') AS table_path,
    count() as znode_count
FROM system.zookeeper
WHERE path LIKE '/clickhouse/s3queue/%'
GROUP BY table_path
HAVING count() > 100000  -- Alert threshold
ORDER BY znode_count DESC;
```

**Dashboard metrics:**
```sql
-- Track znode growth over time
SELECT 
    toStartOfDay(now()) as date,
    count() as total_s3queue_znodes
FROM system.zookeeper
WHERE path LIKE '/clickhouse/s3queue/%';
```

---

### 5. Prefer Scheduled INSERT for Batch Data

**If your data is:**
- ✅ Date/time partitioned
- ✅ Arrives on schedule
- ✅ Predictable timing

**Then use:**
```sql
-- Airflow DAG or cron job
INSERT INTO target_table
SELECT * FROM s3(
    's3://bucket/date={partition}/*.parquet',
    'Parquet'
);
```

**Instead of S3Queue.**

---

## Common Pitfalls

### Pitfall 1: Setting TTL to 0 (Infinite)

**Problem:**
```sql
s3queue_tracked_file_ttl_sec = 0  -- NEVER DO THIS
```

**What happens:**
- Files tracked forever in ZooKeeper
- Unlimited znode growth
- Eventually: ZK snapshot > JVM heap → digest errors → cluster instability
- Our incident: 7.1M znodes, 3.3GB snapshots, P1 outage

**Fix:**
```sql
s3queue_tracked_file_ttl_sec = 604800  -- 7 days
```

Pitfall 2: Using S3Queue for Scheduled/Batch Data
Problem:

-- Date-partitioned data arriving daily at 2 AM
-- But using S3Queue to monitor 24/7
***
CREATE TABLE daily_reports__s3queue
ENGINE = S3Queue('s3://reports/date=*/*.parquet', 'Parquet');

*** What happens:

S3Queue polls S3 every 1-10 seconds checking for files
Most checks return nothing (files only arrive at 2 AM)
Wasted S3 API calls (costs money)
Tracks all files forever (if TTL=0)
More complex than needed

*** Fix:
```sql
-- Use scheduled INSERT instead
-- Airflow/cron runs daily at 3 AM
INSERT INTO daily_reports
SELECT * FROM s3('s3://reports/date={yesterday}/*.parquet', 'Parquet');
