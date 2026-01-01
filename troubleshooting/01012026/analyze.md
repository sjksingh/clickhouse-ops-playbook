# ClickHouse OLAP Performance Playbook
**From Reactive to Proactive: A Platform Engineer's Guide**

---

## 🎯 Quick Classification Matrix

When your monitoring alerts, use this decision tree:

```
SYMPTOM → ROOT CAUSE → RUNBOOK
```

### Classification Table

| Workload Class | Key Metrics | Root Cause | Severity | Runbook |
|---|---|---|---|---|
| 💣 Memory-heavy / OOM-risk | `peak_memory > 2GB` | Large GROUP BY, inefficient aggregations | 🔴 CRITICAL | RB-001 |
| 🔥 Parts explosion | `parts_read > 5000` | Merge lag, tiny parts, poor partitioning | 🟠 HIGH | RB-002 |
| 📡 IO-bound heavy scan | `bytes_per_sec > 200MB/s` | Missing indexes, full table scan | 🟡 MEDIUM | RB-003 |
| 🧱 CPU-bound / bad plan | `rows_per_sec < 5000` | Poor query plan, inefficient filters | 🟡 MEDIUM | RB-004 |
| 🔗 Join-heavy workload | `joins_executed > 5` | Cartesian products, unoptimized JOINs | 🟠 HIGH | RB-005 |

---

## 📋 RUNBOOK RB-001: Memory-Heavy / OOM Risk

**Symptoms:**
- `peak_memory > 2GB`
- Query killed with "Memory limit exceeded"
- System memory exhaustion

**Root Causes:**
1. Large GROUP BY on high-cardinality columns
2. Inefficient aggregation functions
3. Missing LIMIT on aggregations
4. Cartesian JOIN products

**Immediate Actions (5 min):**

```bash
# 1. Identify the offending query hash
./pv2-top-slow-queries.sh | grep "Memory-heavy"

# 2. Kill if still running
ch_query "KILL QUERY WHERE query_id = 'xxx'"

# 3. Check memory settings
ch_query "SELECT name, value FROM system.settings 
          WHERE name LIKE '%memory%' 
          AND name IN ('max_memory_usage', 'max_bytes_before_external_group_by')"
```

**Short-term Fix (30 min):**

```sql
-- Option A: Add memory-efficient GROUP BY
-- BEFORE (memory explosion):
SELECT user, count(*), groupUniqArray(domain) 
FROM large_table 
GROUP BY user

-- AFTER (bounded memory):
SELECT user, count(*), groupUniqArray(100)(domain)  -- Limit array size
FROM large_table 
GROUP BY user

-- Option B: Enable external aggregation
SET max_bytes_before_external_group_by = 10000000000; -- 10GB threshold
```

**Long-term Fix (This week):**

1. **Refactor query:**
   - Use `uniqExact()` → `uniq()` for approximations
   - Add `LIMIT` to array aggregations
   - Break into smaller CTEs

2. **Adjust settings:**
   ```xml
   <!-- config.xml -->
   <max_memory_usage>20000000000</max_memory_usage>  <!-- 20GB -->
   <max_bytes_before_external_group_by>10000000000</max_bytes_before_external_group_by>
   ```

3. **Monitor:**
   - Add to your pattern analyzer
   - Set alert at 1.5GB peak memory

---

## 📋 RUNBOOK RB-002: Parts Explosion

**Symptoms:**
- `parts_read > 5000`
- Query reads thousands of small parts
- Merge processes lagging

**Root Causes:**
1. Too frequent inserts (creates tiny parts)
2. Merges can't keep up with insert rate
3. Poor partitioning strategy
4. Replication lag creating part fragmentation

**Immediate Actions (5 min):**

```bash
# 1. Check merge backlog
ch_query "
SELECT 
  database,
  table,
  sum(active_parts) AS active_parts,
  sum(total_marks) AS total_marks,
  formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active = 1
GROUP BY database, table
ORDER BY active_parts DESC
LIMIT 10
"

# 2. Check merge processes
ch_query "
SELECT 
  database,
  table,
  elapsed,
  progress,
  formatReadableSize(total_size_bytes_compressed) AS size,
  formatReadableSize(bytes_read_uncompressed) AS read,
  merge_algorithm
FROM system.merges
ORDER BY elapsed DESC
"
```

