# Detached Parts - Testing & Validation Guide

**Purpose**: Test detached parts scenarios and recovery procedures  
**Cluster**: `platform-v2-demo-us-east-1`  
**Namespace**: `ch-observations-nvme`

---

## ⚠️ SAFETY WARNING

**NEVER run these tests in production!**

These procedures intentionally detach data to test monitoring and recovery.

**Requirements:**
- Dev or staging environment only
- Test table with non-critical data
- Ability to restart pods if needed
- Monitoring configured

---

## Test Setup

### Create Test Table

```sql
CREATE TABLE ssc_dbre.test_detached ON CLUSTER '{cluster}'
(
    `id` Int32,
    `partition_date` Date,
    `value` String,
    `created_at` DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}')
PARTITION BY toYYYYMM(partition_date)
ORDER BY (partition_date, id)
SETTINGS storage_policy = 'standardv2', index_granularity = 8192;
```

### Insert Multi-Partition Data

```sql
-- Insert data spanning 3 months
INSERT INTO ssc_dbre.test_detached 
SELECT 
    number AS id,
    toDate('2024-10-01') + INTERVAL (number % 90) DAY AS partition_date,
    concat('value_', toString(number)) AS value,
    now() - INTERVAL number SECOND AS created_at
FROM numbers(10000);
```

### Verify Initial State

```sql
-- Check partitions created
SELECT
    hostName() AS host,
    partition,
    count() AS parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE database = 'ssc_dbre'
  AND table = 'test_detached'
  AND active = 1
GROUP BY host, partition
ORDER BY partition, host;
```

**Expected:** 3 partitions (202410, 202411, 202412) on both replicas

### Check for Any Existing Detached Parts

```sql
SELECT count(*) AS detached_count
FROM clusterAllReplicas('{cluster}', system, detached_parts)
WHERE database = 'ssc_dbre'
  AND table = 'test_detached';
```

**Expected:** 0 (no detached parts yet)

---

## Test Scenario 1: Manual Partition Detach

**Simulates:** Operator detaching partition on one replica only

### Execute Test

**Connect to replica 0-1 ONLY:**
```bash
kubectl exec -n ch-observations-nvme -it \
  chi-ch-observations-nvme-observations-ls-0-1-0 -- clickhouse-client
```

**Detach a partition:**
```sql
-- Detach October partition
ALTER TABLE ssc_dbre.test_detached 
DETACH PARTITION '202410';
```

### Verify Detachment

**Check detached parts:**
```sql
SELECT
    hostName() AS host,
    name AS part_name,
    reason,
    partition_id,
    min_block_number,
    max_block_number,
    disk
FROM clusterAllReplicas('{cluster}', system, detached_parts)
WHERE database = 'ssc_dbre'
  AND table = 'test_detached';
```

**Expected:** Multiple parts from partition 202410 on replica 0-1 only

**Check row count mismatch:**
```sql
SELECT 
    hostName() AS host,
    count(*) AS row_count
FROM clusterAllReplicas('{cluster}', ssc_dbre, test_detached)
GROUP BY hostName();
```

**Expected:**
- Replica 0-0: ~10,000 rows
- Replica 0-1: ~6,000-7,000 rows (missing October data)

**Verify on filesystem:**
```bash
kubectl exec -n ch-observations-nvme -it \
  chi-ch-observations-nvme-observations-ls-0-1-0 -- bash

cd /var/lib/clickhouse/data/ssc_dbre/test_detached/

# Check detached directory
ls -lh detached/

# You should see parts like: 202410_1_1_0, 202410_2_2_0, etc.
```

### Recovery - Re-attach Partition

```sql
-- On replica 0-1
ALTER TABLE ssc_dbre.test_detached 
ATTACH PARTITION '202410';
```

### Verify Recovery

```sql
-- Check no more detached parts
SELECT count(*) 
FROM system.detached_parts
WHERE database = 'ssc_dbre'
  AND table = 'test_detached';

-- Verify row counts match
SELECT 
    hostName() AS host,
    count(*) AS row_count
FROM clusterAllReplicas('{cluster}', ssc_dbre, test_detached)
GROUP BY hostName();
```

**Expected:** Both replicas now have ~10,000 rows

---

## Test Scenario 2: Detach Single Part

**Simulates:** Specific part corruption/detachment

### Execute Test

**Identify a specific part:**
```sql
SELECT
    hostName() AS host,
    name AS part_name,
    partition,
    rows
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE database = 'ssc_dbre'
  AND table = 'test_detached'
  AND partition = '202411'
  AND active = 1
LIMIT 1;
```

**Detach the specific part (on replica 0-1):**
```sql
-- Use the part_name from above query
ALTER TABLE ssc_dbre.test_detached 
DETACH PART '202411_X_X_0';
```

### Verify Single Part Detachment

