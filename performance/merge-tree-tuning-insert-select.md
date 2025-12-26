# ClickHouse MergeTree Performance Guide
## On-Call DBRE Platform Reference

---

## Table of Contents
1. [Quick Reference](#quick-reference)
2. [Understanding the Problem](#understanding-the-problem)
3. [Critical Monitoring Queries](#critical-monitoring-queries)
4. [Performance Tuning Settings](#performance-tuning-settings)
5. [Troubleshooting Workflow](#troubleshooting-workflow)
6. [EKS-Specific Considerations](#eks-specific-considerations)
7. [Common Scenarios & Solutions](#common-scenarios--solutions)

---

## Quick Reference

### Emergency Response
```bash
# Check if you're about to hit "Too many parts" error
kubectl exec -it <clickhouse-pod> -- clickhouse-client --query "
SELECT table, partition, count() as parts 
FROM system.parts 
WHERE active = 1 
GROUP BY table, partition 
HAVING parts > 200 
ORDER BY parts DESC"

# Check merge queue depth
kubectl exec -it <clickhouse-pod> -- clickhouse-client --query "
SELECT count() as queued_merges, sum(parts_to_merge) as total_parts 
FROM system.merges"
```

### Key Settings at a Glance
| Setting | Default | High-Throughput | Query-Optimized |
|---------|---------|----------------|-----------------|
| `parts_to_throw_insert` | 300 | 500-600 | 200-300 |
| `parts_to_delay_insert` | 150 | 250-300 | 100-150 |
| `background_pool_size` | 16 | 24-32 | 16-20 |

---

## Understanding the Problem

### What Are Parts?
When data is inserted into ClickHouse MergeTree tables:
- Each INSERT creates one or more **parts** (directories with data files)
- Parts accumulate over time
- Background merge process combines small parts into larger ones
- Too many parts = slow queries (must read multiple files)
- Too few parts = slow inserts (merging consumes I/O/CPU)

### The Core Trade-Off
```
High Insert Performance ← → High Query Performance
(more parts allowed)       (aggressive merging)
```

### Critical Threshold
When parts exceed `parts_to_throw_insert`, ClickHouse rejects INSERTs with:
```
"Too many parts (300). Merges are processing significantly slower than inserts."
```

---

## Critical Monitoring Queries

### 1. Active Parts by Table/Partition
**What it shows**: Current part counts, identifies tables under merge pressure

```sql
SELECT
    table,
    partition,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE active = 1
GROUP BY table, partition
ORDER BY part_count DESC
LIMIT 20;
```

**Red flags**:
- `part_count > 200`: Approaching danger zone
- `part_count > 300`: Critical, may start rejecting INSERTs
- Sudden spikes: Burst traffic or merge stall

---

### 2. Merge Queue Status
**What it shows**: Active merge work, backlog depth

```sql
SELECT
    table,
    count() AS queued_merges,
    sum(parts_to_merge) AS total_parts_to_merge,
    formatReadableSize(sum(size_in_bytes)) AS total_merge_size,
    max(elapsed) AS longest_merge_seconds
FROM system.merges
GROUP BY table
ORDER BY queued_merges DESC;
```

**Red flags**:
- `queued_merges > 0` consistently: Merges can't keep up
- Large `total_merge_size`: I/O intensive operations
- `longest_merge_seconds > 300`: Very slow merges

---

### 3. Background Pool Utilization
**What it shows**: Whether merge threads are saturated

```sql
SELECT
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN (
    'BackgroundPoolTaskActive',
    'BackgroundMergesAndMutationsPoolTask',
    'BackgroundMergesAndMutationsPoolSize'
)
ORDER BY metric;
```

**Analysis**:
- If `BackgroundPoolTaskActive` = `background_pool_size`: **Threads saturated**
- If `BackgroundMergesAndMutationsPoolTask` growing: **Merge backlog building**

---

### 4. Recent Merge Performance
**What it shows**: Historical merge timing, helps identify trends

```sql
SELECT
    table,
    count() AS merge_count,
    avg(duration_ms) / 1000 AS avg_duration_sec,
    max(duration_ms) / 1000 AS max_duration_sec,
    sum(read_rows) AS total_rows_merged,
    formatReadableSize(sum(read_bytes)) AS total_data_merged
FROM system.part_log
WHERE event_type = 'MergeParts'
  AND event_time > now() - INTERVAL 1 HOUR
GROUP BY table
ORDER BY merge_count DESC;
```

**Red flags**:
- Increasing `avg_duration_sec` over time: I/O or CPU bottleneck
- Very high `max_duration_sec`: Large part merges blocking pool

---

### 5. Part Size Distribution
**What it shows**: Whether parts are properly consolidating

```sql
SELECT
    table,
    partition,
    quantile(0.5)(rows) AS median_rows,
    quantile(0.95)(rows) AS p95_rows,
    max(rows) AS max_rows,
    count() AS part_count
FROM system.parts
WHERE active = 1
GROUP BY table, partition
ORDER BY part_count DESC
LIMIT 20;
```

**Healthy pattern**: Few large parts, not many tiny parts
**Problem pattern**: Many parts with low median_rows (fragmentation)

---

## Performance Tuning Settings

### Configuration File Location (EKS)
Settings go in `/etc/clickhouse-server/config.d/` or ConfigMap:

```xml
<clickhouse>
    <merge_tree>
        <parts_to_throw_insert>400</parts_to_throw_insert>
        <parts_to_delay_insert>200</parts_to_delay_insert>
    </merge_tree>
    
    <background_pool_size>20</background_pool_size>
    <background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>
    <max_bytes_to_merge_at_max_space_in_pool>161061273600</max_bytes_to_merge_at_max_space_in_pool>
</clickhouse>
```

### Setting Descriptions

#### `parts_to_throw_insert`
- **What**: Max parts before rejecting INSERTs
- **Default**: 300
- **When to increase**: High-throughput streaming workloads
- **When to decrease**: Query performance is priority
- **Risk**: Higher values = more parts = slower queries

#### `parts_to_delay_insert`
- **What**: Parts threshold where INSERTs start slowing down (not rejected)
- **Default**: 150
- **Rule of thumb**: Set to 50% of `parts_to_throw_insert`
- **Effect**: Gives merges breathing room before hard rejection

#### `background_pool_size`
- **What**: Number of threads for background merges
- **Default**: 16
- **Considerations**:
  - More threads = faster merges but more CPU/IO
  - Set based on CPU cores and storage speed
  - For NVMe SSD with 32+ cores: 24-32
  - For slower storage: Keep default or reduce

#### `background_merges_mutations_concurrency_ratio`
- **What**: Max concurrent merge tasks = `background_pool_size × ratio`
- **Default**: 2
- **Effect**: Allows more tasks in queue beyond thread count

#### `max_bytes_to_merge_at_max_space_in_pool`
- **What**: Maximum size of parts that can be merged
- **Default**: 150 GB
- **When to increase**: Tables with very large parts (>100GB)

---

## Troubleshooting Workflow

### Symptom: "Too many parts" Errors

**Step 1**: Check current part counts
```sql
SELECT table, partition, count() as parts 
FROM system.parts WHERE active = 1 
GROUP BY table, partition HAVING parts > 200;
```

**Step 2**: Check if merges are running
```sql
SELECT count() FROM system.merges;
```

**Step 3**: Decision tree
- **If merges = 0 and parts > 200**: Merge process stalled → Check logs, restart server
- **If merges > 0**: Merges happening but can't keep up → Increase `background_pool_size`
- **Quick fix**: Increase `parts_to_throw_insert` to buy time

**Step 4**: Apply changes and verify
```bash
# Edit config (via kubectl or ConfigMap)
kubectl edit configmap clickhouse-config

# Rolling restart pods
kubectl rollout restart statefulset clickhouse

# Verify settings applied
kubectl exec -it clickhouse-0 -- clickhouse-client --query "
SELECT name, value FROM system.settings 
WHERE name LIKE '%parts%' OR name LIKE '%background%'"
```

---

### Symptom: Slow Queries Despite Low Part Counts

**Step 1**: Identify slow queries
```sql
SELECT 
    type,
    query_duration_ms,
    read_rows,
    read_bytes,
    formatReadableSize(memory_usage) as memory,
    substring(query, 1, 100) as query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 5000
  AND event_date >= today() - 1
ORDER BY query_duration_ms DESC
LIMIT 20;
```

**Step 2**: Use EXPLAIN to diagnose
```sql
-- Check if indexes are being used
EXPLAIN indexes = 1
SELECT ... FROM your_table WHERE ...;

-- Check query parallelism
EXPLAIN PIPELINE
SELECT ... FROM your_table WHERE ...;
```

**Common issues**:
- No indexes applied → Add skip index or optimize partition key
- Single-threaded execution → Check `max_threads` setting
- Full table scans → Add PREWHERE clause

---

### Symptom: High CPU/IO but Merges Not Completing

**Step 1**: Check merge sizes
```sql
SELECT 
    table,
    sum(size_in_bytes) / 1024 / 1024 / 1024 AS merge_size_gb,
    max(elapsed) as longest_merge
FROM system.merges
GROUP BY table;
```

**Step 2**: If merge_size_gb is very large (>100GB):
- Increase `max_bytes_to_merge_at_max_space_in_pool`
- Consider optimizing partition scheme
- Check if you need faster storage (NVMe)

**Step 3**: Check for I/O bottlenecks (from K8s node)
```bash
# Check pod I/O usage
kubectl exec -it clickhouse-0 -- iostat -x 2 5

# Check storage performance
kubectl exec -it clickhouse-0 -- fio --name=test --rw=randrw --size=1G --runtime=30
```

---

## EKS-Specific Considerations

### Resource Limits
Ensure your StatefulSet has adequate resources:
```yaml
resources:
  requests:
    cpu: "8"
    memory: "32Gi"
  limits:
    cpu: "16"
    memory: "64Gi"
```

**Rule of thumb**: `background_pool_size` should be ≤ 50% of CPU cores

### Storage Classes
- **gp3 EBS**: Good for most workloads, set `background_pool_size: 16-20`
- **io2 EBS**: High IOPS, can use `background_pool_size: 24-32`
- **Instance Store (NVMe)**: Fastest, use `background_pool_size: 32+`

### ConfigMap Management
Store settings in ConfigMap for easy updates:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: clickhouse-merge-config
data:
  merge-settings.xml: |
    <clickhouse>
        <merge_tree>
            <parts_to_throw_insert>400</parts_to_throw_insert>
            <parts_to_delay_insert>200</parts_to_delay_insert>
        </merge_tree>
        <background_pool_size>20</background_pool_size>
    </clickhouse>
```

### Monitoring with Prometheus
Export key metrics:
```yaml
# Add to ClickHouse config
<prometheus>
    <endpoint>/metrics</endpoint>
    <port>9363</port>
    <metrics>true</metrics>
</prometheus>
```

---

## Common Scenarios & Solutions

### Scenario 1: Real-Time Streaming (Kafka → ClickHouse)
**Profile**:
- Continuous high-volume INSERTs (1000s/sec)
- Recent data queried most
- Query latency requirement: <1 sec

**Recommended Settings**:
```xml
<merge_tree>
    <parts_to_throw_insert>500</parts_to_throw_insert>
    <parts_to_delay_insert>250</parts_to_delay_insert>
</merge_tree>
<background_pool_size>24</background_pool_size>
```

**Partition Strategy**: By hour or day to keep parts manageable

---

### Scenario 2: Batch ETL (Hourly/Daily Loads)
**Profile**:
- Periodic bulk INSERTs
- Query-heavy during business hours
- Can tolerate slower INSERTs

**Recommended Settings**:
```xml
<merge_tree>
    <parts_to_throw_insert>200</parts_to_throw_insert>
    <parts_to_delay_insert>100</parts_to_delay_insert>
</merge_tree>
<background_pool_size>16</background_pool_size>
```

**Strategy**: Schedule merges to complete before query hours

---

### Scenario 3: Mixed Workload (Your Likely Case)
**Profile**:
- Moderate continuous INSERTs with occasional spikes
- Mix of analytical and operational queries
- Need balanced performance

**Recommended Settings**:
```xml
<merge_tree>
    <parts_to_throw_insert>350</parts_to_throw_insert>
    <parts_to_delay_insert>175</parts_to_delay_insert>
</merge_tree>
<background_pool_size>20</background_pool_size>
<background_merges_mutations_concurrency_ratio>2</background_merges_mutations_concurrency_ratio>
```

---

## Change Management Best Practices

### Before Making Changes
1. **Document baseline**: Run all monitoring queries, save results
2. **Check current load**: Don't tune during peak hours
3. **Review recent incidents**: Understand what triggered need for change

### Making Changes
1. **Change one setting at a time**: 25-50% adjustments
2. **Use ConfigMap**: Easy rollback if needed
3. **Rolling restart**: `kubectl rollout restart` for zero downtime
4. **Wait for full merge cycle**: 10-30 minutes before re-measuring

### After Changes
1. **Re-run monitoring queries**: Compare against baseline
2. **Monitor for 24 hours**: Catch daily patterns
3. **Document impact**: What improved, what didn't
4. **Alert on regressions**: Set up Prometheus alerts

---

## Emergency Runbook

### Critical: "Too many parts" Blocking Production

**Immediate Action** (< 5 minutes):
```bash
# 1. Increase threshold (buys time)
kubectl exec -it clickhouse-0 -- clickhouse-client --query "
SET parts_to_throw_insert = 600;"

# 2. Check if merges are running
kubectl exec -it clickhouse-0 -- clickhouse-client --query "
SELECT count() FROM system.merges;"

# 3. If no merges, force OPTIMIZE (use sparingly!)
kubectl exec -it clickhouse-0 -- clickhouse-client --query "
OPTIMIZE TABLE your_problematic_table FINAL;"
```

**Short-term Fix** (< 30 minutes):
```bash
# Update ConfigMap with higher thresholds
kubectl edit configmap clickhouse-config

# Rolling restart to apply
kubectl rollout restart statefulset clickhouse
```

**Long-term Solution** (next maintenance window):
- Review partition strategy (might be too granular)
- Analyze insert patterns (batch smaller INSERTs)
- Add more storage/CPU if consistently hitting limits
- Consider table redesign if fundamentally mismatched to workload

---

## Key Takeaways

1. **Monitor continuously**: Set up dashboards and alerts
2. **Start conservative**: Use defaults unless you have evidence of problems
3. **Change incrementally**: 25-50% adjustments, one at a time
4. **Know your workload**: Streaming vs batch vs mixed dictates settings
5. **Hardware matters**: Settings should match your storage speed and CPU
6. **Partition wisely**: Good partitioning reduces part counts naturally
7. **Document everything**: Track what you changed and why

---

## Additional Resources

- ClickHouse docs: https://clickhouse.com/docs/en/operations/settings/merge-tree-settings
- System tables reference: https://clickhouse.com/docs/en/operations/system-tables
- Performance optimization: https://clickhouse.com/docs/en/operations/optimizing-performance
- MerTree Settings: https://chistadata.com/mergetree-settings-clickhouse-performance/

---

**Last Updated**: Based on ClickHouse best practices as of December 2024
**Maintained by**: Platform DBRE Team
**Questions?**: #dbre-oncall Slack channel