**Short-term Fix (30 min):**

```sql
-- Force aggressive merges (do this off-peak!)
OPTIMIZE TABLE your_table FINAL;

-- Or schedule regular optimization
-- Add to cron:
-- 0 2 * * * ch_query "OPTIMIZE TABLE observations.deduped_observations_2"
```

**Long-term Fix (This week):**

1. **Batch your writes:**
   ```python
   # BEFORE: Insert every row
   for row in data:
       insert_single_row(row)  # Creates 1000s of parts!
   
   # AFTER: Batch inserts
   BATCH_SIZE = 10000
   for batch in chunks(data, BATCH_SIZE):
       insert_batch(batch)  # Creates few large parts
   ```

2. **Tune merge settings:**
   ```xml
   <!-- config.xml -->
   <merge_tree>
     <max_parts_to_merge_at_once>100</max_parts_to_merge_at_once>
     <parts_to_throw_insert>300</parts_to_throw_insert>
     <parts_to_delay_insert>150</parts_to_delay_insert>
   </merge_tree>
   ```

3. **Review partitioning:**
   ```sql
   -- Check partition distribution
   SELECT 
     partition,
     count() AS parts,
     formatReadableSize(sum(bytes_on_disk)) AS size
   FROM system.parts
   WHERE table = 'your_table' AND active = 1
   GROUP BY partition
   ORDER BY parts DESC
   
   -- If partitions have >100 parts each, consider:
   -- - Coarser partition key (daily → monthly)
   -- - Increase merge parallelism
   ```

---

## 📋 RUNBOOK RB-003: IO-Bound Heavy Scan

**Symptoms:**
- `bytes_per_sec > 200MB/s`
- Reading 10GB+ for simple queries
- High disk IO wait

**Root Causes:**
1. Missing or unused primary key
2. Full table scan due to non-indexed filters
3. Wrong column order in WHERE clause

**Immediate Actions (5 min):**

```bash
# Check query plan
ch_query "EXPLAIN PLAN 
  [paste your slow query here]
" --format=Pretty

# Look for:
# - "Expression (Before GROUP BY)" with no "FilterByPrimaryKey"
# - High "SelectedParts" or "SelectedRows"
```

**Short-term Fix (30 min):**

```sql
-- BEFORE (full scan):
SELECT * FROM observations 
WHERE asset_name = 'server-123'  -- Not in primary key!

-- AFTER (use indexed column first):
SELECT * FROM observations 
WHERE observation_owner_domain = 'company.com'  -- Primary key prefix
  AND asset_name = 'server-123'

-- Or add to WHERE clause:
WHERE observation_owner_domain IN (
  SELECT DISTINCT observation_owner_domain 
  FROM observations 
  WHERE asset_name = 'server-123'
  LIMIT 100
)
```

**Long-term Fix (This week):**

1. **Analyze primary key usage:**
   ```sql
   -- From your query, primary key is likely:
   -- (observation_owner_domain, observation_group_key, asset_key)
   
   -- Always filter on observation_owner_domain FIRST
   -- This allows ClickHouse to skip entire parts
   ```

2. **Add materialized views for common patterns:**
   ```sql
   CREATE MATERIALIZED VIEW observations_by_asset_name
   ENGINE = AggregatingMergeTree()
   ORDER BY (asset_name, observation_owner_domain)
   AS SELECT 
     asset_name,
     observation_owner_domain,
     groupUniqArrayState(observation_group_key) AS group_keys
   FROM observations.deduped_observations_2
   GROUP BY asset_name, observation_owner_domain
   ```

3. **Use projection for alternate sort orders:**
   ```sql
   ALTER TABLE observations.deduped_observations_2
   ADD PROJECTION by_asset_name (
     SELECT * ORDER BY asset_name, observation_owner_domain
   )
   
   -- ClickHouse will auto-use this for queries filtering on asset_name
   ```

---

## 📋 RUNBOOK RB-004: CPU-Bound / Bad Plan

**Symptoms:**
- `rows_per_sec < 5000`
- High CPU usage
- Query processes many rows but slowly

**Root Causes:**
1. Inefficient string operations (regex, concat in WHERE)
2. Complex multiIf() chains
3. Non-optimizable functions in WHERE clause
4. Unnecessary decompression