```sql
SELECT
    hostName() AS host,
    name,
    reason,
    rows,
    formatReadableSize(bytes_on_disk) AS size
FROM clusterAllReplicas('{cluster}', system, detached_parts)
WHERE database = 'ssc_dbre'
  AND table = 'test_detached';
```

**Expected:** One part detached on replica 0-1

**Row count check:**
```sql
SELECT 
    hostName() AS host,
    count(*) AS row_count
FROM clusterAllReplicas('{cluster}', ssc_dbre, test_detached)
GROUP BY hostName();
```

**Expected:** Replica 0-1 missing rows from that specific part

### Recovery - Attach Single Part

```sql
-- On replica 0-1
ALTER TABLE ssc_dbre.test_detached 
ATTACH PART '202411_X_X_0';
```

### Verify Recovery

```sql
-- Check detached parts cleared
SELECT count(*) 
FROM system.detached_parts
WHERE database = 'ssc_dbre'
  AND table = 'test_detached';

-- Verify row counts
SELECT 
    hostName() AS host,
    count(*) AS row_count
FROM clusterAllReplicas('{cluster}', ssc_dbre, test_detached)
GROUP BY hostName();
```

---

## Test Scenario 3: Simulate Corrupted Part

**Simulates:** Checksum mismatch causing automatic detachment

⚠️ **WARNING:** This requires filesystem access and may cause temporary issues

### Execute Test

**Get into pod:**
```bash
kubectl exec -n ch-observations-nvme -it \
  chi-ch-observations-nvme-observations-ls-0-1-0 -- bash
```

**Navigate to table directory:**
```bash
cd /var/lib/clickhouse/data/ssc_dbre/test_detached/

# List active parts
ls -lh | grep 202412
```

**Corrupt a part's checksums file:**
```bash
# Pick a part (example: 202412_5_5_0)
PART_NAME="202412_5_5_0"

# Backup original checksums
cp $PART_NAME/checksums.txt $PART_NAME/checksums.txt.backup

# Corrupt the checksums file
echo "CORRUPTED_DATA_FOR_TEST" > $PART_NAME/checksums.txt

# Exit pod
exit
```

### Trigger Detection

**Force ClickHouse to check the part:**
```sql
-- On replica 0-1, try to select from that partition
SELECT count(*) 
FROM ssc_dbre.test_detached 
WHERE partition_date >= '2024-12-01';
```

**Or restart the replica:**
```bash
kubectl rollout restart statefulset/chi-ch-observations-nvme-observations-ls-0-1 \
  -n ch-observations-nvme

# Wait for pod to restart
kubectl get pods -n ch-observations-nvme -w
```

### Verify Automatic Detachment

```sql
-- Check if part was automatically detached
SELECT
    hostName() AS host,
    name,
    reason,
    partition_id
FROM clusterAllReplicas('{cluster}', system, detached_parts)
WHERE database = 'ssc_dbre'
  AND table = 'test_detached'
  AND reason LIKE '%Checksum%';
```

**Expected:** Part automatically moved to detached/ with reason containing "Checksum"

### Check Replication Queue Errors

```sql
SELECT
    type,
    last_exception,
    num_tries,
    postpone_reason
FROM system.replication_queue
WHERE database = 'ssc_dbre'
  AND table = 'test_detached'
  AND last_exception != '';
```

### Recovery - Drop and Refetch

**Drop the corrupted part:**
```sql
-- On replica 0-1
ALTER TABLE ssc_dbre.test_detached 
DROP DETACHED PART '202412_5_5_0';
```

**Force refetch from healthy replica:**
```sql
-- ClickHouse should automatically fetch missing data
-- Check replication queue
SELECT
    type,
    create_time,
    new_part_name,
    source_replica
FROM system.replication_queue
WHERE database = 'ssc_dbre'
  AND table = 'test_detached'
ORDER BY create_time DESC
LIMIT 10;
```

**Wait 30-60 seconds for replication, then verify:**
```sql
SELECT 
    hostName() AS host,
    count(*) AS row_count
FROM clusterAllReplicas('{cluster}', ssc_dbre, test_detached)
GROUP BY hostName();
```

**Expected:** Row counts match again

---

## Test Scenario 4: SYSTEM RESTORE REPLICA

**Simulates:** Complete replica recovery from healthy source

### Execute Test

**Detach multiple partitions on replica 0-1:**
```sql
-- Detach October and November
ALTER TABLE ssc_dbre.test_detached DETACH PARTITION '202410';
ALTER TABLE ssc_dbre.test_detached DETACH PARTITION '202411';
```

### Verify Major Data Loss

```sql
SELECT 
    hostName() AS host,
    count(*) AS row_count,
    count(DISTINCT toYYYYMM(partition_date)) AS partitions
FROM clusterAllReplicas('{cluster}', ssc_dbre, test_detached)
GROUP BY hostName();
```

