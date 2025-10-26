# Compression - Production Optimization Guide

**Last Updated**: October 2025  
**Cluster**: Single shard, 2 replicas, 3 ZK ensemble

---

## 🚨 When to Use This Guide

- Disk space running low (>80% used)
- High storage costs
- Poor query performance due to I/O overhead
- Tables growing faster than expected
- Compression ratio below expectations (<3:1)

---

## ⚡ Quick Assessment

**Check current compression ratios:**
```bash
./scripts/diagnostics/09-disk-space.sql
```

**Detailed compression analysis:**
```sql
SELECT
    database,
    table,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 3) AS compression_ratio,
    round(sum(bytes_on_disk) / sum(data_compressed_bytes), 3) AS overhead_ratio,
    sum(rows) AS total_rows,
    count() AS parts
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE active = 1
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 20;
```

**Good compression ratios:**
- Text/String data: 5:1 to 10:1
- Numeric data: 3:1 to 5:1
- Mixed data: 4:1 to 7:1

**Bad compression ratios (<2:1) indicate:**
- Wrong codec choice
- Already compressed data (images, encrypted data)
- High cardinality random data
- Poor column ordering

---

## 🔍 Compression Codecs in ClickHouse

### Default Codec: LZ4

**Characteristics:**
- Fast compression/decompression
- Moderate compression ratio (3-4:1)
- Best for general-purpose use
- Low CPU overhead

**When to use:** Default for most columns unless you have specific needs

---

### ZSTD (Zstandard)

**Characteristics:**
- Better compression than LZ4 (4-7:1)
- Configurable levels (1-22)
- Good balance of speed and compression
- ZSTD(1) ≈ LZ4 speed, ZSTD(3) is default

**When to use:**
- Tables with infrequent writes
- Long-term storage
- Large text/string columns
- When disk space is critical

**Example:**
```sql
CREATE TABLE database.table
(
    id UInt64,
    text String CODEC(ZSTD(3)),
    data String CODEC(ZSTD(1))
)
ENGINE = ReplicatedMergeTree()
ORDER BY id;
```

**Compression levels:**
- `ZSTD(1)` - Fast, moderate compression (~4:1)
- `ZSTD(3)` - Default, balanced (~5:1)
- `ZSTD(9)` - High compression, slower (~6-7:1)
- `ZSTD(19)` - Maximum compression, very slow (~8:1+)

---

### Delta Codec

**Characteristics:**
- Excellent for monotonic sequences
- Stores differences between consecutive values
- Best combined with another codec: `CODEC(Delta, LZ4)`
- 10:1+ compression for timestamps, IDs

**When to use:**
- Timestamp columns
- Sequential IDs
- Monotonically increasing/decreasing values
- Sensor data with gradual changes

**Example:**
```sql
CREATE TABLE sensor_data
(
    timestamp DateTime CODEC(Delta, LZ4),
    sensor_id UInt32 CODEC(Delta, ZSTD),
    temperature Float32 CODEC(Gorilla, LZ4),
    value Int64 CODEC(Delta, ZSTD)
)
ENGINE = ReplicatedMergeTree()
ORDER BY (sensor_id, timestamp);
```

---

### DoubleDelta Codec

**Characteristics:**
- For values that change at constant rate
- Stores delta of deltas
- Excellent for time-series with linear growth
- Best combined: `CODEC(DoubleDelta, LZ4)`

**When to use:**
- Counters that increment regularly
- Metrics that grow linearly
- Sequential data with predictable patterns

**Example:**
```sql
CREATE TABLE metrics
(
    timestamp DateTime CODEC(DoubleDelta, LZ4),
    counter UInt64 CODEC(DoubleDelta, ZSTD),
    metric_value Float64
)
ENGINE = ReplicatedMergeTree()
ORDER BY timestamp;
```

---

### Gorilla Codec

**Characteristics:**
- Designed for floating-point values
- Excellent for time-series metrics
- Best for values that change slowly
- Usually combined: `CODEC(Gorilla, LZ4)`

**When to use:**
- Float32/Float64 columns
- Temperature, pressure, or sensor readings
- Financial data with small incremental changes
- IoT/monitoring metrics

**Example:**
```sql
CREATE TABLE iot_metrics
(
    timestamp DateTime CODEC(Delta, LZ4),
    device_id UInt32,
    temperature Float32 CODEC(Gorilla, LZ4),
    humidity Float32 CODEC(Gorilla, LZ4),
    pressure Float64 CODEC(Gorilla, ZSTD)
)
ENGINE = ReplicatedMergeTree()
ORDER BY (device_id, timestamp);
```

---

### T64 Codec

