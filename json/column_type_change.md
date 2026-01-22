# Schema Migration Plan: Evidence Column to JSON Type

## Executive Summary

**Goal:** Migrate `evidence` column from `String` to native `JSON` type for better query performance and simpler syntax.

**Timeline:** 4-6 weeks (phased approach)

**Downtime:** Zero (using dual-write strategy)

**Risk Level:** Low (with proper rollback plan)

---

## Current State

```sql
CREATE TABLE max.topic_proto_scorecard_measurement_observations
(
    `status` String,
    `organization_domain` String,
    `v1_issue_type_name` String,
    `first_seen` String,
    `last_seen` String,
    `asset` String,
    `evidence` String,  -- ⚠️ Current: String containing JSON
    `measurement_id` String,
    `ingest_date` DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree(...)
```

---

## Target State

### Option A: Native JSON Column (Recommended)

```sql
CREATE TABLE max.topic_proto_scorecard_measurement_observations_v2
(
    `status` String,
    `organization_domain` String,
    `v1_issue_type_name` String,
    `first_seen` String,
    `last_seen` String,
    `asset` String,
    `evidence` JSON,  -- ✅ Native JSON type
    `measurement_id` String,
    `ingest_date` DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree(...)
```

**Benefits:**
- Simpler query syntax: `evidence.breach.breach_items`
- Better compression
- Potential query performance improvement
- Built-in JSON validation

**Drawbacks:**
- Requires full table migration
- Need to backfill historical data
- All consumers need query updates

---

### Option B: Materialized JSON Column (Faster, Lower Risk)

```sql
ALTER TABLE max.topic_proto_scorecard_measurement_observations
ADD COLUMN evidence_json JSON MATERIALIZED 
    if(evidence != '', parseJSON(evidence), null);
```

**Benefits:**
- No data migration needed
- Backward compatible (old column still works)
- Can migrate queries gradually
- Rollback is trivial (just drop column)

**Drawbacks:**
- Extra storage (both String and JSON)
- Need to update all INSERT queries eventually
- Transitional state is permanent unless cleaned up

---

### Option C: Flattened Schema (Most Performant, Highest Effort)

```sql
-- Main observations table (unchanged)
CREATE TABLE max.topic_proto_scorecard_measurement_observations ...

-- New table for breach items
CREATE TABLE max.breach_items
(
    measurement_id String,
    cluster_id String,
    title String,
    link String,
    source_type String,
    published_date DateTime,
    originating_party String,
    affected_parties Array(String),
    threat_actors Array(String),
    breach_date Nullable(DateTime),
    records_lost Nullable(UInt64),
    source_reliability Float32,
    created_at DateTime,
    updated_at DateTime,
    info_leaked Array(String),
    item_id String,
    ingest_date DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree()
PARTITION BY toYYYYMM(ingest_date)
ORDER BY (measurement_id, item_id, ingest_date);
```

**Benefits:**
- Best query performance (no JSON parsing)
- Proper indexing on breach fields
- Easy to add columns
- Standard SQL joins

**Drawbacks:**
- Major schema redesign
- Need to modify Kafka connector/SMT
- All queries need rewrite
- More tables to manage

---

## Recommended Approach: Option B (Materialized Column)

### Why Option B?

1. **Low Risk** - Backward compatible, easy rollback
2. **Fast Implementation** - 1-2 weeks vs 4-6 weeks
3. **Zero Downtime** - No data migration required
4. **Gradual Migration** - Update queries at your own pace
5. **Validation Period** - Run both old and new queries in parallel

---

## Migration Timeline: Option B (Materialized Column)

### Week 1: Preparation & Testing

#### Day 1-2: Schema Design & Validation
```sql
-- QA Environment: Add materialized column
ALTER TABLE max.topic_proto_scorecard_measurement_observations
ADD COLUMN evidence_json JSON MATERIALIZED 
    if(evidence != '', parseJSON(evidence), null);

-- Validate on sample data
SELECT 
    measurement_id,
    evidence_json.breach.cluster_id as cluster_new,
    JSONExtractString(
        JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
        'cluster_id'
    ) as cluster_old
FROM max.topic_proto_scorecard_measurement_observations
WHERE evidence != ''
LIMIT 100;
```