**Immediate Actions (5 min):**

```bash
# Check CPU profile
ch_query "
SELECT 
  thread_id,
  query_id,
  round(ProfileEvents['RealTimeMicroseconds']/1e6, 2) AS cpu_sec,
  ProfileEvents['UserTimeMicroseconds']/ProfileEvents['RealTimeMicroseconds'] AS cpu_ratio
FROM system.query_thread_log
WHERE event_time > now() - INTERVAL 5 MINUTE
ORDER BY cpu_sec DESC
LIMIT 10
"
```

**Short-term Fix (30 min):**

Look at your query - it has this pattern:
```sql
multiIf(
  upper(v1_issue_key) = 'MALWARE_INFECTION', concat(...),
  upper(v1_issue_key) = 'PVA_INSTALLATION', concat(...),
  -- 5 more conditions...
)
```

**Optimize this:**
```sql
-- BEFORE (evaluated for every row):
multiIf(
  upper(v1_issue_key) = 'MALWARE_INFECTION', 
  concat('Malware Infection - ', malware_family),
  ...
)

-- AFTER (pre-compute in CTE):
WITH enriched_issues AS (
  SELECT 
    *,
    CASE upper(v1_issue_key)
      WHEN 'MALWARE_INFECTION' THEN 'Malware Infection - ' || malware_family
      WHEN 'PVA_INSTALLATION' THEN 'PVA - ' || malware_family
      ELSE observation_group_identifier
    END AS computed_name
  FROM observations.deduped_observations_2
)
-- Now use computed_name in main query
```

**Long-term Fix:**

1. **Materialize complex expressions:**
   ```sql
   ALTER TABLE observations.deduped_observations_2
   ADD COLUMN computed_name String 
   MATERIALIZED multiIf(...) -- Your logic here
   
   -- Now queries can filter on computed_name directly
   ```

2. **Use dictionaries for lookups:**
   ```sql
   -- Instead of multiIf checking v1_issue_key repeatedly
   CREATE DICTIONARY issue_name_mapping (
     issue_key String,
     display_name String
   ) PRIMARY KEY issue_key
   SOURCE(CLICKHOUSE(TABLE 'v1_issue_types'))
   LAYOUT(FLAT())
   LIFETIME(3600)
   
   -- In query:
   SELECT dictGet('issue_name_mapping', 'display_name', v1_issue_key)
   ```

---

## 📋 RUNBOOK RB-005: Join-Heavy Workload

**Your query has 5 JOINs - this is the problem!**

**Immediate Actions:**

```bash
# Check join statistics
ch_query "
SELECT 
  query_id,
  ProfileEvents['JoinExecuted'] AS joins,
  ProfileEvents['HashJoinBytes'] AS join_bytes,
  query_duration_ms / 1000 AS sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND ProfileEvents['JoinExecuted'] > 3
  AND event_time > now() - INTERVAL 10 MINUTE
ORDER BY sec DESC
LIMIT 5
"
```

**Short-term Fix:**

Your query pattern:
```sql
FROM filtered_obs AS o
  INNER JOIN not_deleted_portfolios AS p ON ...
  ANY LEFT JOIN filtered_statuses AS vs ON ...
  ANY LEFT JOIN observations.vulnerability_details AS vd ON ...
  ANY LEFT JOIN observations.v1_issue_types AS it ON ...
```

**Optimize JOIN order:**
```sql
-- PRINCIPLE: Join smallest tables first

-- 1. Check table sizes:
SELECT 
  table,
  formatReadableSize(sum(bytes_on_disk)) AS size,
  sum(rows) AS rows
FROM system.parts
WHERE table IN (
  'deduped_observations_2', 
  'vulnerability_details',
  'v1_issue_types',
  'vrm_statuses'
)
AND active = 1
GROUP BY table

-- 2. Reorder: smallest → largest
-- If v1_issue_types is smallest:
FROM filtered_obs AS o
  ANY LEFT JOIN observations.v1_issue_types AS it ON ...  -- FIRST (smallest)
  ANY LEFT JOIN observations.vulnerability_details AS vd ON ...
  ANY LEFT JOIN filtered_statuses AS vs ON ...
  INNER JOIN not_deleted_portfolios AS p ON ...  -- LAST
```

**Long-term Fix:**

