# ClickHouse Operations Runbook

**Production-ready diagnostic scripts and troubleshooting guides for ClickHouse clusters**

**Cluster**: Single shard, 2 replicas, 3 ZK ensemble  
**Environment**: Kubernetes (clickhouse-operator)  
**Last Updated**: October 2025

---

## 🚨 Quick Start (On-Call Emergency)

**You're paged at 3AM. What do you do?**

### Step 1: Run Quick Health Check (30 seconds)
```bash
cd scripts/diagnostics/
clickhouse-client < 00-quick-health-check.sql
```

This checks:
- Readonly replicas
- Recent errors
- Replication lag
- Memory pressure
- Merge backlog
- Stuck mutations
- Disk space

**If all `issue_count = 0`, you're good. Go back to bed.**

### Step 2: If Issues Found, Use Decision Tree

| Alert/Symptom | Run This Script | Then Read This Guide |
|---------------|-----------------|----------------------|
| 🔴 **Readonly replica** | `03-replication-health.sql` | [readonly-tables.md](troubleshooting/readonly-tables.md) |
| 🔴 **Query failures/errors** | `02-query-failures.sql` | Check error codes, investigate |
| 🔴 **Slow queries** | `01-slow-queries.sql` | Optimize queries, check indexes |
| 🟡 **Replication lag** | `03-replication-health.sql` | [readonly-tables.md](troubleshooting/readonly-tables.md) |
| 🟡 **Detached parts** | Check system.detached_parts | [detached-parts.md](troubleshooting/detached-parts.md) |
| 🟡 **Too many parts** | `05-merge-backlog.sql` | [too-many-parts.md](troubleshooting/too-many-parts.md) |
| 🟡 **Stuck mutations** | `04-stuck-mutations.sql` | Kill or investigate |
| 🟡 **High memory** | `07-memory-pressure.sql` | Kill heavy queries |
| 🟡 **Long queries** | `08-long-running-queries.sql` | Kill or optimize |
| 🟢 **Disk space low** | `09-disk-space.sql` | [compression.md](troubleshooting/compression.md) |
| 🔵 **ZK connection issues** | `10-zookeeper-health.sql` | Check ZK ensemble, network |

---

## 📁 Repository Structure

```
clickhouse-ops-runbook/
├── README.md (this file)
├── scripts/
│   ├── diagnostics/
│   │   ├── 00-quick-health-check.sql          # 🚨 START HERE
│   │   ├── 01-slow-queries.sql                # Query performance
│   │   ├── 02-query-failures.sql              # Error analysis
│   │   ├── 03-replication-health.sql          # Replica status
│   │   ├── 04-stuck-mutations.sql             # ALTER/UPDATE issues
│   │   ├── 05-merge-backlog.sql               # Too many parts
│   │   ├── 06-active-merges.sql               # Current merge activity
│   │   ├── 07-memory-pressure.sql             # Memory usage
│   │   ├── 08-long-running-queries.sql        # Stuck queries
│   │   ├── 09-disk-space.sql                  # Storage analysis
│   │   └── 10-zookeeper-health.sql            # ZK connectivity
│   └── full-diagnostics.sql                    # Run everything
└── troubleshooting/
    ├── README.md                               # Guide index
    ├── readonly-tables.md                      # Fix readonly replicas
    ├── readonly-tables-testing.md              # Test readonly scenarios
    ├── detached-parts.md                       # Recover detached parts
    ├── detached-parts-testing.md               # Test detached parts
    ├── compression.md                          # Optimize storage
    └── too-many-parts.md                       # Fix merge backlog
```

---

## 🛠️ How to Use This Runbook

### Prerequisites

**1. ClickHouse Client Access**
```bash
# From your machine
clickhouse-client --host <host> --port 9000 --user <user> --password <password>

# Or from pod
kubectl exec -n <namespace> -it <pod-name> -- clickhouse-client
```

**2. Configure Cluster Macro**
All scripts use `{cluster}` macro. Ensure your ClickHouse config has:
```xml
<macros>
    <cluster>your_cluster_name</cluster>
</macros>
```

**3. kubectl Access (for restarts)**
```bash
kubectl get pods -n <namespace>
```

---

## 📊 Diagnostic Scripts Guide

### 00-quick-health-check.sql
**When**: First thing to run, always  
**Duration**: 10-30 seconds  
**Purpose**: Fast overview of all critical issues

**Returns**: 7 rows with `issue_count` for each check
- All zeros = cluster healthy
- Non-zero = run specific diagnostic script

---