**Expected:**
- Replica 0-0: ~10,000 rows, 3 partitions
- Replica 0-1: ~3,000 rows, 1 partition (only December)

### Execute SYSTEM RESTORE REPLICA

**On replica 0-1:**
```bash
kubectl exec -n ch-observations-nvme -it \
  chi-ch-observations-nvme-observations-ls-0-1-0 -- clickhouse-client
```

```sql
-- ⚠️ This will drop ALL local data and refetch
SYSTEM RESTORE REPLICA ssc_dbre.test_detached;
```

### Monitor Recovery Progress

```sql
-- Watch replication queue (run every 10-15 seconds)
SELECT
    type,
    create_time,
    num_tries,
    formatReadableSize(bytes_to_download) AS download_size,
    new_part_name
FROM system.replication_queue
WHERE database = 'ssc_dbre'
  AND table = 'test_detached'
ORDER BY create_time;
```

**Check parts being created:**
```sql
SELECT
    partition,
    count() AS parts,
    sum(rows) AS rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE database = 'ssc_dbre'
  AND table = 'test_detached'
  AND active = 1
GROUP BY partition;
```

### Verify Complete Recovery

**After 2-5 minutes:**
```sql
-- Check row counts match
SELECT 
    hostName() AS host,
    count(*) AS row_count,
    count(DISTINCT toYYYYMM(partition_date)) AS partitions
FROM clusterAllReplicas('{cluster}', ssc_dbre, test_detached)
GROUP BY hostName();
```

**Expected:** Both replicas have ~10,000 rows and 3 partitions

**Check no detached parts remain:**
```sql
SELECT count(*) 
FROM system.detached_parts
WHERE database = 'ssc_dbre'
  AND table = 'test_detached';
```

**Expected:** 0

---

## Monitoring & Alerts

### Check for Detached Parts

**Query to run regularly:**
```sql
SELECT
    hostName() AS host,
    database,
    table,
    count(*) AS detached_count,
    groupArray(reason) AS detach_reasons
FROM clusterAllReplicas('{cluster}', system, detached_parts)
GROUP BY host, database, table
HAVING detached_count > 0;
```

### New Relic Alert

**Alert when detached parts detected:**
```nrql
FROM Log 
SELECT count(*) 
WHERE cluster_name = 'platform-v2-demo-us-east-1' 
  AND namespace_name = 'clickhouse-operator'
  AND message LIKE '%detached parts%'
  AND message LIKE '%test_detached%'
```

**Threshold:** > 0 for 5 minutes

---

## Cleanup

### Option 1: Drop Test Table

```sql
DROP TABLE ssc_dbre.test_detached ON CLUSTER '{cluster}';
```

### Option 2: Clean Detached Parts Only

```sql
-- List all detached parts
SELECT
    concat(
        'ALTER TABLE ',
        database,
        '.',
        table,
        ' DROP DETACHED PART \'',
        name,
        '\''
    ) AS drop_command
FROM system.detached_parts
WHERE database = 'ssc_dbre'
  AND table = 'test_detached';

-- Copy and execute the DROP commands
```

### Verify Cleanup

```sql
-- Check table exists
SELECT 
    hostName(),
    database,
    name
FROM clusterAllReplicas('{cluster}', system, tables)
WHERE database = 'ssc_dbre' 
  AND name = 'test_detached';

-- Check no detached parts remain
SELECT count(*) 
FROM clusterAllReplicas('{cluster}', system, detached_parts)
WHERE database = 'ssc_dbre'
  AND table = 'test_detached';
```

---

## Test Checklist

- [ ] Environment is non-production
- [ ] Test table created successfully
- [ ] Multi-partition data inserted
- [ ] Verified initial replication (both replicas identical)
- [ ] Tested partition detach (Scenario 1)
- [ ] Verified detached parts appear in system.detached_parts
- [ ] Confirmed row count mismatch
- [ ] Tested ATTACH PARTITION recovery
- [ ] Verified recovery successful
- [ ] Tested single part detach (Scenario 2)
- [ ] Tested ATTACH PART recovery
- [ ] Tested corrupted part simulation (Scenario 3)
- [ ] Verified automatic detachment on checksum error
- [ ] Tested DROP DETACHED PART and refetch
- [ ] Tested SYSTEM RESTORE REPLICA (Scenario 4)
- [ ] Monitored replication queue during restore
- [ ] Verified complete recovery after restore
- [ ] Ran diagnostic scripts during tests
- [ ] Checked monitoring/alerting triggered
- [ ] Cleaned up test table and detached parts
- [ ] Documented any unexpected behaviors

---

## Production Runbook Reference

After testing, refer to:

**[detached-parts.md](detached-parts.md)** - Production troubleshooting guide

---

**Document Version**: 1.0  
**Last Updated**: October 2025  
**Maintained By**: DBRE Team