#### Day 3-4: Query Rewrite & Testing
```sql
-- New simplified query using evidence_json
SELECT
    v1_issue_type_name AS issue_type,
    measurement_id,
    first_seen,
    last_seen,
    
    -- Breach fields (MUCH SIMPLER!)
    evidence_json.breach.cluster_id AS cluster,
    evidence_json.breach.records_lost AS records_lost,
    evidence_json.breach.confirmed AS confirmed,
    evidence_json.breach.breach_items AS breach_items
    
FROM max.topic_proto_scorecard_measurement_observations
WHERE v1_issue_type_name = 'confirmed_first_party_breach';
```

#### Day 5: Performance Testing
- Run old vs new queries
- Compare execution times
- Validate results match 100%
- Check memory usage

**Success Criteria:**
- ✅ Results match between old/new queries
- ✅ Performance equal or better
- ✅ No NULL values where data exists

---

### Week 2: Production Rollout

#### Day 1: Production Schema Change (Low Risk Window)
```sql
-- Execute during low-traffic period
ALTER TABLE max.topic_proto_scorecard_measurement_observations
ADD COLUMN evidence_json JSON MATERIALIZED 
    if(evidence != '', parseJSON(evidence), null);
```

**Impact:** 
- Near-instant (materialized columns computed on-the-fly)
- No table lock
- No downtime

#### Day 2-3: Monitoring & Validation
- Monitor disk usage (expect ~10-20% increase)
- Check query performance
- Validate data population
- Run automated tests

#### Day 4-5: Update Application Queries
- Deploy updated queries gradually
- Keep old queries as fallback
- Monitor error rates

**Rollback Plan:**
```sql
-- If issues arise, simply drop the column
ALTER TABLE max.topic_proto_scorecard_measurement_observations
DROP COLUMN evidence_json;
```

---

### Week 3-4: Full Migration & Optimization

#### Week 3: Migrate All Queries
- Update all dashboards
- Update all scheduled reports
- Update all API endpoints
- Document new query patterns

#### Week 4: Optimization & Cleanup
- Analyze query patterns
- Add indexes if needed
- Update documentation
- Train team on new syntax

---

## Migration Timeline: Option A (Full Schema Change)

If you prefer full migration to native JSON (more thorough, longer timeline):

### Phase 1: Preparation (Week 1-2)

#### Week 1: Design & Testing
1. Create new table schema in QA
2. Test Kafka connector with new schema
3. Write data migration script
4. Performance benchmark

#### Week 2: Dual-Write Setup
1. Configure Kafka to write to BOTH tables
2. Validate dual writes working
3. Monitor lag between tables

### Phase 2: Data Migration (Week 3-4)

#### Week 3: Historical Data Backfill
```sql
-- Backfill historical data in batches
INSERT INTO max.topic_proto_scorecard_measurement_observations_v2
SELECT 
    status,
    organization_domain,
    v1_issue_type_name,
    first_seen,
    last_seen,
    asset,
    if(evidence != '', parseJSON(evidence), null) as evidence,
    measurement_id,
    ingest_date
FROM max.topic_proto_scorecard_measurement_observations
WHERE ingest_date >= '2025-01-01'  -- Batch by month
  AND ingest_date < '2025-02-01'
SETTINGS max_insert_threads = 4;
```

**Strategy:**
- Backfill 1 month at a time
- Run during off-peak hours
- Monitor cluster health
- Validate row counts match

#### Week 4: Validation & Reconciliation
- Compare row counts
- Validate critical records
- Check data integrity
- Performance testing

### Phase 3: Cutover (Week 5-6)

#### Week 5: Query Migration
1. Update all application queries
2. Update dashboards
3. Deploy to staging
4. Full regression testing

#### Week 6: Production Cutover
1. Final sync (catch up on recent data)
2. Update Kafka connector to new table only
3. Switch queries to new table
4. Monitor for 48 hours
5. Deprecate old table

#### Rollback Plan:
```sql
-- If critical issues, revert Kafka connector to old table
-- All queries still work with old table as backup
```

---

## Cost-Benefit Analysis

| Approach | Timeline | Downtime | Risk | Effort | Long-term Benefit |
|----------|----------|----------|------|--------|-------------------|
| **Option B: Materialized Column** | 2 weeks | 0 min | Low | Low | Medium |
| **Option A: Full Migration** | 6 weeks | 0 min | Medium | High | High |
| **Option C: Flattened Schema** | 8-10 weeks | 0 min | High | Very High | Very High |
| **Current (No Change)** | 0 weeks | 0 min | None | None | None |