### 01-slow-queries.sql
**When**: 
- Users complaining about slow performance
- High query latency alerts
- CPU spikes

**What it finds**:
- Queries taking >2 seconds (last 5 min)
- Query patterns by hash
- Top queries by total time consumed
- Memory and rows scanned

**Actions**:
- Optimize query (add indexes, improve WHERE)
- Kill long-running queries
- Check if table needs OPTIMIZE

---

### 02-query-failures.sql
**When**:
- Application errors
- Failed query alerts
- Users reporting "query failed"

**What it finds**:
- Errors by exception code
- Errors by table
- Error timeline (spikes = incidents)

**Common error codes**:
- `241` - Memory limit exceeded (OOM risk)
- `202` - Too many parts (need merges)
- `60` - Table doesn't exist (schema issues)
- `395` - Checksum mismatch (corrupt parts)

---

### 03-replication-health.sql
**When**:
- Readonly replica alerts
- Data inconsistency between replicas
- Replication lag warnings

**What it finds**:
- Readonly replicas (`is_readonly = 1`)
- Replication lag (>60 seconds)
- Queue backlog
- ZK session issues

**Actions**: See [readonly-tables.md](troubleshooting/readonly-tables.md)

---

### 04-stuck-mutations.sql
**When**:
- ALTER TABLE not completing
- UPDATE/DELETE operations hanging
- "Parts to do" not decreasing

**What it finds**:
- Mutations running >10 minutes
- Failed mutations with reasons
- Parts waiting for mutation

**Actions**:
```sql
-- Kill stuck mutation
KILL MUTATION WHERE mutation_id = 'mutation_xxx';
```

---

### 05-merge-backlog.sql
**When**:
- "Too many parts" errors
- Queries slowing down
- High disk I/O

**What it finds**:
- Tables with >200 parts (warning)
- Tables with >500 parts (critical)
- Parts by partition
- Small parts that should merge

**Actions**: See [too-many-parts.md](troubleshooting/too-many-parts.md)

---

### 06-active-merges.sql
**When**:
- High I/O usage
- Understanding merge activity
- Investigating slow merges

**What it finds**:
- Currently running merges
- Merge progress and size
- Long-running merges (>5 min)

---

### 07-memory-pressure.sql
**When**:
- OOM kills
- High memory usage alerts
- "Memory limit exceeded" errors

**What it finds**:
- Memory usage per host
- Memory percentage (>80% = warning)
- Top memory-consuming queries
- Historical high-memory queries

**Actions**:
```sql
-- Kill heavy query
KILL QUERY WHERE query_id = 'xxx';
```

---

### 08-long-running-queries.sql
**When**:
- Queries stuck/hanging
- High CPU usage
- Need to identify what to kill

**What it finds**:
- Queries running >60 seconds
- Current query load
- Queries by user

**Actions**:
```sql
-- Kill specific query
KILL QUERY WHERE query_id = 'xxx';

-- Kill all queries by user
KILL QUERY WHERE user = 'username';
```

---

### 09-disk-space.sql
**When**:
- Disk full alerts (>80%)
- Planning capacity
- Before dropping old data

**What it finds**:
- Disk usage per host
- Largest tables
- Disk usage by database
- Old partitions (>90 days) to drop

**Actions**: See [compression.md](troubleshooting/compression.md)

---

### 10-zookeeper-health.sql
**When**:
- Replication issues
- Readonly replicas with ZK errors
- Cluster coordination problems

**What it finds**:
- ZK connectivity from all replicas
- ZK session status
- ZK exception messages

**Actions**:
- Check ZK ensemble health
- Restart ZK if needed
- Check network connectivity

---

### full-diagnostics.sql
**When**:
- Initial "WTF is happening?" investigation
- Scheduled health reports
- Incident post-mortem data collection

**Duration**: 1-3 minutes  
**Purpose**: Run all diagnostic queries, dump to file

**Usage**:
```bash
clickhouse-client < full-diagnostics.sql > diagnostics-$(date +%s).log
```

---

## 📚 Troubleshooting Guides

### [readonly-tables.md](troubleshooting/readonly-tables.md)
**Most common issue - bookmark this!**

**Covers**:
- ZK connection loss (most common)
- Corrupted parts causing readonly
- Disk full
- Manual operations gone wrong
- Recovery procedures (restart, RESTORE REPLICA)

**Quick fix (90% of cases)**:
```bash
kubectl rollout restart statefulset/<statefulset-name> -n <namespace>
```

---

### [detached-parts.md](troubleshooting/detached-parts.md)
**When**: Parts missing, row count mismatch

