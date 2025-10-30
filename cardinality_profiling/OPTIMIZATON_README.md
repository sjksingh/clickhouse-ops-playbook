# ClickHouse Observations Database - Action Plan & Root Cause Analysis

**Date**: October 29, 2025  
**Database**: `observations`  
**Cluster Health**: 🔴 **CRITICAL** - Immediate action required

---

## Executive Summary

Your `observations` database has **79,882 active parts** across all tables, with two tables in critical condition due to hash-based partitioning causing a "parts explosion." This is degrading query performance, overwhelming merge processes, and consuming excessive system resources.

**Impact**:
- Queries on affected tables are 10-100x slower than they should be
- Continuous high CPU/disk I/O from merges trying to keep up
- Risk of INSERT failures when part count exceeds safety thresholds

**Root Cause**: Misuse of hash-based partitioning (`cityHash64() % 100`) which fragments data into 100 buckets, preventing efficient merging.

---

## Diagnostic Queries Used

### Query 1: Complete Table Health Assessment
```sql
SELECT
    t.name AS table,
    t.engine,
    t.partition_key,
    t.sorting_key,
    -- Current state
    p.total_parts,
    p.total_rows,
    p.total_size,
    p.avg_part_size,
    p.min_rows_per_part,
    p.max_rows_per_part,
    -- Ingestion pattern (last 24h)
    i.parts_created_24h,
    i.avg_parts_per_hour,
    i.avg_rows_per_insert,
    i.last_insert,
    -- Health assessment
    multiIf(
        t.partition_key LIKE '%cityHash%' OR t.partition_key LIKE '%xxHash%' OR t.partition_key LIKE '% % %', 
        '🔴 CRITICAL: Hash/Modulo Partitioning',
        p.total_parts > 1000, 
        '🔴 CRITICAL: Too Many Parts (>1000)',
        p.total_parts > 500, 
        '🟠 WARNING: High Part Count (>500)',
        p.total_parts > 200, 
        '🟡 ATTENTION: Monitor Part Count (>200)',
        p.avg_part_bytes < 10485760 AND i.avg_parts_per_hour > 10,
        '🟡 SUBOPTIMAL: Small parts + High frequency',
        '🟢 HEALTHY'
    ) AS health_status,
    -- Specific issue
    multiIf(
        t.partition_key LIKE '%cityHash%' OR t.partition_key LIKE '%xxHash%',
        'Remove hash partitioning',
        p.total_parts > 500 AND i.avg_parts_per_hour > 20,
        'Increase batch size + Run OPTIMIZE',
        p.total_parts > 500,
        'Run OPTIMIZE TABLE',
        p.avg_part_bytes < 10485760,
        'Increase insert batch size',
        'Monitor only'
    ) AS recommended_action
FROM system.tables t
LEFT JOIN (
    SELECT 
        database,
        table,
        count() AS total_parts,
        sum(rows) AS total_rows,
        formatReadableSize(sum(bytes_on_disk)) AS total_size,
        formatReadableSize(avg(bytes_on_disk)) AS avg_part_size,
        avg(bytes_on_disk) AS avg_part_bytes,
        min(rows) AS min_rows_per_part,
        max(rows) AS max_rows_per_part
    FROM system.parts
    WHERE active = 1
    GROUP BY database, table
) p ON t.database = p.database AND t.name = p.table
LEFT JOIN (
    SELECT
        database,
        table,
        count() AS parts_created_24h,
        round(count() / 24, 2) AS avg_parts_per_hour,
        round(avg(rows), 0) AS avg_rows_per_insert,
        max(event_time) AS last_insert
    FROM system.part_log
    WHERE event_type = 'NewPart'
      AND event_time >= now() - INTERVAL 24 HOUR
    GROUP BY database, table
) i ON t.database = i.database AND t.name = i.table
WHERE t.database = 'observations'
  AND t.engine LIKE '%MergeTree%'
ORDER BY p.total_parts DESC NULLS LAST;
```

### Query 2: Merge Health Analysis
```sql
SELECT
    t.table,
    -- Insert activity
    COALESCE(i.parts_last_hour, 0) AS new_parts_last_hour,
    COALESCE(i.rows_last_hour, 0) AS rows_inserted_last_hour,
    -- Merge activity  
    COALESCE(m.merges_last_hour, 0) AS merges_completed_last_hour,
    COALESCE(m.parts_merged_last_hour, 0) AS parts_merged_last_hour,
    -- Net change (positive = parts accumulating)
    COALESCE(i.parts_last_hour, 0) - COALESCE(m.parts_merged_last_hour, 0) AS net_parts_change,
    -- Current state
    p.total_parts,
    -- Assessment
    multiIf(
        COALESCE(i.parts_last_hour, 0) > COALESCE(m.parts_merged_last_hour, 0) * 2,
        '🔴 MERGES FALLING BEHIND',
        COALESCE(i.parts_last_hour, 0) > COALESCE(m.parts_merged_last_hour, 0),
        '🟡 MERGES BARELY KEEPING UP',
        '🟢 MERGES OK'
    ) AS merge_health,
    -- Active merges right now
    COALESCE(am.active_merges, 0) AS currently_merging
FROM (
    SELECT DISTINCT table 
    FROM system.tables 
    WHERE database = 'observations' AND engine LIKE '%MergeTree%'
) t
LEFT JOIN (
    SELECT table, count() AS total_parts
    FROM system.parts
    WHERE active = 1 AND database = 'observations'
    GROUP BY table
) p ON t.table = p.table
LEFT JOIN (
    SELECT 
        table,
        count() AS parts_last_hour,
        sum(rows) AS rows_last_hour
    FROM system.part_log
    WHERE event_type = 'NewPart'
      AND event_time >= now() - INTERVAL 1 HOUR
      AND database = 'observations'
    GROUP BY table
) i ON t.table = i.table
LEFT JOIN (
    SELECT
        table,
        count() AS merges_last_hour,
        sum(length(splitByChar(',', part_name))) AS parts_merged_last_hour
    FROM system.part_log
    WHERE event_type = 'MergeParts'
      AND event_time >= now() - INTERVAL 1 HOUR
      AND database = 'observations'
    GROUP BY table
) m ON t.table = m.table
LEFT JOIN (
    SELECT table, count() AS active_merges
    FROM system.merges
    WHERE database = 'observations'
    GROUP BY table
) am ON t.table = am.table
ORDER BY net_parts_change DESC;
```

