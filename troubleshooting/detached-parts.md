# Detached Parts - Production Troubleshooting

**Last Updated**: October 2025  
**Cluster**: Single shard, 2 replicas, 3 ZK ensemble

---

## 🚨 Symptoms

- Row count mismatch between replicas
- Queries returning incomplete data
- Parts visible in `system.detached_parts`
- Errors mentioning "Part ... is not found on disk"
- Replication queue errors about missing parts

---

## ⚡ Quick Diagnosis

**Check for detached parts:**
```sql
SELECT
    hostName() AS host,
    database,
    table,
    count(*) AS detached_count,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM clusterAllReplicas('{cluster}', system, detached_parts)
GROUP BY host, database, table
ORDER BY detached_count DESC;
```

**Detailed view:**
```sql
SELECT
    hostName() AS host,
    database,
    table,
    name AS part_name,
    reason,
    min_block_number,
    max_block_number,
    level,
    disk
FROM clusterAllReplicas('{cluster}', system, detached_parts)
ORDER BY database, table, min_block_number;
```

---

## 🔍 Common Causes

### 1. Manual DETACH Operations

**How it happens:**
```sql
-- Someone ran this on one replica only
ALTER TABLE database.table DETACH PARTITION 'partition_id';
```

**Result:** Part moved to `detached/` directory, data missing from queries

---

### 2. Corrupted Parts (Automatic Detach)

**ClickHouse automatically detaches parts when:**
- Checksum verification fails
- Part files are corrupted on disk
- Filesystem errors during read/write
- Memory corruption during merge

**Check logs for:**
```
Code: 395. DB::Exception: Checksum doesn't match
Code: 107. DB::Exception: Cannot read all data
```

**Verify in replication queue:**
```sql
SELECT
    database,
    table,
    type,
    last_exception,
    num_tries,
    postpone_reason
FROM system.replication_queue
WHERE last_exception LIKE '%Checksum%'
   OR last_exception LIKE '%corrupted%'
ORDER BY create_time;
```

---

### 3. Failed Merges

**Symptoms:**
- Multiple parts detached after merge operation
- Errors in merge logs
- High merge backlog

**Check active merges:**
```bash
./scripts/diagnostics/06-active-merges.sql
```

**Check for failed merges in logs:**
```bash
kubectl logs -n <namespace> <pod-name> | grep -i "merge.*error"
```

---

### 4. Disk Issues

**Causes:**
- Disk full during write
- I/O errors
- Filesystem corruption
- Disk removed/unmounted

**Check disk health:**
```bash
./scripts/diagnostics/09-disk-space.sql
```

**From inside pod:**
```bash
kubectl exec -it <pod-name> -n <namespace> -- df -h
kubectl exec -it <pod-name> -n <namespace> -- dmesg | tail -50
```

---

### 5. Replication Failures

**Parts detached because replica couldn't fetch from other replica:**
- Network issues between replicas
- Source replica went down during fetch
- ZooKeeper metadata inconsistency

**Check replication health:**
```bash
./scripts/diagnostics/03-replication-health.sql
```

---

## 🔧 Recovery Procedures

### Procedure 1: Re-attach Healthy Parts

**Use when:** Parts were detached manually or by mistake, and are not corrupted

**Step 1: Verify parts are on disk**
```bash
kubectl exec -it <pod-name> -n <namespace> -- bash

# Navigate to table directory
cd /var/lib/clickhouse/data/<database>/<table>/

# Check detached directory
ls -lh detached/

# Verify part structure (should have columns.txt, checksums.txt, etc.)
ls detached/<part_name>/
```

**Step 2: Identify parts to reattach**
```sql
-- Get list of detached parts with reasons
SELECT
    name AS part_name,
    reason,
    min_block_number,
    max_block_number,
    disk,
    concat(
        'ALTER TABLE ',
        database,
        '.',
        table,
        ' ATTACH PART \'',
        name,
        '\''
    ) AS attach_command
FROM system.detached_parts
WHERE database = '<your_database>'
  AND table = '<your_table>'
ORDER BY min_block_number;
```

**Step 3: Attach parts**
```sql
-- Attach single part
ALTER TABLE database.table ATTACH PART 'part_name';

-- Or attach entire partition
ALTER TABLE database.table ATTACH PARTITION 'partition_id';
```