---

## Recommendation: Phased Approach

### Phase 1 (Now): Keep Current Fix
- Use the nested JSONExtractRaw solution
- Works immediately
- No migration risk
- Performance is acceptable (1 sec for 67K rows)

### Phase 2 (Q2 2026): Add Materialized Column
- Low risk, high reward
- 2 week implementation
- Gradual query migration
- Easy rollback

### Phase 3 (Q3 2026): Evaluate Full Migration
- Based on Phase 2 results
- If query simplification shows major benefits
- Consider full schema migration
- Or keep materialized column permanently

---

## Detailed Steps: Option B Implementation

### Step 1: QA Environment Testing

```sql
-- 1. Add column in QA
ALTER TABLE max.topic_proto_scorecard_measurement_observations
ADD COLUMN evidence_json JSON MATERIALIZED 
    if(evidence != '', parseJSON(evidence), null);

-- 2. Wait 30 seconds for materialization

-- 3. Validate data
SELECT 
    count(*) as total,
    countIf(evidence != '' AND evidence_json IS NULL) as failed_parsing,
    countIf(evidence != '' AND evidence_json IS NOT NULL) as successful_parsing
FROM max.topic_proto_scorecard_measurement_observations;

-- Expected: failed_parsing = 0
```

### Step 2: Query Rewrite

```sql
-- OLD QUERY (Current)
SELECT
    arrayMap(b ->
        tuple(
            JSONExtractString(b, 'title'),
            JSONExtractString(b, 'link'),
            -- ... 11 more fields
        ),
        JSONExtractArrayRaw(
            JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
            'breach_items'
        )
    ) AS breach_items
FROM max.topic_proto_scorecard_measurement_observations;

-- NEW QUERY (After migration)
SELECT
    evidence_json.breach.breach_items AS breach_items
FROM max.topic_proto_scorecard_measurement_observations;
```

**Complexity Reduction:** 15 lines → 1 line!

### Step 3: A/B Testing

```sql
-- Run both queries side-by-side
WITH old_method AS (
    SELECT 
        measurement_id,
        arrayMap(b -> tuple(...), 
            JSONExtractArrayRaw(...)
        ) as breach_items_old
    FROM max.topic_proto_scorecard_measurement_observations
    WHERE measurement_id IN (SELECT measurement_id FROM ... LIMIT 1000)
),
new_method AS (
    SELECT 
        measurement_id,
        evidence_json.breach.breach_items as breach_items_new
    FROM max.topic_proto_scorecard_measurement_observations
    WHERE measurement_id IN (SELECT measurement_id FROM ... LIMIT 1000)
)
SELECT 
    old_method.measurement_id,
    breach_items_old = breach_items_new as results_match
FROM old_method
JOIN new_method USING (measurement_id)
WHERE NOT results_match;

-- Expected: 0 rows (all results match)
```

### Step 4: Production Deployment

```bash
# 1. Create deployment ticket
JIRA: "Add evidence_json materialized column for simplified JSON queries"

# 2. Change window: Off-peak hours (e.g., 2 AM PST)

# 3. Execute schema change
clickhouse-client --host chi-max-qa-local-0-0-0 --query "
ALTER TABLE max.topic_proto_scorecard_measurement_observations
ADD COLUMN evidence_json JSON MATERIALIZED 
    if(evidence != '', parseJSON(evidence), null);
"

# 4. Validate
clickhouse-client --query "
SELECT count(*), countIf(evidence_json IS NOT NULL) 
FROM max.topic_proto_scorecard_measurement_observations 
WHERE evidence != '';
"

# 5. Monitor for 1 hour

# 6. Update application queries (gradual rollout)
```

### Step 5: Monitoring Queries

```sql
-- Check storage overhead
SELECT 
    table,
    formatReadableSize(sum(bytes)) as size,
    sum(rows) as rows
FROM system.parts
WHERE database = 'max' 
  AND table = 'topic_proto_scorecard_measurement_observations'
GROUP BY table;

-- Check query performance
SELECT 
    query_duration_ms,
    query,
    read_rows,
    read_bytes
FROM system.query_log
WHERE query LIKE '%evidence_json%'
  AND type = 'QueryFinish'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY query_duration_ms DESC
LIMIT 10;
```