---

## 🔴 CRITICAL PRIORITY 1: Fix `deduped_observations_2`

### The Problem

**Current State**:
- **79,825 active parts** (should be <100)
- **59 KiB average part size** (should be 100-500 MiB)
- **4,471 new parts per hour**
- **Only 88 rows per insert** (extremely poor batching)
- **147 million rows** in 4.52 GiB

**Root Cause**: Hash-based partitioning
```sql
partition_key: cityHash64(observation_owner_domain) % 100
```

### Why This Is Wrong

**How Hash Partitioning Creates the Problem**:

1. **Data gets split 100 ways**: Every insert is divided across 100 partitions based on domain hash
   ```
   INSERT 5,000 rows
     ↓ Hash function splits by domain
     ↓
   Partition 0: 50 rows  → Creates tiny part
   Partition 1: 48 rows  → Creates tiny part
   Partition 2: 52 rows  → Creates tiny part
   ... (98 more partitions)
   ```

2. **Merges happen WITHIN partitions, not across them**:
   - ClickHouse cannot merge parts from Partition 0 with parts from Partition 1
   - Each of the 100 partitions merges independently
   - With only 50-88 rows per partition per insert, parts stay tiny forever

3. **The math of disaster**:
   ```
   4,471 parts created per hour
   ÷ 100 partitions
   = ~45 parts per partition per hour
   
   Merges can only combine ~10-20 parts per hour per partition
   Result: Parts accumulate faster than they can merge
   ```

4. **Performance impact**:
   - Every query must open and read 79,825 separate files
   - More file handles, more memory overhead
   - Queries are 10-100x slower than they should be

### Why Hash Partitioning Is an Anti-Pattern in ClickHouse

**Common misconception**: "Hash partitioning distributes data evenly for better performance"

**Reality in ClickHouse**:
- ✅ **Sharding** (Distributed tables) distributes data across nodes
- ✅ **Partitioning** is for dropping old data (time-based TTL)
- ❌ **Hash partitioning** does neither - it only fragments your data

**The correct table structure** (like `deduped_observations`, which is healthy with only 4 parts):
```sql
ENGINE = ReplicatedReplacingMergeTree
-- NO PARTITION BY
ORDER BY (observation_owner_domain, observation_group_key, asset_key)
```

### Action Steps

#### Step 1: Create New Table Without Hash Partitioning

```sql
-- Run on all nodes in cluster
CREATE TABLE observations.deduped_observations_3 ON CLUSTER '{cluster}'
(
    observation_category String,
    observation_type String,
    observation_group_identifier String,
    observation_owner_domain String,
    observation_group_key String,
    asset_key String,
    -- Add all other columns from deduped_observations_2
    created_at DateTime64(3, 'UTC')
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/observations/deduped_observations_3',
    '{replica}'
)
ORDER BY (observation_owner_domain, observation_group_key, asset_key)
-- CRITICAL: NO PARTITION BY clause!
SETTINGS index_granularity = 8192;
```

**Why this fixes it**:
- No partitioning = all data merges together
- Parts will consolidate from 79,825 → ~50-100 large parts
- Average part size: 59 KiB → 200-500 MiB
- Queries will be 10-100x faster

#### Step 2: Migrate Data Safely

**Option A: Partition-by-Partition Migration** (Recommended - Resumable)

Create migration script `migrate_deduped_observations.sh`:

```bash
#!/bin/bash

table_old='deduped_observations_2'
table_new='deduped_observations_3'
database='observations'
CH="clickhouse-client --host localhost --user default --password YOUR_PASSWORD"

# Create tracking table
$CH -q "CREATE TABLE IF NOT EXISTS observations.migration_progress_deduped (
    partition_id UInt8,
    migrated_at DateTime DEFAULT now(),
    row_count UInt64,
    status String
) ENGINE = Log;"

# Migrate each of the 100 partitions
for partition in {0..99}; do
  # Check if already migrated
  exists=$($CH -q "SELECT count() FROM observations.migration_progress_deduped 
                   WHERE partition_id = $partition AND status = 'completed'" --format TSV)
  
  if [ "$exists" -eq 0 ]; then
    echo "Migrating partition $partition..."
    
    # Get row count for this partition
    row_count=$($CH -q "SELECT count() FROM $database.$table_old 
                        WHERE cityHash64(observation_owner_domain) % 100 = $partition" --format TSV)
    
    # Record start
    $CH -q "INSERT INTO observations.migration_progress_deduped 
            VALUES ($partition, now(), 0, 'in_progress')"
    
    # Migrate the partition
    $CH -n -q "
      INSERT INTO $database.$table_new 
      SELECT * FROM $database.$table_old 
      WHERE cityHash64(observation_owner_domain) % 100 = $partition
      SETTINGS max_insert_threads=8, max_threads=16;
    "
    
    if [ $? -eq 0 ]; then
      # Update tracking
      $CH -q "INSERT INTO observations.migration_progress_deduped 
              VALUES ($partition, now(), $row_count, 'completed')"
      echo "✓ Partition $partition complete ($row_count rows)"
    else
      $CH -q "INSERT INTO observations.migration_progress_deduped 
              VALUES ($partition, now(), 0, 'failed')"
      echo "✗ Partition $partition FAILED"
    fi
  else
    echo "○ Partition $partition already migrated, skipping"
  fi
done

echo ""
echo "Migration Summary:"
$CH -q "SELECT 
    status,
    count() AS partitions,
    sum(row_count) AS total_rows
FROM observations.migration_progress_deduped
GROUP BY status
FORMAT PrettyCompact"
```

