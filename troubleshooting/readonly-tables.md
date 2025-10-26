# Readonly Tables - Production Troubleshooting

**Last Updated**: October 2025  
**Cluster**: Single shard, 2 replicas, 3 ZK ensemble

---

## 🚨 Symptoms

- Applications getting `Table is in readonly mode` errors
- Inserts failing on one or more replicas
- New Relic alert: **"ClickHouse Readonly Replica Detected"**
- `is_readonly = 1` in system.replicas

---

## ⚡ Quick Diagnosis

**Run this first:**
```bash
./scripts/diagnostics/00-quick-health-check.sql
```

**If readonly detected, run:**
```bash
./scripts/diagnostics/03-replication-health.sql
```

**Emergency query (copy-paste ready):**
```sql
SELECT
    hostName() AS host,
    database,
    table,
    is_readonly,
    absolute_delay AS lag_seconds,
    queue_size,
    is_session_expired,
    zookeeper_exception
FROM clusterAllReplicas('{cluster}', system, replicas)
WHERE is_readonly = 1;
```

---

## 🔍 Root Causes & Fixes

### 1. ZooKeeper Connection Lost (Most Common)

**Symptoms:**
- `is_session_expired = 1`
- `zookeeper_exception` contains connection errors
- Both replicas may show issues if ZK ensemble is down

**Check:**
```sql
SELECT 
    hostName() AS host,
    is_session_expired,
    zookeeper_exception,
    last_queue_update
FROM system.replicas
WHERE is_readonly = 1;
```

**Verify ZK health:**
```bash
./scripts/diagnostics/10-zookeeper-health.sql
```

**Fix:**
```bash
# Option 1: Restart affected replica pod
kubectl rollout restart statefulset/chi-<your-cluster>-<shard>-<replica> -n <namespace>

# Option 2: If ZK ensemble is down, fix ZK first
kubectl get pods -n <zk-namespace> | grep zookeeper

# Option 3: Check network connectivity
kubectl exec -it <ch-pod> -n <namespace> -- nc -zv <zk-host> 2181
```

**Verify recovery:**
```sql
SELECT hostName(), is_readonly, is_session_expired
FROM system.replicas
WHERE table = '<your_table>';
```

---

### 2. Corrupted Parts / Checksum Mismatch

**Symptoms:**
- `zookeeper_exception` contains "Checksum doesn't match"
- Replication queue stuck with exceptions
- Specific parts fail to replicate

**Check:**
```sql
SELECT
    database,
    table,
    hostName() AS host,
    type,
    last_exception,
    num_tries,
    postpone_reason
FROM clusterAllReplicas('{cluster}', system, replication_queue)
WHERE last_exception != ''
ORDER BY num_tries DESC
LIMIT 20;
```

**Identify corrupted parts:**
```sql
SELECT
    database,
    table,
    name AS part_name,
    hostName() AS host,
    disk_name,
    path
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE table = '<your_table>'
  AND active = 1;
```

**Fix:**

See **[detached-parts.md](detached-parts.md)** for detailed recovery procedures.

Quick fix:
```sql
-- On the affected replica
DETACH TABLE database.table;
ATTACH TABLE database.table;
```

**Nuclear option (refetch all data):**
```sql
-- ⚠️ WARNING: This drops all local data and refetches from healthy replica
SYSTEM RESTORE REPLICA database.table;
```

---

### 3. Disk Full

**Symptoms:**
- Errors mentioning "No space left on device"
- High disk usage (>90%)
- Merges failing

**Check:**
```bash
./scripts/diagnostics/09-disk-space.sql
```

**Quick check:**
```sql
SELECT
    hostName() AS host,
    formatReadableSize(free_space) AS free,
    round((total_space - free_space) / total_space * 100, 1) AS used_pct
FROM clusterAllReplicas('{cluster}', system, disks)
WHERE used_pct > 80;
```

**Fix:**

**Immediate (emergency):**
```sql
-- Drop old partitions (adjust date as needed)
ALTER TABLE database.table DROP PARTITION '2024-01-01';

-- Or detach to move to cold storage later
ALTER TABLE database.table DETACH PARTITION '2024-01-01';
```

**Short-term:**
```sql
-- Force optimize to merge small parts
OPTIMIZE TABLE database.table FINAL;
```

**Long-term:**
- Review retention policies
- Implement TTL (Time To Live)
- Add more storage
- Optimize compression (see **[compression.md](compression.md)**)

---

### 4. Replication Queue Backlog

**Symptoms:**
- `queue_size > 100`
- `inserts_in_queue` very high
- High `absolute_delay` (lag)

**Check:**
```sql
SELECT
    hostName() AS host,
    database,
    table,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    absolute_delay
FROM system.replicas
WHERE queue_size > 100 OR absolute_delay > 60;
```

**Fix:**
```sql
-- Check what's blocking the queue
SELECT
    type,
    create_time,
    num_tries,
    last_exception,
    postpone_reason
FROM system.replication_queue
WHERE num_tries > 5 OR last_exception != ''
ORDER BY create_time
LIMIT 20;
```

If queue is stuck:
```bash
# Restart replica to clear queue
kubectl rollout restart statefulset/chi-<cluster>-<shard>-<replica> -n <namespace>
```

---

### 5. Manual Operations Gone Wrong

**Common mistakes:**
- `DROP TABLE` without `ON CLUSTER` - one replica drops, other goes readonly
- `DETACH PARTITION` on one replica only
- `ALTER TABLE` mutations stuck