**Step 4: Verify attachment**
```sql
-- Check if parts are now active
SELECT
    partition,
    name,
    rows,
    formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE database = '<database>'
  AND table = '<table>'
  AND name = '<part_name>'
  AND active = 1;

-- Verify row counts match across replicas
SELECT 
    hostName() AS host,
    count(*) AS row_count
FROM clusterAllReplicas('{cluster}', database, table)
GROUP BY hostName();
```

---

### Procedure 2: Drop Corrupted Parts

**Use when:** Parts are confirmed corrupted and cannot be recovered

**Step 1: Identify corrupted parts**
```sql
-- Check detach reason
SELECT
    name,
    reason,
    min_block_number,
    max_block_number
FROM system.detached_parts
WHERE database = '<database>'
  AND table = '<table>'
  AND reason LIKE '%Checksum%';
```

**Step 2: Verify other replica has data**
```sql
-- Check if healthy replica has overlapping data range
SELECT
    hostName() AS host,
    name,
    partition,
    min_block_number,
    max_block_number,
    rows
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE database = '<database>'
  AND table = '<table>'
  AND active = 1
  AND min_block_number <= <corrupted_max_block>
  AND max_block_number >= <corrupted_min_block>
ORDER BY host, min_block_number;
```

**Step 3: Drop detached part**
```sql
-- Drop single part
ALTER TABLE database.table 
DROP DETACHED PART 'part_name';

-- Or drop all detached parts for a partition
ALTER TABLE database.table 
DROP DETACHED PARTITION 'partition_id';
```

**Step 4: Force refetch from healthy replica**
```sql
-- ClickHouse will automatically refetch missing data blocks
-- You can monitor replication queue
SELECT
    type,
    create_time,
    new_part_name,
    source_replica
FROM system.replication_queue
WHERE database = '<database>'
  AND table = '<table>'
ORDER BY create_time DESC
LIMIT 10;
```

---

### Procedure 3: SYSTEM RESTORE REPLICA (Nuclear Option)

**Use when:** Many parts corrupted, or replication is completely broken

**⚠️ WARNING:** Drops ALL local data and refetches from healthy replica

**Step 1: Verify other replica is healthy**
```sql
SELECT
    hostName() AS host,
    is_readonly,
    is_leader,
    total_replicas,
    active_replicas,
    absolute_delay
FROM clusterAllReplicas('{cluster}', system, replicas)
WHERE database = '<database>'
  AND table = '<table>';
```

**Expected:** At least one replica with `is_readonly = 0` and `is_leader = 1`

**Step 2: Execute on BROKEN replica only**
```sql
-- This will drop all local parts and refetch
SYSTEM RESTORE REPLICA database.table;
```

**Step 3: Monitor progress**
```sql
-- Watch replication queue
SELECT
    type,
    num_tries,
    last_attempt_time,
    new_part_name,
    formatReadableSize(bytes_to_download) AS download_size
FROM system.replication_queue
WHERE database = '<database>'
  AND table = '<table>'
ORDER BY create_time;

-- Check parts being created
SELECT count(*) AS active_parts
FROM system.parts
WHERE database = '<database>'
  AND table = '<table>'
  AND active = 1;
```

**Expected duration:** 5-30 minutes depending on table size

---

### Procedure 4: Manual Part Recovery from Filesystem

**Use when:** Parts exist on disk but not in metadata

**Step 1: Find parts on disk**
```bash
kubectl exec -it <pod-name> -n <namespace> -- bash

cd /var/lib/clickhouse/data/<database>/<table>/

# Check detached directory
ls -lh detached/

# Check for orphaned parts in main directory
ls -lh | grep -v detached
```

**Step 2: Move parts to detached (if needed)**
```bash
# If parts are orphaned in main directory
mv <orphaned_part> detached/
```

**Step 3: Attempt ATTACH**
```sql
ALTER TABLE database.table ATTACH PART 'part_name';
```

**If ATTACH fails with checksum error:**
```sql
-- Drop the corrupted part
ALTER TABLE database.table DROP DETACHED PART 'part_name';

-- Let replication fetch from healthy replica
```

---

## 🎯 Prevention

### 1. Always Use ON CLUSTER
```sql
-- ✅ CORRECT: Operates on all replicas
ALTER TABLE database.table ON CLUSTER '{cluster}' 
DROP PARTITION 'old_partition';

-- ❌ WRONG: Only affects one replica
ALTER TABLE database.table 
DROP PARTITION 'old_partition';
```