**Why this approach**:
- ✅ **Idempotent**: Can be re-run safely if it fails
- ✅ **Resumable**: Skips already-migrated partitions
- ✅ **Progress tracking**: See exactly where you are
- ✅ **Atomic per partition**: If partition 47 fails, partitions 1-46 are safe

**Option B: Simple Migration** (Faster but not resumable)

```sql
-- Simple INSERT-SELECT (only if you can afford potential restart)
INSERT INTO observations.deduped_observations_3
SELECT * FROM observations.deduped_observations_2
SETTINGS max_insert_threads=16, max_threads=32;
```

#### Step 3: Verify Migration

```sql
-- Compare row counts
SELECT 'OLD' AS table, count() AS rows FROM observations.deduped_observations_2
UNION ALL
SELECT 'NEW' AS table, count() AS rows FROM observations.deduped_observations_3;

-- Check part structure (NEW should have ~50-100 parts)
SELECT
    table,
    count() AS parts,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    formatReadableSize(avg(bytes_on_disk)) AS avg_part_size
FROM system.parts
WHERE table IN ('deduped_observations_2', 'deduped_observations_3')
  AND active = 1
GROUP BY table;

-- Sample data verification
SELECT observation_owner_domain, count() 
FROM observations.deduped_observations_2 
GROUP BY observation_owner_domain 
ORDER BY count() DESC LIMIT 10;

SELECT observation_owner_domain, count() 
FROM observations.deduped_observations_3 
GROUP BY observation_owner_domain 
ORDER BY count() DESC LIMIT 10;
-- Should match!
```

#### Step 4: Optimize New Table

```sql
-- Force merge to consolidate parts (run after migration completes)
OPTIMIZE TABLE observations.deduped_observations_3 ON CLUSTER '{cluster}' FINAL;

-- Verify final state (should see 10-50 large parts)
SELECT 
    count() AS parts,
    formatReadableSize(avg(bytes_on_disk)) AS avg_part_size
FROM system.parts
WHERE table = 'deduped_observations_3' AND active = 1;
```

#### Step 5: Switch Application & Clean Up

```sql
-- Stop application inserts to old table

-- Atomic table swap
RENAME TABLE 
    observations.deduped_observations_2 TO observations.deduped_observations_2_old,
    observations.deduped_observations_3 TO observations.deduped_observations_2
ON CLUSTER '{cluster}';

-- Update application to resume inserts (now going to new table)

-- After 1-2 weeks of validation, drop old table
DROP TABLE observations.deduped_observations_2_old ON CLUSTER '{cluster}';
```

### Expected Results

**Before**:
- 79,825 parts
- 59 KiB average part size
- 4,471 parts created per hour
- Merges overwhelmed
- Queries slow and unpredictable

**After**:
- 50-100 parts (99% reduction)
- 200-500 MiB average part size (3,000x larger)
- 50-100 parts created per hour (98% reduction)
- Merges easily keeping up
- Queries 10-100x faster

### Timeline

- **Step 1** (Create table): 1 minute
- **Step 2** (Migration): 2-4 hours for 147M rows
- **Step 3** (Verify): 10 minutes
- **Step 4** (Optimize): 30-60 minutes
- **Step 5** (Switch): 5 minutes

**Total**: ~4-6 hours with careful validation

---

## 🔴 CRITICAL PRIORITY 2: Fix `vrm_statuses`

### The Problem

**Current State**:
- **57 active parts** (smaller table, but same issue)
- **3.77 KiB average part size** (extremely tiny)
- **Only 4 rows per insert**
- **16,075 total rows** in 214 KiB

**Root Cause**: Same hash partitioning anti-pattern
```sql
partition_key: cityHash64(view_owner_domain) % 100
```

### Why This Matters

Even though it's a smaller table, the same performance problems apply:
- 57 tiny parts instead of 1 large part
- Queries must read 57 separate files
- Merge overhead disproportionate to table size

### Action Steps