**Characteristics:**
- For integer columns with many small values
- Packs 64-bit values into smaller bit widths
- Good for columns with limited range
- Combine with: `CODEC(T64, LZ4)`

**When to use:**
- Small integers stored as UInt64
- Boolean-like columns (0/1)
- Enum-like integer columns
- Status codes

**Example:**
```sql
CREATE TABLE events
(
    event_id UInt64,
    user_id UInt64,
    status_code UInt8 CODEC(T64, LZ4),
    priority UInt8 CODEC(T64, LZ4),
    timestamp DateTime
)
ENGINE = ReplicatedMergeTree()
ORDER BY (user_id, timestamp);
```

---

### LZ4HC (High Compression)

**Characteristics:**
- Better compression than LZ4
- Slower compression, same decompression speed
- Good for write-once, read-many scenarios

**When to use:**
- Archive tables
- Historical data
- Append-only tables

---

## 🔧 Optimization Procedures

### Procedure 1: Analyze Current Compression

**Step 1: Check compression by column**
```sql
SELECT
    database,
    table,
    name AS column_name,
    type AS column_type,
    compression_codec,
    formatReadableSize(data_compressed_bytes) AS compressed_size,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed_size,
    round(data_compressed_bytes / data_uncompressed_bytes, 3) AS compression_ratio
FROM system.columns
WHERE database = '<your_database>'
  AND table = '<your_table>'
  AND data_compressed_bytes > 0
ORDER BY data_compressed_bytes DESC;
```

**Step 2: Identify columns with poor compression**
```sql
-- Find columns with compression ratio > 0.5 (less than 2:1)
SELECT
    database,
    table,
    name AS column_name,
    type AS column_type,
    compression_codec,
    round(data_compressed_bytes / data_uncompressed_bytes, 3) AS compression_ratio
FROM system.columns
WHERE database = '<your_database>'
  AND data_compressed_bytes > 0
  AND (data_compressed_bytes / data_uncompressed_bytes) > 0.5
ORDER BY compression_ratio DESC;
```

**Step 3: Sample column data to understand patterns**
```sql
-- Check for monotonic sequences (good for Delta)
SELECT
    min(column_name) AS min_val,
    max(column_name) AS max_val,
    count(DISTINCT column_name) AS unique_values,
    count(*) AS total_rows,
    round(count(DISTINCT column_name) / count(*), 4) AS cardinality_ratio
FROM database.table
LIMIT 1;

-- Check if values are sequential
SELECT
    column_name,
    column_name - lagInFrame(column_name) OVER (ORDER BY column_name) AS delta
FROM database.table
ORDER BY column_name
LIMIT 100;
```

---

### Procedure 2: Create Optimized Table

**Step 1: Generate optimized CREATE statement**

```sql
-- Start with current table structure
SHOW CREATE TABLE database.table;
```

**Step 2: Modify with optimal codecs**

Example optimization:
```sql
CREATE TABLE database.table_optimized ON CLUSTER '{cluster}'
(
    -- Timestamps: Use Delta + LZ4
    timestamp DateTime CODEC(Delta, LZ4),
    created_at DateTime CODEC(Delta, LZ4),
    
    -- Sequential IDs: Use Delta + ZSTD
    id UInt64 CODEC(Delta, ZSTD),
    user_id UInt64 CODEC(Delta, ZSTD),
    
    -- Floats: Use Gorilla + LZ4
    amount Float64 CODEC(Gorilla, LZ4),
    price Float32 CODEC(Gorilla, LZ4),
    
    -- Text/Strings: Use ZSTD(3)
    description String CODEC(ZSTD(3)),
    metadata String CODEC(ZSTD(3)),
    
    -- Small integers: Use T64 + LZ4
    status UInt8 CODEC(T64, LZ4),
    priority UInt8 CODEC(T64, LZ4),
    
    -- Enums/Low cardinality: Use LowCardinality + ZSTD
    category LowCardinality(String) CODEC(ZSTD),
    country LowCardinality(String) CODEC(ZSTD)
)
ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (user_id, timestamp)
SETTINGS storage_policy = 'standardv2';
```

**Step 3: Migrate data**

See **Procedure 3: Migrate to Optimized Table** below

---

### Procedure 3: Migrate to Optimized Table

**⚠️ WARNING:** This involves table recreation. Test in dev first!

**Option A: CREATE AS SELECT (simple, downtime)**

