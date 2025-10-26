# Too Many Parts - Production Troubleshooting

**Last Updated**: October 2025  
**Cluster**: Single shard, 2 replicas, 3 ZK ensemble

---

## 🚨 Symptoms

- Error: `TOO_MANY_PARTS` (Code 252)
- Queries getting slower over time
- High disk I/O usage
- `SELECT` queries scanning many small parts
- Inserts taking longer than usual
- System.parts shows >300 parts for a table

---

## ⚡ Quick Diagnosis

**Check parts count:**
```bash
./scripts/diagnostics/05-merge-backlog.sql
```

**Emergency query:**
```sql
SELECT
    database,
    table,
    count() AS active_parts,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE active = 1
GROUP BY database, table
HAVING active_parts > 200
ORDER BY active_parts DESC;
```

**Severity levels:**
- **< 100 parts**: Healthy
- **100-300 parts**: Monitor
- **300-500 parts**: Warning - investigate
- **500-1000 parts**: Critical - act now
- **> 1000 parts**: Emergency - queries will fail

---

## 🔍 Why Too Many Parts Is Bad

### Performance Impact

**Each SELECT query must:**
1. Open metadata for every part
2. Read index from each part
3. Merge results from all parts
4. More parts = more I/O = slower queries

**Example:**
- 10 parts: Query takes 100ms
- 100 parts: Query takes 500ms
- 1000 parts: Query takes 5000ms (50x slower!)

### ClickHouse Limits

**Default limit**: 300 parts per partition (configurable)

**Error when exceeded:**
```
DB::Exception: Too many parts (301). 
Merges are processing significantly slower than inserts.
```

---

## 🔍 Root Causes

### 1. High Insert Rate (Most Common)

**Problem**: Inserting data too frequently in small batches

**Bad pattern:**
```python
# ❌ WRONG: 1000 inserts/second, 1 row each
for row in data:
    client.insert('table', [row])  # Creates 1000 parts!
```

**Good pattern:**
```python
# ✅ CORRECT: Batch every 1 second, 1000 rows each
batch = []
for row in data:
    batch.append(row)
    if len(batch) >= 1000:
        client.insert('table', batch)  # Creates 1 part
        batch = []
```

**Check insert frequency:**
```sql
SELECT
    toStartOfMinute(event_time) AS minute,
    count() AS insert_operations,
    sum(read_rows) AS total_rows_inserted,
    round(sum(read_rows) / count()) AS avg_rows_per_insert
FROM clusterAllReplicas('{cluster}', system, query_log)
WHERE event_time >= now() - INTERVAL 1 HOUR
  AND type = 'QueryFinish'
  AND query_kind = 'Insert'
  AND database = '<your_database>'
  AND arrayJoin(tables) = '<your_table>'
GROUP BY minute
ORDER BY minute DESC
LIMIT 60;
```

**Ideal**: 
- Insert every 1-10 seconds
- 10,000-100,000 rows per insert
- Results in 1-2 parts per minute

---

### 2. Merges Can't Keep Up

**Problem**: Background merges are slower than insert rate

**Check merge activity:**
```bash
./scripts/diagnostics/06-active-merges.sql
```

**Reasons merges slow down:**
- High disk I/O contention
- CPU bottleneck
- Large parts taking time to merge
- Too many concurrent merges
- Insufficient merge threads

**Check merge settings:**
```sql
SELECT
    name,
    value
FROM system.merge_tree_settings
WHERE name IN (
    'max_bytes_to_merge_at_max_space_usage',
    'max_bytes_to_merge_at_min_space_in_pool',
    'number_of_free_entries_in_pool_to_lower_max_size_of_merge'
);
```

---

### 3. Small Insert Batches

**Problem**: Each insert creates one part, regardless of size

**Check part sizes:**
```sql
SELECT
    database,
    table,
    partition,
    count() AS small_parts,
    round(avg(rows)) AS avg_rows_per_part,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE active = 1
  AND rows < 10000  -- Parts with < 10k rows
GROUP BY database, table, partition
HAVING small_parts > 10
ORDER BY small_parts DESC
LIMIT 20;
```