**Check:**
```sql
-- Check for missing tables on replicas
SELECT
    hostName() AS host,
    database,
    name AS table
FROM clusterAllReplicas('{cluster}', system, tables)
WHERE database = '<your_database>'
ORDER BY table, host;
```

**Fix:**

If table exists on one replica but not the other:
```sql
-- On replica WITH the table
SHOW CREATE TABLE database.table;

-- Copy the CREATE statement and run on missing replica
-- Then data will sync automatically
```

If table was accidentally dropped:
```sql
-- Recreate from backup or from other replica's CREATE statement
CREATE TABLE database.table ON CLUSTER '{cluster}' ...;
```

---

### 6. Stuck Mutations

**Symptoms:**
- `ALTER TABLE` or `UPDATE`/`DELETE` operations not completing
- Parts showing in `parts_to_do` but not mutating

**Check:**
```bash
./scripts/diagnostics/04-stuck-mutations.sql
```

**Fix:**
```sql
-- View stuck mutations
SELECT
    mutation_id,
    command,
    create_time,
    parts_to_do,
    latest_fail_reason
FROM system.mutations
WHERE is_done = 0
  AND create_time < now() - INTERVAL 10 MINUTE;

-- Kill specific mutation
KILL MUTATION WHERE mutation_id = 'mutation_xxx';

-- Or kill all mutations for a table
KILL MUTATION WHERE database = 'xxx' AND table = 'xxx';
```

---

## 🔧 Standard Recovery Procedures

### Procedure 1: Restart Replica (Most Common)

```bash
# 1. Identify readonly replica
kubectl exec -n <namespace> <pod-name> -- clickhouse-client -q \
  "SELECT hostName(), is_readonly FROM system.replicas WHERE is_readonly = 1"

# 2. Restart the pod
kubectl rollout restart statefulset/<statefulset-name> -n <namespace>

# 3. Wait for pod to be ready (1-2 minutes)
kubectl get pods -n <namespace> -w

# 4. Verify readonly cleared
kubectl exec -n <namespace> <pod-name> -- clickhouse-client -q \
  "SELECT is_readonly, is_session_expired FROM system.replicas WHERE table = '<table>'"
```

---

### Procedure 2: SYSTEM RESTORE REPLICA (Nuclear Option)

**⚠️ WARNING**: This drops ALL local data and refetches from healthy replica. Use only if:
- Replica is hopelessly corrupted
- Replication queue permanently stuck
- Checksum errors cannot be fixed

```sql
-- 1. Verify other replica is healthy
SELECT hostName(), is_readonly, is_leader
FROM system.replicas
WHERE database = '<db>' AND table = '<table>';

-- 2. On the BROKEN replica only:
SYSTEM RESTORE REPLICA database.table;

-- 3. Monitor progress
SELECT
    hostName(),
    is_readonly,
    queue_size,
    inserts_in_queue
FROM system.replicas
WHERE database = '<db>' AND table = '<table>';
```

**This will:**
- Drop all local parts
- Refetch from ZooKeeper metadata
- Download parts from healthy replica
- Takes 5-30 minutes depending on table size

---

### Procedure 3: Table Recreation (Last Resort)

If SYSTEM RESTORE REPLICA fails:

```sql
-- 1. Get CREATE statement from healthy replica
SHOW CREATE TABLE database.table;

-- 2. On broken replica, drop and recreate
DROP TABLE database.table;
CREATE TABLE database.table ... ; -- Use CREATE from step 1

-- 3. Data will sync automatically
```

---

## 🎯 Prevention

### Monitoring
```sql
-- Set up alerting for these metrics:
-- 1. is_readonly = 1 (CRITICAL)
-- 2. absolute_delay > 60 seconds (WARNING)
-- 3. queue_size > 100 (WARNING)
-- 4. is_session_expired = 1 (WARNING)
```

### Best Practices
1. **Always use `ON CLUSTER`** for DDL operations
2. **Test schema changes in dev** before production
3. **Monitor disk space** - alert at 80%, act at 85%
4. **Keep ZK ensemble healthy** - 3 or 5 nodes, never even numbers
5. **Never manually delete parts** from disk - use DETACH
6. **Implement TTL** for automatic data cleanup
7. **Regular backups** before major operations

### New Relic Alerts
```nrql
-- Critical: Readonly replica detected
FROM Log 
SELECT count(*) 
WHERE cluster_name = 'platform-v2-demo-us-east-1' 
  AND namespace_name = 'clickhouse-operator'
  AND message LIKE '%is_readonly%1%'
```

---

## 📊 Related Scripts

| Script | Purpose | When to Use |
|--------|---------|-------------|
| `00-quick-health-check.sql` | Fast overview of all issues | First thing to run at 3AM |
| `03-replication-health.sql` | Detailed replication status | Investigating readonly/lag |
| `04-stuck-mutations.sql` | Find stuck ALTER operations | Mutations not completing |
| `09-disk-space.sql` | Disk usage by table | Disk full errors |
| `10-zookeeper-health.sql` | ZK connectivity check | ZK connection issues |

---

## 🧪 Testing

To safely test readonly scenarios in dev/staging:

See **[readonly-tables-testing.md](readonly-tables-testing.md)**

---

## 📚 References

- [ClickHouse Replication Troubleshooting](https://clickhouse.com/docs/en/guides/sre/troubleshooting-replicated-tables)
- [System Tables Reference](https://clickhouse.com/docs/en/operations/system-tables/replicas)
- Internal: [Detached Parts Recovery](detached-parts.md)
- Internal: [Compression Optimization](compression.md)

---

**Document Version**: 1.0  
**Maintained By**: DBRE Team