```sql
-- 1. Create optimized table
CREATE TABLE database.table_new ON CLUSTER '{cluster}'
(
    -- columns with optimized codecs
)
ENGINE = ReplicatedMergeTree()
ORDER BY ...;

-- 2. Copy data (this may take time!)
INSERT INTO database.table_new 
SELECT * FROM database.table;

-- 3. Verify row counts match
SELECT 
    (SELECT count(*) FROM database.table) AS old_count,
    (SELECT count(*) FROM database.table_new) AS new_count,
    old_count = new_count AS match;

-- 4. Rename tables (atomic)
RENAME TABLE database.table TO database.table_old,
             database.table_new TO database.table
ON CLUSTER '{cluster}';

-- 5. Drop old table after verification
DROP TABLE database.table_old ON CLUSTER '{cluster}';
```

**Option B: ALTER TABLE MODIFY COLUMN (in-place, slower)**

```sql
-- Modify individual columns (causes mutations)
ALTER TABLE database.table ON CLUSTER '{cluster}'
MODIFY COLUMN timestamp DateTime CODEC(Delta, LZ4);

ALTER TABLE database.table ON CLUSTER '{cluster}'
MODIFY COLUMN description String CODEC(ZSTD(3));

-- Monitor mutation progress
SELECT
    database,
    table,
    mutation_id,
    command,
    parts_to_do,
    is_done,
    latest_fail_reason
FROM system.mutations
WHERE database = 'database'
  AND table = 'table'
  AND is_done = 0;
```

**Pros/Cons:**

| Method | Pros | Cons |
|--------|------|------|
| CREATE AS SELECT | Fast, clean, testable | Requires downtime, 2x storage temporarily |
| ALTER MODIFY | No downtime, gradual | Slow, mutations can fail, parts rewritten over time |

---

### Procedure 4: Force Recompression of Existing Data

**When to use:** After changing default codec, want immediate recompression

```sql
-- Force merge and recompress all parts
OPTIMIZE TABLE database.table FINAL;

-- Or per partition (less aggressive)
OPTIMIZE TABLE database.table PARTITION '202410';
```

**⚠️ WARNING:** 
- `OPTIMIZE FINAL` is resource-intensive
- Blocks other merges
- Can take hours for large tables
- Run during low-traffic periods

**Monitor progress:**
```sql
-- Check active merges
SELECT
    database,
    table,
    elapsed,
    progress,
    formatReadableSize(total_size_bytes_compressed) AS merge_size
FROM system.merges
WHERE database = 'database' 
  AND table = 'table';
```

---

## 🎯 Best Practices

### 1. Compression Codec Selection Guide

| Data Type | Pattern | Recommended Codec | Expected Ratio |
|-----------|---------|-------------------|----------------|
| DateTime | Timestamps | `Delta, LZ4` | 10:1 |
| UInt64 | Sequential IDs | `Delta, ZSTD` | 8:1 |
| Float32/64 | Metrics/sensors | `Gorilla, LZ4` | 5:1 |
| String | Text/descriptions | `ZSTD(3)` | 6:1 |
| String | JSON/logs | `ZSTD(5)` | 8:1 |
| UInt8 | Status codes | `T64, LZ4` | 4:1 |
| Enum/Category | Low cardinality | `LowCardinality + ZSTD` | 10:1+ |
| UInt64 | Counter (linear) | `DoubleDelta, LZ4` | 12:1 |

### 2. ORDER BY Optimization for Compression

**Bad ordering (hurts compression):**
```sql
-- Random ordering, poor locality
ORDER BY (random_id, timestamp)
```

**Good ordering (helps compression):**
```sql
-- Group similar data together
ORDER BY (user_id, toYYYYMMDD(timestamp), event_type)
```

**Why:** Similar values clustered together compress better

### 3. LowCardinality for Enum-Like Columns

**Before:**
```sql
country String  -- Poor compression if limited values
```

**After:**
```sql
country LowCardinality(String)  -- Dictionary encoding, 10x better
```

**When to use:**
- Column has < 10,000 unique values
- High repetition (e.g., countries, categories, status codes)
- Read performance is critical

**When NOT to use:**
- High cardinality (> 100,000 unique values)
- Unique or near-unique values (IDs, emails)

### 4. Partition Strategy Impacts Compression

**Smaller partitions = Better compression**

```sql
-- Poor: Large partitions, diverse data
PARTITION BY toYear(timestamp)

-- Better: Monthly partitions
PARTITION BY toYYYYMM(timestamp)

-- Best for compression (but more parts to manage)
PARTITION BY toYYYYMMDD(timestamp)
```

Trade-off: More partitions = more parts = higher merge overhead

### 5. Monitor Compression After Changes

```sql
-- Check compression improvements over time
SELECT
    toDate(min_date) AS date,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(bytes_on_disk)) AS disk,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 3) AS ratio
FROM system.parts
WHERE database = 'database'
  AND table = 'table'
  AND active = 1
GROUP BY toDate(min_date)
ORDER BY date DESC
LIMIT 30;
```