**Ideal part size**: 100,000 - 1,000,000 rows per part

---

### 4. Frequent Partitions

**Problem**: Too many partitions = parts spread across many directories

**Bad partitioning:**
```sql
-- ❌ Creates 365 partitions per year
PARTITION BY toYYYYMMDD(timestamp)

-- ❌ Creates partition per hour
PARTITION BY toStartOfHour(timestamp)
```

**Good partitioning:**
```sql
-- ✅ Creates 12 partitions per year
PARTITION BY toYYYYMM(timestamp)

-- ✅ Or no partitioning for small tables
-- (omit PARTITION BY clause)
```

**Check partition count:**
```sql
SELECT
    database,
    table,
    count(DISTINCT partition) AS partition_count,
    count() AS total_parts,
    round(count() / count(DISTINCT partition)) AS avg_parts_per_partition
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE active = 1
GROUP BY database, table
HAVING partition_count > 100
ORDER BY partition_count DESC;
```

---

### 5. Mutations Blocking Merges

**Problem**: ALTER/UPDATE/DELETE operations prevent merges

**Check stuck mutations:**
```bash
./scripts/diagnostics/04-stuck-mutations.sql
```

**Mutations block merges because:**
- Parts being mutated can't be merged
- New parts wait for mutations to finish
- Long mutations = accumulating parts

---

### 6. Insufficient System Resources

**Problem**: System too busy to merge fast enough

**Check resource usage:**
```sql
-- CPU usage
SELECT *
FROM system.asynchronous_metrics
WHERE metric LIKE '%CPU%';

-- Disk I/O
SELECT
    formatReadableSize(value) AS value,
    metric
FROM system.asynchronous_metrics
WHERE metric IN ('BlockReadBytes', 'BlockWriteBytes');

-- Background pool usage
SELECT *
FROM system.metrics
WHERE metric LIKE '%BackgroundPool%';
```

---

## 🔧 Recovery Procedures

### Procedure 1: Force Immediate Merge (Quick Fix)

**Use when**: Need immediate relief, table <100GB

```sql
-- Force merge all parts in table
OPTIMIZE TABLE database.table FINAL;
```

**⚠️ WARNING**:
- Blocks other operations
- High I/O and CPU usage
- Can take minutes to hours
- Use during low-traffic periods

**Better approach (per partition):**
```sql
-- Merge one partition at a time
OPTIMIZE TABLE database.table PARTITION '202410' FINAL;
OPTIMIZE TABLE database.table PARTITION '202411' FINAL;
```

**Monitor progress:**
```sql
-- Check merge activity
SELECT
    database,
    table,
    elapsed,
    progress,
    formatReadableSize(total_size_bytes_compressed) AS size
FROM system.merges
WHERE database = '<database>' AND table = '<table>';

-- Check part count decreasing
SELECT count() AS parts
FROM system.parts
WHERE database = '<database>'
  AND table = '<table>'
  AND active = 1;
```

---

### Procedure 2: Adjust Merge Settings (Long-term Fix)

**Step 1: Increase merge aggressiveness**

```sql
-- Allow larger merges
ALTER TABLE database.table 
MODIFY SETTING max_bytes_to_merge_at_max_space_usage = 161061273600;  -- 150GB

-- Merge more frequently
ALTER TABLE database.table 
MODIFY SETTING merge_with_ttl_timeout = 3600;  -- 1 hour
```

**Step 2: Increase background pool size (server-wide)**

Add to `config.xml`:
```xml
<clickhouse>
    <merge_tree>
        <max_part_loading_threads>16</max_part_loading_threads>
        <max_part_removal_threads>16</max_part_removal_threads>
        <max_bytes_to_merge_at_max_space_usage>161061273600</max_bytes_to_merge_at_max_space_usage>
    </merge_tree>
    <background_pool_size>32</background_pool_size>
    <background_schedule_pool_size>32</background_schedule_pool_size>
</clickhouse>
```

**Step 3: Restart ClickHouse**
```bash
kubectl rollout restart statefulset/<statefulset-name> -n <namespace>
```

---

### Procedure 3: Fix Application Insert Pattern