**Covers**:
- Manual DETACH operations
- Automatic detachment (corruption)
- Failed merges
- Recovery procedures (ATTACH, DROP, RESTORE)

**Quick check**:
```sql
SELECT count(*) FROM system.detached_parts;
```

---

### [too-many-parts.md](troubleshooting/too-many-parts.md)
**When**: "Too many parts" errors, slow queries

**Covers**:
- Why too many parts hurt performance
- Root causes (high insert rate, small batches)
- Prevention (batch inserts, merge settings)
- Recovery (OPTIMIZE, adjust settings)

**Quick fix**:
```sql
OPTIMIZE TABLE database.table FINAL;
```

---

### [compression.md](troubleshooting/compression.md)
**When**: Disk space issues, storage optimization

**Covers**:
- ClickHouse compression codecs (LZ4, ZSTD, Delta, Gorilla)
- When to use each codec
- Migration procedures
- Real-world examples

**Analysis**:
```sql
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 2) AS ratio
FROM system.parts
WHERE active = 1
GROUP BY table;
```

---

## 🧪 Testing Guides

**Safe to run in dev/staging only!**

- [readonly-tables-testing.md](troubleshooting/readonly-tables-testing.md)
- [detached-parts-testing.md](troubleshooting/detached-parts-testing.md)

These guides help you:
- Understand failure scenarios
- Test monitoring/alerting
- Practice recovery procedures
- Train new team members

---

## 🎯 Common Scenarios Cheat Sheet

### Scenario 1: Cluster Appears Frozen
```bash
# 1. Check long-running queries
./scripts/diagnostics/08-long-running-queries.sql

# 2. Check memory pressure
./scripts/diagnostics/07-memory-pressure.sql

# 3. Kill heavy queries if needed
clickhouse-client -q "KILL QUERY WHERE elapsed > 300"
```

---

### Scenario 2: Insert Failures
```bash
# 1. Check if replica is readonly
./scripts/diagnostics/03-replication-health.sql

# 2. Check disk space
./scripts/diagnostics/09-disk-space.sql

# 3. Check for errors
./scripts/diagnostics/02-query-failures.sql
```

---

### Scenario 3: Queries Timing Out
```bash
# 1. Check for slow queries
./scripts/diagnostics/01-slow-queries.sql

# 2. Check for too many parts
./scripts/diagnostics/05-merge-backlog.sql

# 3. Check active merges
./scripts/diagnostics/06-active-merges.sql
```

---

### Scenario 4: Replicas Out of Sync
```bash
# 1. Check replication health
./scripts/diagnostics/03-replication-health.sql

# 2. Check ZK connectivity
./scripts/diagnostics/10-zookeeper-health.sql

# 3. Check for detached parts
clickhouse-client -q "SELECT count(*) FROM system.detached_parts"
```

---

## 🔧 Useful ClickHouse Commands

### Kill Queries
```sql
-- Kill by query_id
KILL QUERY WHERE query_id = 'xxx';

-- Kill long-running queries
KILL QUERY WHERE elapsed > 300;

-- Kill by user
KILL QUERY WHERE user = 'username';

-- Kill by pattern
KILL QUERY WHERE query LIKE '%heavy_table%';
```

### Restart Replica
```bash
# Graceful restart
kubectl rollout restart statefulset/<name> -n <namespace>

# Force delete pod
kubectl delete pod <pod-name> -n <namespace> --force
```

### Check Logs
```bash
# ClickHouse logs
kubectl logs -n <namespace> <pod-name> --tail=100 -f

# Search for errors
kubectl logs -n <namespace> <pod-name> | grep -i error

# Check specific time
kubectl logs -n <namespace> <pod-name> --since=10m
```

### ZooKeeper Operations
```sql
-- Check ZK connectivity
SELECT count(*) FROM system.zookeeper WHERE path = '/';

-- View ZK paths
SELECT * FROM system.zookeeper WHERE path = '/clickhouse';

-- Check ZK metrics
SELECT * FROM system.asynchronous_metrics WHERE metric LIKE 'ZooKeeper%';
```
---

## 🔗 External Resources

- [ClickHouse Official Docs](https://clickhouse.com/docs)
- [System Tables Reference](https://clickhouse.com/docs/en/operations/system-tables)
- [Replication Troubleshooting](https://clickhouse.com/docs/en/guides/sre/troubleshooting-replicated-tables)
- [clickhouse-operator GitHub](https://github.com/Altinity/clickhouse-operator)

---