### 2. Monitor Detached Parts
```sql
-- Set up alert when detached parts > 0
SELECT
    hostName(),
    database,
    table,
    count(*) AS detached_count
FROM clusterAllReplicas('{cluster}', system, detached_parts)
GROUP BY hostName(), database, table
HAVING detached_count > 0;
```

**New Relic alert:**
```nrql
FROM Log 
SELECT count(*) 
WHERE cluster_name = 'platform-v2-demo-us-east-1' 
  AND namespace_name = 'clickhouse-operator'
  AND message LIKE '%detached parts%'
```

### 3. Regular Disk Health Checks
```sql
-- Check disk space weekly
SELECT
    hostName(),
    name AS disk,
    formatReadableSize(free_space) AS free,
    round((total_space - free_space) / total_space * 100, 1) AS used_pct
FROM clusterAllReplicas('{cluster}', system, disks)
WHERE used_pct > 70;
```

### 4. Enable Part Verification
```xml
<!-- In config.xml -->
<clickhouse>
    <merge_tree>
        <check_sample_column_is_correct>1</check_sample_column_is_correct>
        <min_bytes_to_fsync_after_merge>0</min_bytes_to_fsync_after_merge>
    </merge_tree>
</clickhouse>
```

### 5. Backup Before Major Operations
```sql
-- Before dropping partitions or running mutations
-- Take snapshot or backup
CREATE TABLE database.table_backup AS database.table;

-- Or use clickhouse-backup tool
```

---

## 📊 Diagnostic Queries

### Row Count Comparison
```sql
-- Compare actual rows vs parts metadata
SELECT
    hostName() AS host,
    count(*) AS table_rows,
    (SELECT sum(rows) 
     FROM clusterAllReplicas('{cluster}', system, parts) 
     WHERE database = '<db>' AND table = '<table>' AND active = 1) AS parts_rows
FROM clusterAllReplicas('{cluster}', <database>, <table>)
GROUP BY hostName();
```

### Part Distribution by Replica
```sql
SELECT
    hostName() AS host,
    partition,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE database = '<database>'
  AND table = '<table>'
  AND active = 1
GROUP BY hostName(), partition
ORDER BY partition, host;
```

### Missing Data Blocks Detection
```sql
-- Find gaps in block numbers (indicates missing parts)
SELECT
    partition,
    min_block_number AS block_start,
    max_block_number AS block_end,
    max_block_number - min_block_number + 1 AS expected_blocks,
    count() AS actual_parts
FROM system.parts
WHERE database = '<database>'
  AND table = '<table>'
  AND active = 1
GROUP BY partition, min_block_number, max_block_number
HAVING actual_parts < expected_blocks
ORDER BY partition, block_start;
```

### Detached Parts Summary
```sql
SELECT
    database,
    table,
    reason,
    count() AS part_count,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    min(min_block_number) AS earliest_block,
    max(max_block_number) AS latest_block
FROM system.detached_parts
GROUP BY database, table, reason
ORDER BY part_count DESC;
```

---

## 🧪 Testing

**Safe testing in dev/staging:**

See **[detached-parts-testing.md](detached-parts-testing.md)**

---

## 📚 Common Scenarios & Solutions

| Scenario | Cause | Solution |
|----------|-------|----------|
| Single part detached after insert | Checksum error during write | Drop detached, refetch from replica |
| Many parts detached after merge | Merge failed, disk full | Free disk space, drop detached, optimize |
| Partition missing on one replica | Manual DETACH without ON CLUSTER | ATTACH PARTITION on affected replica |
| Parts detached with "broken" reason | Filesystem corruption | SYSTEM RESTORE REPLICA |
| Detached on both replicas | Simultaneous corruption (rare) | Restore from backup |
| Parts accumulating in detached/ | No one monitoring/cleaning | Set up alerts, implement cleanup job |

---

## 🔗 Related Documentation

- [Readonly Tables](readonly-tables.md) - May cause parts to detach
- [Compression](compression.md) - Optimize storage after recovery
- [System Tables: detached_parts](https://clickhouse.com/docs/en/operations/system-tables/detached-parts)
- [System Tables: parts](https://clickhouse.com/docs/en/operations/system-tables/parts)

---

## 📋 Related Scripts

| Script | Purpose |
|--------|---------|
| `03-replication-health.sql` | Check replica sync status |
| `05-merge-backlog.sql` | Check for too many parts |
| `09-disk-space.sql` | Verify disk availability |

---

**Document Version**: 1.0  
**Maintained By**: DBRE Team
