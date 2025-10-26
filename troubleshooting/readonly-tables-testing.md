# Readonly Tables - Testing & Validation Guide

**Purpose**: Test and validate readonly replica scenarios in dev/staging  
**Cluster**: `platform-v2-demo-us-east-1`  
**Namespace**: `ch-observations-nvme`

---

## ⚠️ SAFETY WARNING

**NEVER run these tests in production!**

These procedures intentionally break replication to test monitoring and recovery.

**Requirements:**
- Dev or staging environment only
- No active production traffic
- Ability to restart pods
- New Relic alerts configured

---

## Table of Contents

1. [Test Setup](#test-setup)
2. [Test Scenario 1: ZK Path Deletion](#scenario-1-zk-path-deletion)
3. [Test Scenario 2: Detached Partition](#scenario-2-detached-partition)
4. [Test Scenario 3: Corrupted Parts](#scenario-3-corrupted-parts)
5. [Verify Monitoring](#verify-monitoring)
6. [Cleanup](#cleanup)

---

## Test Setup

### Step 1: Create Test Table

```sql
CREATE TABLE ssc_dbre.test_readonly ON CLUSTER '{cluster}'
(
    `id` Int32,
    `value` String,
    `timestamp` DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}')
PARTITION BY toYYYYMM(timestamp)
ORDER BY id
SETTINGS storage_policy = 'standardv2', index_granularity = 8192;
```

**Expected output:**
```
┌─host─────────────────────────────────────────┬─port─┬─status─┬─error─┐
│ chi-ch-observations-nvme-observations-ls-0-0 │ 9000 │      0 │       │
│ chi-ch-observations-nvme-observations-ls-0-1 │ 9000 │      0 │       │
└──────────────────────────────────────────────┴──────┴────────┴───────┘
```

### Step 2: Insert Test Data

```sql
-- Insert 1,000 rows across multiple partitions
INSERT INTO ssc_dbre.test_readonly 
SELECT 
    number AS id,
    concat('test_', toString(number)) AS value,
    now() - INTERVAL number DAY AS timestamp
FROM numbers(1000);
```

### Step 3: Verify Replication

```sql
SELECT 
    hostName() AS host,
    count(*) AS row_count,
    count(DISTINCT partition) AS partitions
FROM clusterAllReplicas('{cluster}', ssc_dbre, test_readonly)
GROUP BY hostName()
ORDER BY host;
```

**Expected:** Both replicas show 1000 rows

### Step 4: Check Healthy State

```sql
SELECT 
    hostName() AS host,
    is_readonly,
    total_replicas,
    active_replicas,
    absolute_delay,
    queue_size
FROM clusterAllReplicas('{cluster}', system, replicas)
WHERE database = 'ssc_dbre' 
  AND table = 'test_readonly';
```

**Expected:**
- `is_readonly = 0` on both
- `active_replicas = 2`
- `absolute_delay = 0`
- `queue_size = 0`

---

## Scenario 1: ZK Path Deletion

**Simulates:** Accidental DROP TABLE on one replica (most common readonly cause)

### Execute Test

**Connect to replica 0-0 ONLY:**
```bash
kubectl exec -n ch-observations-nvme -it \
  chi-ch-observations-nvme-observations-ls-0-0-0 -- clickhouse-client
```

**Drop table (local only - DO NOT use ON CLUSTER):**
```sql
DROP TABLE ssc_dbre.test_readonly;
```

### Expected Behavior

**Replica 0-0:**
- Table gone completely
- No errors

**Replica 0-1:**
- Table exists but `is_readonly = 1`
- `zookeeper_exception`: "No node /clickhouse/tables/.../log"
- Inserts will fail with "Table is in readonly mode"

### Verify Readonly State

```sql
-- Run on replica 0-1 or via clusterAllReplicas
SELECT 
    hostName() AS host,
    is_readonly,
    zookeeper_exception,
    active_replicas
FROM clusterAllReplicas('{cluster}', system, replicas)
WHERE database = 'ssc_dbre' 
  AND table = 'test_readonly';
```

**Expected output:**
```
┌─host─────────────────────────────────────────┬─is_readonly─┬─zookeeper_exception──────────┬─active_replicas─┐
│ chi-ch-observations-nvme-observations-ls-0-1 │           1 │ No node /clickhouse/tables/... │               1 │
└──────────────────────────────────────────────┴─────────────┴──────────────────────────────┴─────────────────┘
```

### Test Insert Failure

**Connect to replica 0-1:**
```bash
kubectl exec -n ch-observations-nvme -it \
  chi-ch-observations-nvme-observations-ls-0-1-0 -- clickhouse-client
```

**Attempt insert:**
```sql
INSERT INTO ssc_dbre.test_readonly VALUES (9999, 'fail_test', now());
```

**Expected error:**
```
DB::Exception: Table is in readonly mode. (TABLE_IS_READ_ONLY)
```

### Recovery

**Option A: Restart replica 0-1**
```bash
kubectl rollout restart statefulset/chi-ch-observations-nvme-observations-ls-0-1 \
  -n ch-observations-nvme
```

**Expected:** Still readonly after restart (ZK path is gone)

**Option B: Recreate table on 0-0**
```bash
# Connect to 0-0
kubectl exec -n ch-observations-nvme -it \
  chi-ch-observations-nvme-observations-ls-0-0-0 -- clickhouse-client

# Recreate table
CREATE TABLE ssc_dbre.test_readonly
(
    id Int32,
    value String,
    timestamp DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/<UUID>/<SHARD>', '{replica}')
PARTITION BY toYYYYMM(timestamp)
ORDER BY id;
```

**Note:** Data will NOT sync automatically. Use SYSTEM RESTORE REPLICA on 0-0.

---

## Scenario 2: Detached Partition

**Simulates:** Manual partition detachment on one replica

### Execute Test

**On replica 0-1 ONLY:**
```sql
-- Detach current month's partition
ALTER TABLE ssc_dbre.test_readonly 
DETACH PARTITION tuple();
```

**Alternative (detach specific partition):**
```sql
-- First, see what partitions exist
SELECT DISTINCT partition 
FROM system.parts 
WHERE database = 'ssc_dbre' 
  AND table = 'test_readonly' 
  AND active = 1;

-- Detach a specific partition
ALTER TABLE ssc_dbre.test_readonly 
DETACH PARTITION '202410';
```

### Expected Behavior

**Replica 0-1:**
- Partition moved to `detached/` directory
- Table still functional but missing data from that partition
- NOT readonly (this is different from Scenario 1)

**Replica 0-0:**
- Still has the partition
- Continues to work normally

### Verify Detached Parts

```sql
-- Check for detached parts
SELECT
    database,
    table,
    name AS part_name,
    reason,
    min_block_number,
    max_block_number
FROM system.detached_parts
WHERE database = 'ssc_dbre'
  AND table = 'test_readonly';
```

### Row Count Mismatch

```sql
-- Compare row counts between replicas
SELECT 
    hostName() AS host,
    count(*) AS row_count
FROM clusterAllReplicas('{cluster}', ssc_dbre, test_readonly)
GROUP BY hostName();
```

**Expected:** Replica 0-1 has fewer rows

### Recovery

**Re-attach partition:**
```sql
-- On replica 0-1
ALTER TABLE ssc_dbre.test_readonly 
ATTACH PARTITION tuple();

-- Or specific partition
ALTER TABLE ssc_dbre.test_readonly 
ATTACH PARTITION '202410';
```

**Verify recovery:**
```sql
SELECT 
    hostName() AS host,
    count(*) AS row_count
FROM clusterAllReplicas('{cluster}', ssc_dbre, test_readonly)
GROUP BY hostName();
```

**Expected:** Both replicas now have same count

---

## Scenario 3: Corrupted Parts

**Simulates:** Checksum mismatch / corrupted data files

⚠️ **WARNING:** This is more invasive - requires direct filesystem access

### Execute Test

**Connect to pod and corrupt a part:**
```bash
# Get into the pod
kubectl exec -n ch-observations-nvme -it \
  chi-ch-observations-nvme-observations-ls-0-1-0 -- bash

# Find a part directory
cd /var/lib/clickhouse/data/ssc_dbre/test_readonly/

# List parts
ls -la

# Corrupt a part's checksum file (example)
echo "corrupted" > all_1_1_0/checksums.txt

# Exit pod
exit
```

### Expected Behavior

- Replica 0-1 may go readonly
- Replication queue errors about checksum mismatch
- Queries may fail on corrupted part

### Verify Corruption

```sql
SELECT
    database,
    table,
    hostName(),
    last_exception
FROM clusterAllReplicas('{cluster}', system, replication_queue)
WHERE database = 'ssc_dbre'
  AND table = 'test_readonly'
  AND last_exception != '';
```

### Recovery

**Detach and refetch:**
```sql
-- On replica 0-1
DETACH TABLE ssc_dbre.test_readonly;
ATTACH TABLE ssc_dbre.test_readonly;
```

**Or use SYSTEM RESTORE REPLICA:**
```sql
SYSTEM RESTORE REPLICA ssc_dbre.test_readonly;
```

---

## Verify Monitoring

### New Relic Log Query

**Check for readonly detection (1-2 minutes after triggering):**
```nrql
FROM Log 
SELECT timestamp, message 
WHERE cluster_name = 'platform-v2-demo-us-east-1' 
  AND namespace_name = 'clickhouse-operator'
  AND message LIKE '%test_readonly%'
  AND message LIKE '%is_readonly%'
ORDER BY timestamp DESC
LIMIT 50
```

### Expected Logs

**Pattern to look for:**
```
Extracted [X] system replicas for host chi-ch-observations-nvme-observations-ls-0-1
...is_readonly=1...
```

### Alert Validation

1. Go to **New Relic → Alerts & AI → Issues & Activity**
2. Look for: "ClickHouse Readonly Replica Detected"
3. Confirm alert details match:
   - Host: `chi-ch-observations-nvme-observations-ls-0-1`
   - Table: `test_readonly`
   - Status: `is_readonly = 1`

### Diagnostic Scripts

**Run during testing to see real-time status:**
```bash
# Quick health check
./scripts/diagnostics/00-quick-health-check.sql

# Detailed replication status
./scripts/diagnostics/03-replication-health.sql

# Check ZK connectivity
./scripts/diagnostics/10-zookeeper-health.sql
```

---

## Cleanup

### Option 1: Drop Table Completely

```sql
-- If both replicas still have the table
DROP TABLE ssc_dbre.test_readonly ON CLUSTER '{cluster}';

-- If only one replica has it
-- Connect to that replica and drop locally
DROP TABLE ssc_dbre.test_readonly;
```

### Option 2: Keep Table for Future Testing

```sql
-- Truncate data but keep structure
TRUNCATE TABLE ssc_dbre.test_readonly ON CLUSTER '{cluster}';
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
  AND name = 'test_readonly';

-- Should return empty if dropped, or 2 rows if kept
```

### Clean Detached Parts

```sql
-- Remove detached parts from disk
SELECT 
    concat(
        'ALTER TABLE ',
        database,
        '.',
        table,
        ' DROP DETACHED PARTITION ID \'',
        partition_id,
        '\''
    ) AS drop_command
FROM system.detached_parts
WHERE database = 'ssc_dbre'
  AND table = 'test_readonly';

-- Copy and run the DROP commands
```

---

## Test Checklist

Use this checklist when running tests:

- [ ] Confirmed environment is **not production**
- [ ] Created test table successfully
- [ ] Verified initial replication (both replicas have data)
- [ ] Executed readonly test (Scenario 1)
- [ ] Confirmed readonly state in system.replicas
- [ ] Verified insert failures on readonly replica
- [ ] Checked New Relic logs appeared (1-2 min)
- [ ] Verified New Relic alert triggered (5 min threshold)
- [ ] Tested recovery procedure
- [ ] Confirmed readonly cleared after recovery
- [ ] Executed detached partition test (Scenario 2)
- [ ] Verified row count mismatch
- [ ] Tested re-attach procedure
- [ ] Ran diagnostic scripts during tests
- [ ] Documented any unexpected behaviors
- [ ] Cleaned up test table and data
- [ ] Verified New Relic alert cleared

---

## Troubleshooting Tests

### Test Doesn't Trigger Readonly

**Possible causes:**
1. Both replicas still synced via ZK cache
2. ZK path still exists temporarily
3. Replica hasn't detected the issue yet

**Force detection:**
```sql
-- Restart replica to force ZK check
-- (via kubectl rollout restart)
```

### New Relic Alert Doesn't Fire

**Checks:**
1. Logs are being shipped (check NR logs exist)
2. Alert query matches your cluster name
3. Alert threshold not met (need >0 or >10 depending on config)
4. Wait full 5 minutes for threshold window

**Debug query:**
```nrql
FROM Log 
SELECT count(*) 
WHERE cluster_name = 'platform-v2-demo-us-east-1' 
  AND message LIKE '%is_readonly%'
SINCE 10 minutes ago
```

### Recovery Doesn't Work

**If restart doesn't clear readonly:**
- ZK path truly gone → need to recreate table
- Check ZK connectivity
- Try SYSTEM RESTORE REPLICA

**If ATTACH fails:**
- Part may be truly corrupted
- Check filesystem permissions
- Drop and refetch from healthy replica

---

## Production Runbook Reference

After completing these tests, refer to:

**[readonly-tables.md](readonly-tables.md)** - Production troubleshooting guide

---

**Document Version**: 1.0  
**Last Updated**: October 2025  
**Maintained By**: DBRE Team