```sql
-- Step 1: Create new table
CREATE TABLE observations.vrm_statuses_new ON CLUSTER '{cluster}'
(
    -- Copy all columns from vrm_statuses
)
ENGINE = ReplicatedCoalescingMergeTree(
    '/clickhouse/tables/{shard}/observations/vrm_statuses_new',
    '{replica}'
)
ORDER BY (observation_owner_domain, observation_group_key, asset_key, view_owner_domain)
-- NO PARTITION BY!
SETTINGS index_granularity = 8192;

-- Step 2: Simple migration (small table)
INSERT INTO observations.vrm_statuses_new
SELECT * FROM observations.vrm_statuses;

-- Step 3: Verify
SELECT count() FROM observations.vrm_statuses;
SELECT count() FROM observations.vrm_statuses_new;

-- Step 4: Optimize
OPTIMIZE TABLE observations.vrm_statuses_new ON CLUSTER '{cluster}' FINAL;

-- Step 5: Swap
RENAME TABLE 
    observations.vrm_statuses TO observations.vrm_statuses_old,
    observations.vrm_statuses_new TO observations.vrm_statuses
ON CLUSTER '{cluster}';

-- Step 6: Drop old after validation
DROP TABLE observations.vrm_statuses_old ON CLUSTER '{cluster}';
```

**Expected result**: 57 parts → 1 part, 3.77 KiB → 200+ KiB

**Timeline**: 30 minutes total

---

## 🟠 WARNING PRIORITY 3: Fix Insert Batching

### The Problem: Tiny Inserts Creating Small Parts

Several tables have poor insert batching:

| Table | Rows per Insert | Problem |
|-------|----------------|---------|
| `bluepipe_feedback_remediation` | 17 | Streaming too small batches |
| `vulnerability_details` | 1,482 | Better but still suboptimal |
| Various small tables | <100 | Single-row or tiny inserts |

### Why Small Inserts Are Bad

**Every INSERT creates at least one part**:
```
Application inserts 17 rows → ClickHouse creates 1 part with 17 rows
Application inserts 17 rows → Another part with 17 rows
... repeat 100 times per hour ...
Result: 100 tiny parts that need merging
```