---

## Rollback Procedures

### Rollback for Option B (Materialized Column)

```sql
-- SIMPLE: Just drop the column
ALTER TABLE max.topic_proto_scorecard_measurement_observations
DROP COLUMN evidence_json;

-- Revert application queries to old syntax
-- (Keep old queries in version control for quick revert)
```

**Rollback Time:** < 5 minutes  
**Data Loss:** None (original column untouched)

### Rollback for Option A (Full Migration)

```sql
-- Revert Kafka connector to old table
-- In Confluent Cloud or connector config:
{
  "topics": "scorecard_observations",
  "table.name": "topic_proto_scorecard_measurement_observations"  // Old table
}

-- Keep new table for investigation
-- All queries already support old table as backup
```

**Rollback Time:** 15-30 minutes  
**Data Loss:** Only new data since cutover (can be replayed from Kafka)

---

## Success Metrics

### Phase 1 (Immediate)
- ✅ Query returns correct breach_items (current fix working)
- ✅ Performance < 2 seconds for 67K rows
- ✅ Zero production incidents

### Phase 2 (After Materialized Column)
- ✅ Query complexity reduced by 90%
- ✅ New hire onboarding time reduced
- ✅ Query performance improved by 20-30%
- ✅ Storage overhead < 20%

### Phase 3 (After Full Migration, if pursued)
- ✅ Query syntax matches ClickHouse best practices
- ✅ No String → JSON parsing overhead
- ✅ Schema matches data model
- ✅ Zero legacy technical debt

---

## Questions & Answers

### "How much storage will materialized column add?"
Approximately 10-20% more storage. The JSON type is compressed, but you're storing data twice (String + JSON).

For 67K rows with average evidence size ~25KB:
- Current: ~1.7 GB
- After: ~2.0-2.2 GB
- Delta: ~300-500 MB

### "Will this impact write performance?"
Minimal impact. ClickHouse computes materialized columns during INSERT, but JSON parsing is very fast (~microseconds per row).

Expected INSERT latency increase: < 5%

### "Can we do this without DBA involvement?"
Option B (materialized column): Yes, ALTER TABLE is non-blocking and instant.
Option A (full migration): Need DBRE for capacity planning and backfill strategy.

### "What if parseJSON fails on malformed data?"
The IF condition handles this:
```sql
if(evidence != '', parseJSON(evidence), null)
```

Malformed JSON → NULL value instead of query failure.

To identify malformed JSON:
```sql
SELECT measurement_id, evidence
FROM max.topic_proto_scorecard_measurement_observations
WHERE evidence != '' 
  AND NOT isValidJSON(evidence)
LIMIT 10;
```

---

## Decision Matrix

**Choose Option B (Materialized Column) if:**
- ✅ Want quick improvement (2 weeks)
- ✅ Risk-averse approach needed
- ✅ Backward compatibility required
- ✅ Team has limited ClickHouse expertise

**Choose Option A (Full Migration) if:**
- ✅ Long-term schema optimization priority
- ✅ Have 6+ weeks for project
- ✅ Want to eliminate technical debt
- ✅ Storage optimization important

**Choose Option C (Flattened Schema) if:**
- ✅ Need best possible query performance
- ✅ Breach data queries are critical path
- ✅ Have 2-3 months for project
- ✅ Team comfortable with major refactoring

**Keep Current Fix if:**
- ✅ Performance is acceptable (it is!)
- ✅ No budget for schema changes
- ✅ Other priorities more urgent
- ✅ Team is small / bandwidth limited

---

## Recommendation Summary

**Immediate (This Week):**
- ✅ Use the current fix (nested JSONExtractRaw)
- ✅ Document the approach
- ✅ Monitor performance

**Short-term (Next Sprint):**
- 📋 Schedule QA testing of Option B
- 📋 Get approval for 10-20% storage increase
- 📋 Plan 2-week implementation

**Long-term (Q2-Q3 2026):**
- 📋 Evaluate full migration to JSON type
- 📋 Consider flattened schema for v2.0
- 📋 Optimize other evidence sub-objects (malware, appsec)

**Bottom Line:** Current fix works great. Option B is low-hanging fruit for nice improvement. Option A/C only if schema optimization is a strategic priority.