**Step 1: Identify insert pattern**
```sql
SELECT
    user,
    count() AS insert_count,
    round(sum(read_rows) / count()) AS avg_rows_per_insert,
    min(read_rows) AS min_rows,
    max(read_rows) AS max_rows
FROM clusterAllReplicas('{cluster}', system, query_log)
WHERE event_time >= now() - INTERVAL 1 HOUR
  AND type = 'QueryFinish'
  AND query_kind = 'Insert'
  AND arrayJoin(tables) = '<table>'
GROUP BY user
ORDER BY insert_count DESC;
```

**Step 2: Implement batching in application**

**Python example:**
```python
from clickhouse_driver import Client
import time

client = Client('host')
batch = []
batch_size = 10000
last_insert = time.time()

def flush_batch():
    global batch, last_insert
    if batch:
        client.execute('INSERT INTO table VALUES', batch)
        print(f"Inserted {len(batch)} rows")
        batch = []
        last_insert = time.time()

for row in data_stream:
    batch.append(row)
    
    # Flush on size or time
    if len(batch) >= batch_size or (time.time() - last_insert) > 10:
        flush_batch()

# Flush remaining
flush_batch()
```

**Step 3: Use async_insert (ClickHouse 21.11+)**

```sql
-- Enable async inserts
SET async_insert = 1;
SET wait_for_async_insert = 0;
SET async_insert_max_data_size = 10000000;  -- 10MB
SET async_insert_busy_timeout_ms = 1000;    -- 1 second

-- Now inserts are automatically batched
INSERT INTO table VALUES (1, 'data');
INSERT INTO table VALUES (2, 'data');
-- These are batched together by ClickHouse
```

---

### Procedure 4: Reduce Partition Granularity

**Step 1: Analyze current partitioning**
```sql
SELECT
    partition,
    count() AS parts,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    sum(rows) AS rows
FROM system.parts
WHERE database = '<database>'
  AND table = '<table>'
  AND active = 1
GROUP BY partition
ORDER BY partition DESC
LIMIT 30;
```

**Step 2: Create new table with better partitioning**
```sql
-- Old: Daily partitions
CREATE TABLE old_table
(
    timestamp DateTime,
    data String
)
PARTITION BY toYYYYMMDD(timestamp);  -- ❌ Too granular

-- New: Monthly partitions
CREATE TABLE new_table
(
    timestamp DateTime,
    data String
)
PARTITION BY toYYYYMM(timestamp);  -- ✅ Better
```

**Step 3: Migrate data**
```sql
-- Copy data
INSERT INTO new_table SELECT * FROM old_table;

-- Rename tables
RENAME TABLE old_table TO old_table_backup,
             new_table TO old_table
ON CLUSTER '{cluster}';
```

---

### Procedure 5: Emergency - Detach Old Partitions

**Use when**: Cluster critically overloaded, need immediate relief

```sql
-- Find old partitions
SELECT
    partition,
    count() AS parts,
    max(modification_time) AS last_modified
FROM system.parts
WHERE database = '<database>'
  AND table = '<table>'
  AND active = 1
GROUP BY partition
HAVING last_modified < now() - INTERVAL 90 DAY
ORDER BY partition;

-- Detach old partitions (moves to detached/ directory)
ALTER TABLE database.table 
DETACH PARTITION '202401';

ALTER TABLE database.table 
DETACH PARTITION '202402';
```

**Later, reattach or drop:**
```sql
-- Reattach if needed
ALTER TABLE database.table ATTACH PARTITION '202401';

-- Or drop permanently
ALTER TABLE database.table DROP DETACHED PARTITION '202401';
```

---

## 🎯 Prevention Strategies

### 1. Batch Inserts Properly

**Guidelines:**
- Batch size: 10,000 - 100,000 rows
- Frequency: Every 1-10 seconds
- Use async_insert in ClickHouse 21.11+

### 2. Monitor Part Counts

**Set up alert:**
```sql
-- Alert when parts > 300
SELECT
    database,
    table,
    count() AS parts
FROM system.parts
WHERE active = 1
GROUP BY database, table
HAVING parts > 300;
```