**The math**:
- `bluepipe_feedback_remediation`: 92 inserts/hour × 17 rows = creates 92 parts/hour
- Net accumulation: +43 parts/hour (merges can't keep up)
- After 24 hours: 1,000+ parts

### Why This Happens

**Common causes**:
1. **Streaming pipelines** (Flink, Kafka consumers) inserting as soon as data arrives
2. **Application loops** inserting row-by-row
3. **Microservices** each doing small inserts independently

### Action Steps

#### Option A: Application-Level Batching (Best)

**Current pattern** (bad):
```python
# Python example - probably in your Flink job
for record in kafka_stream:
    clickhouse.insert('bluepipe_feedback_remediation', [record])
    # Creates 1 part per record!
```

**Fixed pattern** (good):
```python
buffer = []
buffer_size = 50000  # 50k rows

for record in kafka_stream:
    buffer.append(record)
    
    if len(buffer) >= buffer_size:
        clickhouse.insert('bluepipe_feedback_remediation', buffer)
        buffer = []

# Don't forget final batch
if buffer:
    clickhouse.insert('bluepipe_feedback_remediation', buffer)
```

**Java/Flink example**:
```java
// In your Flink sink
public class ClickHouseBatchingSink implements SinkFunction<Record> {
    private List<Record> buffer = new ArrayList<>();
    private static final int BATCH_SIZE = 50000;
    
    @Override
    public void invoke(Record record, Context context) {
        buffer.add(record);
        
        if (buffer.size() >= BATCH_SIZE) {
            flushBuffer();
        }
    }
    
    private void flushBuffer() {
        if (!buffer.isEmpty()) {
            clickhouseClient.insert("bluepipe_feedback_remediation", buffer);
            buffer.clear();
        }
    }
}
```

#### Option B: Async Inserts (Easier but Less Control)

ClickHouse can batch for you:

```sql
-- In your application, use async_insert setting
INSERT INTO bluepipe_feedback_remediation
SETTINGS async_insert=1, wait_for_async_insert=0
VALUES (...);
```

**How it works**:
- ClickHouse buffers inserts in memory
- Flushes every 200ms or when buffer reaches size limit
- Automatically creates larger parts

**Trade-offs**:
- ✅ Easy to implement (just add settings)
- ✅ ClickHouse handles batching
- ⚠️ Less predictable (flush timing varies)
- ⚠️ Data in memory until flush (potential loss on crash)

#### Option C: Buffer Table (Advanced)

For very high-frequency small inserts:

```sql
-- Create buffer table
CREATE TABLE observations.bluepipe_feedback_remediation_buffer AS observations.bluepipe_feedback_remediation
ENGINE = Buffer(
    observations,                      -- destination database
    bluepipe_feedback_remediation,     -- destination table
    16,                                -- num_layers
    10,                                -- min_time (seconds)
    100,                               -- max_time (seconds)
    10000,                             -- min_rows
    1000000,                           -- max_rows
    10485760,                          -- min_bytes (10MB)
    104857600                          -- max_bytes (100MB)
);

-- Application inserts to buffer table
INSERT INTO observations.bluepipe_feedback_remediation_buffer VALUES (...);
-- ClickHouse automatically flushes to main table in batches
```

### Expected Results

**For `bluepipe_feedback_remediation`**:
- Before: 92 inserts/hour × 17 rows = 92 parts/hour
- After: 2-4 inserts/hour × 50,000 rows = 2-4 parts/hour
- **96% reduction in parts created**

**For `vulnerability_details`**:
- Before: 509 inserts/hour × 1,482 rows = 509 parts/hour
- After: 15-20 inserts/hour × 50,000 rows = 15-20 parts/hour
- **96% reduction in parts created**

### Timeline

- Application code changes: 1-2 hours development + testing
- Deployment: Per your release cycle
- Results visible: Within 1 hour of deployment

---

## 🟡 MONITORING PRIORITY 4: Watch `observations_in`

### The Situation

**Current State**:
- **16 parts** (healthy! ✅)
- **2 billion rows**, 114 GB
- **No partitioning** (correct! ✅)
- **BUT**: Merges falling behind (15,000 parts/hour created, 11,271 merged/hour)

### Why This Is Happening

You're currently running a RESTORE operation on this table:
```
INSERT INTO observations.observations_in (from S3 backup)
  → Creating parts very rapidly
  → Merges can't keep up during bulk load
  → This is NORMAL during restore
```

### Why It's Not Critical (Yet)

**The table structure is correct**:
- ✅ No hash partitioning
- ✅ Good sorting key
- ✅ Parts are large (7.16 GiB average)

**During restore**:
- Temporary high part creation is expected
- After restore completes, merges will catch up
- The 16 parts will consolidate naturally

### Action Steps

#### Step 1: Monitor Restore Progress

```sql
-- Check if restore is still running
SELECT 
    id,
    status,
    formatReadableSize(bytes_read) AS read,
    formatReadableSize(total_size) AS total,
    round(bytes_read / total_size * 100, 2) AS progress_pct
FROM system.backups
WHERE status = 'RESTORING'
ORDER BY start_time DESC
LIMIT 1;

-- Watch part count
SELECT count() AS parts
FROM system.parts
WHERE table = 'observations_in' AND active = 1;
-- Run every 5 minutes during restore
```

#### Step 2: After Restore Completes

```sql
-- Check final part count
SELECT 
    count() AS parts,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    formatReadableSize(avg(bytes_on_disk)) AS avg_part_size
FROM system.parts
WHERE table = 'observations_in' AND active = 1;
```

**If parts > 100 after restore**:
```sql
-- Force merge to consolidate
OPTIMIZE TABLE observations.observations_in ON CLUSTER '{cluster}' FINAL;
```

**If parts < 100**:
- ✅ Table is healthy
- Monitor only
- Merges will naturally maintain this state

#### Step 3: Long-term Monitoring

```sql
-- Run daily to ensure health
SELECT 
    table,
    count() AS parts,
    formatReadableSize(avg(bytes_on_disk)) AS avg_part_size,
    multiIf(
        parts > 100, '🔴 Action needed',
        parts > 50, '🟡 Monitor closely',
        '🟢 Healthy'
    ) AS status
FROM system.parts
WHERE table = 'observations_in' AND active = 1
GROUP BY table;
```

### Timeline

- **Now**: Restore in progress (monitor only)
- **After restore**: Check part count (5 minutes)
- **If needed**: Run OPTIMIZE (1-2 hours for 114 GB table)

---

## 📊 Success Metrics

### Current State (Before Actions)

```
Total Parts in observations database: 79,882
Critical tables: 2 (deduped_observations_2, vrm_statuses)
Parts created per hour: ~5,000
Merge backlog: Growing
Query performance: Degraded
```

### Target State (After Actions)

```
Total Parts in observations database: <500
Critical tables: 0
Parts created per hour: ~200
Merge backlog: None
Query performance: Optimal (10-100x faster)
```

### Key Performance Indicators

**After fixing `deduped_observations_2`**:
- [ ] Part count: 79,825 → <100 (99.9% reduction)
- [ ] Average part size: 59 KiB → 200+ MiB (3,000x improvement)
- [ ] Query response time: 10-100x faster
- [ ] Merge CPU usage: 90% reduction

**After fixing insert batching**:
- [ ] New parts per hour: 5,000 → 200 (96% reduction)
- [ ] Insert efficiency: 88 rows/insert → 50,000+ rows/insert
- [ ] Merge lag: Eliminated

**Overall cluster health**:
- [ ] No tables with >100 parts
- [ ] All tables with >100 MiB average part size
- [ ] Merges easily keeping up with inserts
- [ ] Predictable, fast query performance

---

## 🔄 Ongoing Monitoring Plan

### Daily Health Check

```sql
-- Run this every day
SELECT
    database,
    count(DISTINCT table) AS total_tables,
    sum(CASE WHEN parts > 500 THEN 1 ELSE 0 END) AS critical_tables,
    sum(CASE WHEN parts > 200 THEN 1 ELSE 0 END) AS warning_tables,
    sum(CASE WHEN parts > 100 THEN 1 ELSE 0 END) AS attention_tables,
    sum(parts) AS total_parts,
    formatReadableSize(sum(bytes)) AS total_size
FROM (
    SELECT 
        database,
        table,
        count() AS parts,
        sum(bytes_on_disk) AS bytes
    FROM system.parts
    WHERE active = 1
    GROUP BY database, table
)
WHERE database = 'observations'
GROUP BY database;
```

**Alert if**:
- `critical_tables > 0`
- `total_parts > 1000`

### Weekly Deep Dive

```sql
-- Run Query 1 from diagnostic workflow every week
-- Review any tables trending toward high part counts
-- Investigate new tables added to the database
```

### Real-Time Monitoring

```sql
-- Set up continuous monitoring
SELECT 
    table,
    count() AS new_parts_last_5min
FROM system.part_log
WHERE event_type = 'NewPart'
  AND event_time >= now() - INTERVAL 5 MINUTE
  AND database = 'observations'
GROUP BY table
HAVING new_parts_last_5min > 50  -- Alert threshold
ORDER BY new_parts_last_5min DESC
WATCH 60;
```

---

## 📝 Summary: Why These Actions Matter

### Root Cause Recap

**The fundamental problem**: Hash-based partitioning fragments data in a way that ClickHouse's merge algorithm cannot handle efficiently.

**How ClickHouse merges work**:
1. Background threads continuously merge small parts into larger parts
2. Merges happen WITHIN partitions only
3. With 100 partitions, each partition merges independently
4. With tiny inserts (88 rows), each partition gets ~1 row per insert
5. Parts accumulate faster than merges can consolidate them
6. Result: 79,825 parts and degraded performance

**Why removing partitioning fixes everything**:
1. All data in one "partition" (no partition key)
2. Merges can combine ANY parts together
3. Small parts quickly merge into large, efficient parts
4. Steady state: 50-100 large parts instead of 79,825 tiny parts
5. Queries read fewer, larger files = 10-100x faster

### The Business Impact

**Before fixes**:
- Queries timeout or take minutes instead of seconds
- Dashboard loads are slow, frustrating users
- High CPU/disk utilization from constant merging
- Risk of INSERT failures when part limits are exceeded
- Wasted infrastructure costs (over-provisioned to handle inefficiency)

**After fixes**:
- Sub-second query response times
- Smooth dashboard performance
- 90% reduction in merge CPU/disk usage
- Stable, predictable performance
- Right-sized infrastructure costs

### Why This Happened

**Common source of hash partitioning**:
- Migrated from Cassandra or other sharded databases
- Mistaken belief that "partitioning = performance"
- Copy-paste from incorrect examples
- Misunderstanding of ClickHouse's architecture

**The correct mental model**:
- **Partitioning** = Lifecycle management (drop old data by date)
- **Sharding** = Horizontal scaling (Distributed tables across cluster)
- **Sorting Key** = Query optimization (ORDER BY clause)

---

## 🎯 Execution Order & Timeline

### Week 1: Critical Fixes

**Day 1-2: Plan & Prepare**
- [ ] Review this action plan with team
- [ ] Schedule maintenance window (optional, can do online)
- [ ] Back up `deduped_observations_2` (safety)
- [ ] Test migration script on dev/staging cluster

**Day 3-4: Execute `deduped_observations_2` Migration**
- [ ] Create `deduped_observations_3` table
- [ ] Run migration script (4-6 hours)
- [ ] Verify data integrity
- [ ] Optimize new table
- [ ] Monitor for 24 hours

**Day 5: Switch Traffic**
- [ ] Switch application to new table
- [ ] Monitor query performance (should see 10x+ improvement)
- [ ] Monitor part counts (should see <100 parts)

**Day 6: Execute `vrm_statuses` Migration**
- [ ] Create new table
- [ ] Migrate data (30 minutes)
- [ ] Switch traffic
- [ ] Verify

**Day 7: Verify & Monitor**
- [ ] Run health check queries
- [ ] Confirm all critical tables resolved
- [ ] Document lessons learned

### Week 2: Optimization

**Day 8-9: Application Code Changes**
- [ ] Identify streaming/batch jobs inserting to affected tables
- [ ] Implement batching logic (50k rows per insert)
- [ ] Test in dev/staging
- [ ] Deploy to production

**Day 10-12: Monitor & Tune**
- [ ] Watch part creation rates
- [ ] Adjust batch sizes if needed
- [ ] Verify merge health
- [ ] Check `observations_in` after restore completes

**Day 13-14: Final Validation**
- [ ] Run complete diagnostic workflow
- [ ] Verify all tables healthy
- [ ] Set up ongoing monitoring
- [ ] Drop old tables after validation period

---

## 🚨 Rollback Plan

If migration fails or causes issues:

### For `deduped_observations_2`

**If migration fails mid-way**:
```sql
-- The script is idempotent - just re-run it
-- It will skip completed partitions and resume

-- Check progress
SELECT status, count(*) 
FROM observations.migration_progress_deduped 
GROUP BY status;

-- If needed, restart from failed partition
-- The script automatically handles this
```

**If new table has data issues**:
```sql
-- Old table still exists, just switch back
RENAME TABLE 
    observations.deduped_observations_2 TO observations.deduped_observations_3,
    observations.deduped_observations_2_old TO observations.deduped_observations_2
ON CLUSTER '{cluster}';

-- Resume using old table while investigating
```

**If queries are unexpectedly slow on new table**:
```sql
-- Run OPTIMIZE again
OPTIMIZE TABLE observations.deduped_observations_3 FINAL;

-- Check if merges completed
SELECT * FROM system.merges WHERE table = 'deduped_observations_3';

-- If needed, rollback to old table temporarily
```

### For Insert Batching Changes

**If application batching causes issues**:
```python
# Reduce batch size temporarily
BATCH_SIZE = 10000  # Instead of 50000

# Or revert to old code
# Old behavior is always preserved in version control
```

**If async_insert causes data loss concerns**:
```sql
-- Switch back to synchronous inserts
INSERT INTO table 
SETTINGS async_insert=0  -- Disable async
VALUES (...);
```

---

## 🔍 Troubleshooting Guide

### Problem: Migration Script Fails on Partition X

**Symptoms**:
```
Partition 47 FAILED
Error: Memory limit exceeded
```

**Solution**:
```bash
# Increase memory limit for that partition
CH="clickhouse-client --max_memory_usage=20000000000"  # 20GB

# Or migrate in smaller chunks
$CH -q "INSERT INTO $table_new 
        SELECT * FROM $table_old 
        WHERE cityHash64(observation_owner_domain) % 100 = 47 
        LIMIT 10000000"  # First 10M rows

$CH -q "INSERT INTO $table_new 
        SELECT * FROM $table_old 
        WHERE cityHash64(observation_owner_domain) % 100 = 47 
        LIMIT 10000000 OFFSET 10000000"  # Next 10M rows
```

### Problem: OPTIMIZE Takes Too Long

**Symptoms**:
```
OPTIMIZE TABLE running for hours
```

**Solution**:
```sql
-- Check merge progress
SELECT 
    table,
    elapsed,
    progress,
    formatReadableSize(bytes_read_uncompressed) AS read,
    formatReadableSize(bytes_written_uncompressed) AS written
FROM system.merges
WHERE table = 'deduped_observations_3';

-- If stuck, kill and retry with lighter load
KILL QUERY WHERE query_id = 'xxx';

-- Run OPTIMIZE during off-hours
-- Or let natural merges handle it (slower but no impact)
```

### Problem: Parts Still Accumulating After Fixes

**Symptoms**:
```
New table still showing >100 parts after a week
```

**Diagnosis**:
```sql
-- Check if inserts are still too small
SELECT 
    table,
    count() AS parts_last_hour,
    round(avg(rows), 0) AS avg_rows_per_insert
FROM system.part_log
WHERE event_type = 'NewPart'
  AND event_time >= now() - INTERVAL 1 HOUR
  AND table = 'deduped_observations_3'
GROUP BY table;

-- If avg_rows_per_insert < 10000, batching not working
```

**Solution**:
```python
# Verify application code is actually batching
# Add logging to confirm batch sizes
logger.info(f"Inserting batch of {len(buffer)} rows")

# Check if multiple processes are inserting
# Each process should have its own buffer
```

### Problem: Queries Still Slow After Migration

**Symptoms**:
```
Query takes 30 seconds on new table (expected <3 seconds)
```

**Diagnosis**:
```sql
-- Check if OPTIMIZE completed
SELECT count() AS parts
FROM system.parts
WHERE table = 'deduped_observations_3' AND active = 1;
-- Should be <100

-- Check part sizes
SELECT 
    formatReadableSize(avg(bytes_on_disk)) AS avg_part_size,
    formatReadableSize(min(bytes_on_disk)) AS min_part_size
FROM system.parts
WHERE table = 'deduped_observations_3' AND active = 1;
-- avg should be >100 MiB

-- Check if query is using indexes
EXPLAIN SELECT ... FROM deduped_observations_3 WHERE ...;
-- Look for "ReadFromMergeTree" with index usage
```

**Solution**:
```sql
-- Force final optimization
OPTIMIZE TABLE deduped_observations_3 FINAL;

-- If still slow, check query patterns
-- May need to adjust ORDER BY key for your queries
```

---

## 📚 References & Learning Resources

### ClickHouse Documentation

- [MergeTree Table Engine](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree)
- [Data Parts and Merges](https://clickhouse.com/docs/en/operations/optimizing-performance/sampling-query-profiler)
- [Partitioning Best Practices](https://clickhouse.com/docs/en/optimize/partitioning-key)

### Key Concepts Explained

**Parts**:
- Immutable data blocks on disk
- Each INSERT creates at least one part
- Background merges combine parts
- Goal: Large parts (100+ MiB) for efficiency

**Partitioning**:
- Divides table into separate "buckets"
- Used for: Time-based data retention (TTL)
- Not for: Query performance or data distribution
- Rule: Use only for lifecycle management

**Merges**:
- Automatic background process
- Combines small parts into larger ones
- Removes duplicates (in Replacing/Collapsing engines)
- Limited by CPU, disk I/O, and partition boundaries

**Sharding vs Partitioning**:
- Sharding: Distribute data across cluster nodes (Distributed tables)
- Partitioning: Divide data within a table (Partition key)
- These are orthogonal concepts!

### Internal Links to This Document

For quick reference, bookmark these sections:
- [Critical Priority 1: deduped_observations_2](#-critical-priority-1-fix-deduped_observations_2)
- [Migration Script](#step-2-migrate-data-safely)
- [Rollback Plan](#-rollback-plan)
- [Troubleshooting](#-troubleshooting-guide)

---

## ✅ Checklist: Pre-Migration Validation

Before starting migration, verify:

### Environment Checks
- [ ] Cluster has sufficient disk space (need 2x current table size)
- [ ] ZooKeeper is healthy (`SELECT * FROM system.zookeeper WHERE path='/'`)
- [ ] All replicas are in sync (`SELECT * FROM system.replicas WHERE is_readonly=1`)
- [ ] No stuck merges (`SELECT * FROM system.merges WHERE elapsed > 3600`)

### Backup & Safety
- [ ] Recent backup exists for `deduped_observations_2`
- [ ] Tested backup restore on dev cluster
- [ ] Stakeholders notified of maintenance window (if needed)
- [ ] Rollback plan reviewed and understood

### Application Readiness
- [ ] Identified all applications writing to `deduped_observations_2`
- [ ] Prepared configuration changes for table name switch
- [ ] Tested application with new table structure in dev
- [ ] Monitoring dashboards ready to track migration progress

### Technical Readiness
- [ ] Migration script tested on dev cluster
- [ ] Reviewed and understood all SQL commands
- [ ] Terminal multiplexer (tmux/screen) ready for long-running commands
- [ ] Team members available for support during migration

---

## 📞 Support & Escalation

### Internal Team Contacts
- **DBA Team**: [Contact info]
- **Application Team**: [Contact info]
- **Infrastructure Team**: [Contact info]

### When to Escalate

**Escalate immediately if**:
- Migration fails with data corruption
- Production queries timing out after switch
- Disk space exhaustion during migration
- Replica sync failures

**Escalate within 4 hours if**:
- Migration taking 2x longer than expected
- Part count not decreasing after OPTIMIZE
- Unexpected application errors after switch

### ClickHouse Community Resources
- [ClickHouse Slack](https://clickhouse.com/slack)
- [GitHub Issues](https://github.com/ClickHouse/ClickHouse/issues)
- [ClickHouse Users Telegram](https://t.me/clickhouse_en)

---

## 🎓 Training: Preventing Future Issues

### Best Practices for Your Team

**When creating new tables**:
1. Default to NO partitioning
2. Only add `PARTITION BY toYYYYMM(date_column)` if you need TTL
3. Never use hash-based partitioning
4. Test with production-like data volume before deploying

**When writing insert code**:
1. Batch at least 10,000 rows per insert
2. Target 50,000-100,000 rows for optimal performance
3. Use async_insert for very high-frequency small inserts
4. Monitor part creation rate in production

**When reviewing PRs**:
- [ ] Check for `cityHash` or `% N` in PARTITION BY
- [ ] Verify insert code includes batching
- [ ] Confirm ORDER BY key matches query patterns
- [ ] Review expected data volume and part count

### Code Review Checklist

```sql
-- ❌ BAD: Hash partitioning
CREATE TABLE example
PARTITION BY cityHash64(column) % 100  -- REJECT THIS IN PR!
ORDER BY (column);

-- ❌ BAD: Overly granular time partitioning
CREATE TABLE example
PARTITION BY toYYYYMMDD(timestamp)  -- Too granular for most cases
ORDER BY (timestamp);

-- ✅ GOOD: No partitioning
CREATE TABLE example
ORDER BY (column);

-- ✅ GOOD: Monthly partitioning (if TTL needed)
CREATE TABLE example
PARTITION BY toYYYYMM(timestamp)  -- Good for data retention
ORDER BY (column);
```

---

## 📈 Long-Term Optimization Roadmap

### Phase 1: Immediate (This Action Plan)
- Fix hash partitioning on critical tables
- Implement insert batching
- Restore cluster health

### Phase 2: Optimization (Next 30 days)
- Review all table ORDER BY keys for query patterns
- Implement projection materialized views for slow queries
- Set up automated part count alerting
- Create runbook for common issues

### Phase 3: Architecture (Next 90 days)
- Evaluate if sharding is needed for largest tables
- Implement proper monitoring dashboards
- Review data retention policies
- Consider tiered storage for cold data

### Phase 4: Excellence (Ongoing)
- Regular performance reviews
- Team training on ClickHouse best practices
- Continuous optimization of query patterns
- Capacity planning based on growth trends

---

## 📋 Success Criteria

This action plan is complete when:

### Technical Metrics
- ✅ No tables with >200 parts
- ✅ All tables averaging >100 MiB per part
- ✅ Part creation rate <500/hour cluster-wide
- ✅ Merges completing faster than parts created
- ✅ Query p95 latency <5 seconds for all dashboards

### Operational Metrics
- ✅ Zero part-related alerts in 7 days
- ✅ CPU utilization for merges <20%
- ✅ Disk I/O within normal ranges
- ✅ No INSERT timeouts or failures

### Team Readiness
- ✅ Team trained on ClickHouse best practices
- ✅ Monitoring dashboards in place
- ✅ Runbook documented and tested
- ✅ Code review process includes ClickHouse checks

---

## 🎯 Final Summary

### The Core Problem
Hash-based partitioning on `deduped_observations_2` created 79,825 tiny parts (59 KiB average) because:
1. Data split 100 ways by hash function
2. Merges can't combine parts across partitions
3. Small inserts (88 rows) create tiny parts in each partition
4. Parts accumulate faster than merges can handle

### The Solution
1. **Remove hash partitioning** - Let all data merge together
2. **Improve insert batching** - Create larger parts from the start
3. **Monitor ongoing** - Prevent regression

### The Expected Outcome
- **79,825 parts → ~50-100 parts** (99.9% reduction)
- **59 KiB average → 200+ MiB average** (3,000x improvement)
- **Query performance: 10-100x faster**
- **Merge CPU: 90% reduction**
- **Stable, predictable performance**

### Timeline to Success
- **Week 1**: Fix critical tables
- **Week 2**: Optimize insert patterns
- **Week 3**: Monitor and validate
- **Week 4**: Document and train team

### Risk Assessment
- **Migration risk**: LOW (tested, idempotent, rollback ready)
- **Performance risk**: LOW (improvement guaranteed)
- **Data loss risk**: ZERO (old tables preserved until validated)
- **Downtime risk**: ZERO (online migration possible)

---

## 🚀 Ready to Execute?

You now have:
1. ✅ Complete understanding of the problem
2. ✅ Detailed migration scripts
3. ✅ Rollback procedures
4. ✅ Monitoring queries
5. ✅ Troubleshooting guide
6. ✅ Success criteria

**Next step**: Review with your team, then execute Priority 1 (deduped_observations_2 migration).

**Estimated time to healthy cluster**: 2 weeks

**Questions? Review the troubleshooting section or escalate per the support plan.**

Good luck! 🎉