---

## 📊 Diagnostic Queries

### Query 1: Compression Comparison Between Tables

```sql
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 2) AS compression_ratio,
    count() AS parts,
    sum(rows) AS total_rows
FROM system.parts
WHERE database = 'your_database'
  AND active = 1
GROUP BY table
ORDER BY sum(bytes_on_disk) DESC;
```

### Query 2: Worst Compressing Columns

```sql
SELECT
    database,
    table,
    name AS column,
    type,
    compression_codec,
    formatReadableSize(data_compressed_bytes) AS compressed,
    round(data_compressed_bytes / data_uncompressed_bytes, 3) AS ratio,
    round((data_compressed_bytes / data_uncompressed_bytes - 0.2) * 100) AS savings_potential_pct
FROM system.columns
WHERE database = 'your_database'
  AND data_compressed_bytes > 1024 * 1024  -- > 1MB
  AND (data_compressed_bytes / data_uncompressed_bytes) > 0.3  -- < 3:1
ORDER BY data_compressed_bytes DESC
LIMIT 20;
```

### Query 3: Compression by Partition Age

```sql
SELECT
    partition,
    toDate(min(min_date)) AS partition_date,
    count() AS parts,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 2) AS compression_ratio
FROM system.parts
WHERE database = 'database'
  AND table = 'table'
  AND active = 1
GROUP BY partition
ORDER BY partition DESC
LIMIT 12;
```

**Insight:** Older partitions may have better compression due to more merges

### Query 4: Storage Savings Potential

```sql
-- Estimate savings if compression improved from 3:1 to 6:1
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS current_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 2) AS current_ratio,
    formatReadableSize(sum(bytes_on_disk) * 0.5) AS potential_size_6to1,
    formatReadableSize(sum(bytes_on_disk) - sum(bytes_on_disk) * 0.5) AS potential_savings
FROM system.parts
WHERE active = 1
GROUP BY database, table
HAVING sum(bytes_on_disk) > 1024 * 1024 * 1024  -- > 1GB
ORDER BY sum(bytes_on_disk) DESC;
```

---

## 🚀 Real-World Example

### Scenario: Optimizing a Time-Series Table

**Before (default codecs):**
```sql
CREATE TABLE metrics
(
    timestamp DateTime,
    device_id UInt64,
    metric_name String,
    value Float64,
    status UInt8,
    tags String
)
ENGINE = ReplicatedMergeTree()
ORDER BY (device_id, timestamp);

-- Compression: 3.2:1, 500GB on disk
```

**Analysis:**
```sql
SELECT
    name,
    type,
    compression_codec,
    formatReadableSize(data_compressed_bytes) AS compressed,
    round(data_compressed_bytes / data_uncompressed_bytes, 3) AS ratio
FROM system.columns
WHERE database = 'db' AND table = 'metrics'
ORDER BY data_compressed_bytes DESC;
```

**Results:**
- `timestamp`: Default, ratio 3.1:1
- `device_id`: Default, ratio 2.8:1
- `metric_name`: Default, ratio 4.2:1
- `value`: Default, ratio 2.5:1 (Float64, poor)
- `tags`: Default, ratio 3.8:1 (JSON strings)

**After (optimized):**
```sql
CREATE TABLE metrics_v2
(
    timestamp DateTime CODEC(Delta, LZ4),          -- 10:1
    device_id UInt64 CODEC(Delta, ZSTD),           -- 8:1
    metric_name LowCardinality(String) CODEC(ZSTD), -- 15:1
    value Float64 CODEC(Gorilla, LZ4),             -- 5:1
    status UInt8 CODEC(T64, LZ4),                  -- 8:1
    tags String CODEC(ZSTD(5))                     -- 7:1
)
ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (device_id, timestamp);

-- Result: 6.8:1 compression, 235GB on disk
-- Savings: 265GB (53% reduction)
```

---

## 🔗 Related Documentation

- [Readonly Tables](readonly-tables.md) - May need recovery after compression changes
- [Detached Parts](detached-parts.md) - Handle mutations that fail
- [ClickHouse Compression Codecs](https://clickhouse.com/docs/en/sql-reference/statements/create/table#column-compression-codecs)
- [System Tables: columns](https://clickhouse.com/docs/en/operations/system-tables/columns)

---

## 📋 Related Scripts

| Script | Purpose |
|--------|---------|
| `09-disk-space.sql` | Check disk usage and compression ratios |
| `05-merge-backlog.sql` | Monitor merges after OPTIMIZE |
| `04-stuck-mutations.sql` | Track ALTER MODIFY mutations |

---

**Document Version**: 1.0  
**Maintained By**: DBRE Team
