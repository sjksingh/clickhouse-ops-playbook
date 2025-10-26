# 🧩 ClickHouse Troubleshooting Guide: Inconsistent Detached Parts (ReplicatedMergeTree + ZooKeeper)

**Environment:**  
- ClickHouse version: `25.2`  
- Engine: `ReplicatedMergeTree`  
- Coordination service: `ZooKeeper`

---

## 📖 Overview

Inconsistent or detached parts appear when replicas in a ClickHouse cluster **diverge in part state** — for example, when one replica has missing, corrupted, or uncommitted parts while another already merged or detached them.

Common symptoms:
```
Code: 252. DB::Exception: Too many parts (detached or inconsistent)
Code: 253. DB::Exception: Replica is not consistent with other replicas
Code: 254. DB::Exception: There is a part on replica but not in ZooKeeper
```

---

## ⚙️ 1. Root Causes

| Category | Typical Trigger | Description |
|-----------|-----------------|--------------|
| **Unclean Shutdown / Restart** | Pod or host killed before ClickHouse finishes merges | Leaves orphaned parts in `/detached` |
| **Interrupted Fetch / Merge** | Network hiccup, IO timeout | Part downloaded partially or checksum mismatch |
| **Failed ALTER / DROP** | ZooKeeper outage during ALTER or DROP PARTITION | Metadata partially committed |
| **ZooKeeper Desync** | Session timeout or split-brain | Metadata state diverges between replicas |
| **Version or Schema Drift** | Mixed ClickHouse versions or different settings | Incompatible part serialization |
| **Disk / Volume Issues** | Missing mount or tier mismatch | Data directory recreated or detached unexpectedly |

---

## 🧭 2. Initial Diagnosis

### 🔍 Check for Detached Parts
```sql
SELECT
    database,
    table,
    count() AS detached_parts
FROM system.detached_parts
GROUP BY database, table
HAVING detached_parts > 0;
```

### ⏱️ Check Replica Health
```sql
SELECT
    database,
    table,
    is_leader,
    is_session_expired,
    absolute_delay,
    queue_size
FROM system.replicas;
```

### 🧾 Check Replication Queue
```sql
SELECT
    database,
    table,
    type,
    source_replica,
    part_name,
    create_time,
    postpone_reason
FROM system.replication_queue
WHERE type IN ('FETCH', 'MERGE', 'DROP', 'ATTACH')
ORDER BY create_time DESC;
```

### 🔍 Check ZooKeeper Metadata Path
```sql
SELECT zookeeper_path FROM system.replicas WHERE table = '<table_name>';
```

---

## 🛠️ 3. Recovery Steps

### 🧹 Step 1: Try Automatic Re-Sync
```sql
SYSTEM SYNC REPLICA <database>.<table>;
```

### ♻️ Step 2: Restart Replication
```sql
SYSTEM STOP REPLICATION <database>.<table>;
SYSTEM START REPLICATION <database>.<table>;
-- Or
SYSTEM RESTART REPLICA <database>.<table>;
```

### 🧩 Step 3: Manually Reattach Detached Parts
```sql
ALTER TABLE <database>.<table> ATTACH PARTITION '<partition_id>';
ALTER TABLE <database>.<table> ATTACH PART '<part_name>';
```
```bash
ls /var/lib/clickhouse/data/<database>/<table>/detached/
```

### 📦 Step 4: Force Fetch from Another Replica
```sql
ALTER TABLE <database>.<table> FETCH PART '<part_name>' FROM '/clickhouse/tables/<zookeeper_path>';
```

### ⚠️ Step 5: Rebuild Replica (Last Resort)
```sql
ALTER TABLE <database>.<table> DETACH REPLICA '<replica_name>';
ALTER TABLE <database>.<table> ATTACH REPLICA '<replica_name>';
```

---

## 🧠 4. ZooKeeper Validation

### Check ZooKeeper Health
```bash
echo ruok | nc <zookeeper-host> 2181
# Expected output: imok
```

### Check Active Sessions
```bash
echo stat | nc <zookeeper-host> 2181
```

### Check for Orphaned Nodes
```bash
zkCli.sh -server <zookeeper-host>:2181
ls /clickhouse/tables/<db>/<table>
```

---

## 💡 5. Preventive Measures

| Category | Recommendation |
|-----------|----------------|
| **Kubernetes** | Set `terminationGracePeriodSeconds: 60` and add a `preStop` hook: `clickhouse-client --query "SYSTEM FLUSH LOGS"` |
| **ZooKeeper** | Minimum 3 nodes (SSD). Monitor latency and session count. |
| **Upgrades** | Always perform rolling upgrades with `SYSTEM SYNC REPLICA` verification between steps. |
| **Disk Mounts** | Ensure consistent mount paths. Don’t mix local + network volumes. |
| **Maintenance** | Periodically clean detached parts: `rm -rf /var/lib/clickhouse/data/<db>/<table>/detached/*` *(only after verifying safe)* |

---

## 🧾 6. Example Full Workflow

```bash
# 1. Identify inconsistent replicas
clickhouse-client -q "SELECT table, absolute_delay, queue_size FROM system.replicas WHERE absolute_delay > 0"

# 2. Sync affected table
clickhouse-client -q "SYSTEM SYNC REPLICA analytics.events"

# 3. If detached parts exist
clickhouse-client -q "ALTER TABLE analytics.events ATTACH PARTITION '2025-10-25'"

# 4. If still inconsistent
clickhouse-client -q "ALTER TABLE analytics.events DETACH REPLICA 'replica1'"
sleep 10
clickhouse-client -q "ALTER TABLE analytics.events ATTACH REPLICA 'replica1'"

# 5. Verify
clickhouse-client -q "SELECT table, is_readonly, queue_size, absolute_delay FROM system.replicas"
```

---

## 🧩 7. References
- [ClickHouse Docs – ReplicatedMergeTree](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication)
- [ClickHouse Keeper & ZooKeeper Troubleshooting](https://clickhouse.com/docs/en/operations/troubleshooting)
- [system.detached_parts Table](https://clickhouse.com/docs/en/operations/system-tables/detached_parts)
- [system.replicas Table](https://clickhouse.com/docs/en/operations/system-tables/replicas)

---

**Last Updated:** 2025-10-25  
**Maintainer:** DBRE Team  
**Audience:** SRE / DBA / Platform Ops