1. **Denormalize hot paths:**
   ```sql
   -- Create a wide table with pre-joined data
   CREATE TABLE observations_enriched AS
   SELECT 
     o.*,
     vd.title AS vuln_title,
     vd.description AS vuln_description,
     it.title AS issue_title
   FROM observations.deduped_observations_2 AS o
   LEFT JOIN observations.vulnerability_details AS vd ON o.observation_group_identifier = vd.cve_id
   LEFT JOIN observations.v1_issue_types AS it ON o.observation_group_identifier = upper(it.issue_key)
   
   -- Refresh daily
   ```

2. **Use dictionaries for dimension tables:**
   ```sql
   -- v1_issue_types is perfect for a dictionary
   CREATE DICTIONARY issue_types_dict (
     issue_key String,
     title String,
     short_description String,
     long_description String,
     recommendation String
   ) PRIMARY KEY issue_key
   SOURCE(CLICKHOUSE(TABLE 'v1_issue_types'))
   LAYOUT(FLAT())
   LIFETIME(3600)
   
   -- In query (dictionary lookup is 10-100x faster than JOIN):
   SELECT 
     dictGet('issue_types_dict', 'title', observation_group_identifier) AS issue_title
   ```

---

## 🔄 Proactive Monitoring Workflow

### Daily (10 minutes):
```bash
# Morning routine
./pv2-top-slow-queries.sh
./ch-pattern-analyzer.sh

# Look for:
# - New slow query patterns (not seen before)
# - Degradation trends (queries getting slower)
# - Resource spikes (memory, parts, IO)
```

### Weekly (30 minutes):
```bash
# Deep dive
ch_query "
SELECT 
  toStartOfWeek(event_date) AS week,
  query_hash,
  count() AS executions,
  round(avg(query_duration_ms/1000), 2) AS avg_sec,
  round(quantile(0.95)(query_duration_ms/1000), 2) AS p95_sec
FROM system.query_log
WHERE event_time > now() - INTERVAL 30 DAY
  AND type = 'QueryFinish'
  AND query_duration_ms > 1000
GROUP BY week, query_hash
HAVING executions > 10
ORDER BY week DESC, p95_sec DESC
LIMIT 50
"

# Action items:
# - Identify top 3 slowest recurring queries
# - Apply appropriate runbook
# - Document changes in your wiki/notes
```

### Monthly (2 hours):
- Review merge performance trends
- Analyze table growth and partitioning strategy
- Check replication lag patterns
- Capacity planning (project 3 months ahead)

---

## 🎯 Success Metrics (Track These!)

**Before optimization:**
```
Query: BAD8B1490FD8F110
- P95: 8.2s
- Memory: 2.14GB
- Parts read: 33
- Bytes: 31GB
```

**After optimization (your goal):**
```
Query: BAD8B1490FD8F110
- P95: <2.0s (4x improvement)
- Memory: <1GB (2x reduction)
- Parts read: <10 (3x reduction)
- Bytes: <10GB (3x reduction)
```

**Track in spreadsheet:**
| Date | Query Hash | Optimization | Before (s) | After (s) | Improvement |
|------|------------|--------------|------------|-----------|-------------|
| 2026-01-01 | BAD8B14... | Add projection | 8.2 | 2.1 | 3.9x |

---

## 💡 Principal-Level Thinking

**Staff Engineer:** "This query is slow, let me fix it"
**Principal Engineer:** "Why is this pattern emerging? What systemic issue does this reveal?"

**Questions to ask:**
1. **Pattern:** Is this a one-off or recurring? (Use pattern analyzer)
2. **Impact:** How many users affected? Business critical?
3. **Root cause:** Application logic? Schema design? Capacity?
4. **Prevention:** How do we prevent this class of problems?

**Document everything:**
- Keep a "war stories" log
- Share learnings with team
- Build institutional knowledge
- Update runbooks based on real incidents

---

## 📚 Resources to Level Up

- ClickHouse docs: Optimization tips
- Your pattern analyzer: Run it, study it
- Post-mortems: Write them after every incident
- This playbook: Iterate on it monthly

**Remember:** Principal engineers aren't just faster debuggers - they're system thinkers who prevent problems before they happen.

---

*Generated for your journey from Staff DBRE → Principal Engineer*
*Update this playbook as you learn. Make it yours.* 🚀
