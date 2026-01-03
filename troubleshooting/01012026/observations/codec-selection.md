# ClickHouse Codec Optimization Guide
## Data-Driven Codec Selection

---

## 📋 Table of Contents
1. [The Four Critical Data Characteristics](#the-four-critical-data-characteristics)
2. [Codec Decision Matrix](#codec-decision-matrix)
3. [String Column Deep Dive](#string-column-deep-dive)
4. [Numeric Column Analysis](#numeric-column-analysis)
5. [DateTime Optimization](#datetime-optimization)
6. [Testing & Validation Methodology](#testing--validation-methodology)
7. [Production Deployment Checklist](#production-deployment-checklist)
8. [Common Mistakes to Avoid](#common-mistakes-to-avoid)

---

## The Four Critical Data Characteristics

### 1. Cardinality (Uniqueness Percentage)

**What it is:** Ratio of unique values to total rows

```sql
-- Calculate cardinality
SELECT 
    column_name,
    uniqExact(column_name) AS unique_values,
    count() AS total_rows,
    round(unique_values::Float64 / total_rows * 100, 2) AS cardinality_pct
FROM your_table
GROUP BY column_name;
```

**Why it matters:**
- **<1% cardinality**: Dictionary encoding (`LowCardinality`) is 10-30x better than codecs
- **1-5% cardinality**: `LowCardinality` still wins, 5-10x compression
- **>50% cardinality**: Regular codecs, dictionary overhead too high

**Example:**
```
status column: 5 unique values in 10M rows = 0.00005% → Use LowCardinality(String)
user_id: 2M unique values in 10M rows = 20% → Use String CODEC(LZ4)
evidence: 9.5M unique values in 10M rows = 95% → String CODEC(ZSTD or LZ4)
```

---

### 2. Data Distribution (Patterns & Sorting)

**What it is:** How data is arranged and organized

**Check for:**
- **Sorted data**: Sequential IDs, timestamps
- **Random data**: UUIDs, hashes
- **Repetitive patterns**: JSON structure, repeated prefixes
- **Clustered data**: Geolocation, categories

```sql
-- Check if data is sorted (for integers/dates)
SELECT 
    column_name,
    count() AS total,
    countIf(column_name >= lag(column_name) OVER (ORDER BY primary_key)) AS sorted_count,
    round(sorted_count::Float64 / total * 100, 2) AS sorted_percentage
FROM your_table
LIMIT 100000;
```

**Why it matters:**
- **Sorted integers**: Delta codec gets 10-20x compression
- **Random UUIDs**: Delta codec actually HURTS compression (1.2x → 0.8x)
- **JSON strings**: ZSTD finds repetitive patterns, gets 6-8x
- **Random text**: LZ4 is faster, ZSTD only marginally better

---

### 3. String Patterns (Content Analysis)

**What it is:** The actual content structure of string columns

**Pattern Types:**

| Pattern | Example | Best Codec | Compression | Reasoning |
|---------|---------|------------|-------------|-----------|
| **UUID** | `550e8400-e29b-41d4-a716-446655440000` | `LZ4` | 2-3x | Random data, ZSTD overhead not worth it |
| **JSON** | `{"key": "value", "nested": {...}}` | `ZSTD(3)` | 6-8x | Repetitive structure, keys repeat |
| **URL** | `https://example.com/path/to/page` | `ZSTD(3)` | 5-7x | Common prefixes compress well |
| **Email** | `user@domain.com` | `LZ4` | 3-4x | Medium compression, speed matters |
| **Large Text** | 1000+ char paragraphs | `ZSTD(3)` | 6-10x | Worth CPU cost for savings |
| **Short Text** | <50 chars | `LZ4` | 3-4x | ZSTD overhead not worth it |
| **Base64** | `VGVzdCBkYXRh...` | `LZ4` | 2-3x | Already encoded, limited gains |
| **XML/HTML** | `<tag>content</tag>` | `ZSTD(3)` | 7-9x | Repetitive tags compress well |

**Detection Query:**
```sql
SELECT 
    column_name,
    CASE
        WHEN any(column) LIKE '%{%' OR any(column) LIKE '%[%' THEN 'JSON'
        WHEN length(any(column)) = 36 AND any(column) LIKE '%-%-%-%-%' THEN 'UUID'
        WHEN any(column) LIKE 'http%' THEN 'URL'
        WHEN any(column) LIKE '%@%' THEN 'Email'
        WHEN avg(length(column)) > 1000 THEN 'Large Text'
        WHEN any(column) LIKE '<%>%</%>' THEN 'XML/HTML'
        ELSE 'Regular String'
    END AS pattern_type,
    round(avg(length(column)), 1) AS avg_length,
    any(column) AS sample
FROM your_table
WHERE column IS NOT NULL
GROUP BY column_name;
```

---

### 4. Actual Current Compression (Baseline)

**What it is:** How well your data compresses RIGHT NOW

```sql
-- Check current compression by column
SELECT
    table,
    name AS column,
    compression_codec,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    round(sum(data_uncompressed_bytes) / nullIf(sum(data_compressed_bytes), 0), 2) AS ratio
FROM system.columns
LEFT JOIN system.parts USING (database, table)
WHERE active = 1 
  AND table = 'your_table'
GROUP BY table, name, compression_codec
ORDER BY sum(data_uncompressed_bytes) DESC;
```

**Why it matters:**
- Current ratio 1.2x → Data is already hard to compress (UUIDs, random data)
- Current ratio 3.5x → Adding codecs could get you to 6-8x
- Current ratio 5.0x → You're already optimized, diminishing returns

**Rule of thumb:**
- If current (no codec) ratio < 2x → Don't expect miracles, try LZ4 first
- If current ratio 2-4x → Good candidate for ZSTD(3)
- If current ratio > 4x → Already good, may not need codec change

---

## Codec Decision Matrix

### For STRING Columns

```
START: String column needs optimization
│
├─ Is cardinality < 5%?
│  ├─ YES → Use LowCardinality(String) CODEC(LZ4)
│  │        Expected: 5-10x compression
│  │        Example: status, country_code, category
│  │
│  └─ NO → Continue to pattern check
│          │
│          ├─ Pattern = UUID?
│          │  └─ String CODEC(LZ4)
│          │     Expected: 2-3x compression
│          │     Reason: Random data, ZSTD overhead not worth it
│          │
│          ├─ Pattern = JSON or Large Text (>500 chars)?
│          │  └─ String CODEC(ZSTD(3))
│          │     Expected: 6-10x compression
│          │     Reason: Repetitive structure
│          │
│          ├─ Pattern = URL or Email?
│          │  └─ String CODEC(ZSTD(3)) if size > 100MB
│          │     String CODEC(LZ4) if size < 100MB
│          │     Trade-off: CPU vs compression
│          │
│          └─ Regular text, high cardinality?
│             └─ String CODEC(LZ4) as default
│                Expected: 3-4x compression
│                Reason: Fast, good balance
```

### For NUMERIC Columns

```
START: Numeric column (Int, Float, Decimal, DateTime)
│
├─ Is it DateTime/Timestamp?
│  └─ YES → ALWAYS use CODEC(DoubleDelta, LZ4)
│            Expected: 10-15x compression
│            NO EXCEPTIONS - this is the best codec for timestamps
│
├─ Is it Integer and SORTED (95%+ sequential)?
│  └─ YES → CODEC(Delta, LZ4)
│            Expected: 8-12x compression
│            Example: auto-increment IDs, counters, sequential timestamps
│
├─ Is it Integer but RANDOM (UUIDs as Int, hashes)?
│  └─ YES → CODEC(LZ4) only
│            Expected: 2-3x compression
│            Reason: Delta HURTS random data compression
│
├─ Is it Float or Decimal?
│  └─ YES → CODEC(Gorilla, LZ4)
│            Expected: 5-7x compression
│            Reason: Gorilla optimized for floating point
│
└─ Is cardinality < 100 unique values?
   └─ YES → Consider changing to Enum type
             Expected: 10-20x compression
             Example: status codes, flags, categories
```

---

## String Column Deep Dive

### Step-by-Step Analysis Process

#### Step 1: Measure Cardinality
```sql
SELECT 
    'observation_group_key' AS column_name,
    uniqExact(observation_group_key) AS unique_values,
    count() AS total_rows,
    round(unique_values::Float64 / total_rows * 100, 2) AS cardinality_pct
FROM observations.measurement_id_lookup_3;
```

**Interpretation:**
- `0.01%` → Use `LowCardinality(String)` - massive win
- `2.5%` → Use `LowCardinality(String)` - still great
- `15%` → Borderline, test both approaches
- `60%` → Use regular `String` with appropriate codec

#### Step 2: Analyze Pattern
```sql
SELECT 
    length(observation_group_key) AS str_length,
    observation_group_key AS sample
FROM observations.measurement_id_lookup_3
LIMIT 10;
```

**Look for:**
- Length = 36 chars with dashes → UUID
- Contains `{` or `[` → JSON
- Starts with `http` → URL
- Length > 1000 → Large text
- Consistent length → Probably encoded data

#### Step 3: Check Current Compression
```sql
SELECT
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS ratio
FROM system.parts
WHERE active = 1 
  AND database = 'observations'
  AND table = 'measurement_id_lookup_3';
```

**If ratio is:**
- `< 1.5x` → Data is very random (UUIDs, hashes), use LZ4
- `2-3x` → Decent compression, codecs will help
- `> 4x` → Already compressing well, may not need changes

#### Step 4: Make Decision

**Decision Tree:**
```
Cardinality 0.5%, Pattern: status codes
→ LowCardinality(String) CODEC(LZ4)
→ Expected: 10x compression

Cardinality 45%, Pattern: UUIDs (36 chars, dashes)
→ String CODEC(LZ4)
→ Expected: 2-3x compression

Cardinality 80%, Pattern: JSON (contains {})
→ String CODEC(ZSTD(3))
→ Expected: 6-8x compression

Cardinality 65%, Pattern: Short text (avg 50 chars)
→ String CODEC(LZ4)
→ Expected: 3-4x compression
```

---

## Numeric Column Analysis

### Integer Columns - The Monotonicity Test

**Key Question:** Is this column sequential/sorted?

```sql
-- Test for monotonicity (sortedness)
SELECT 
    countIf(value >= previous_value) AS sorted_count,
    count() AS total_count,
    round(sorted_count::Float64 / total_count * 100, 2) AS sorted_percentage
FROM (
    SELECT 
        measurement_id,
        lag(measurement_id) OVER (ORDER BY inserted_at) AS previous_value
    FROM observations.measurement_id_lookup_3
    LIMIT 100000
);
```

**Decision:**
- `>95% sorted` → CODEC(Delta, LZ4) - excellent compression
- `70-95% sorted` → CODEC(Delta, LZ4) - good compression
- `<70% sorted` → CODEC(LZ4) only - Delta may hurt

**Examples:**
```sql
-- Auto-increment ID (100% sorted)
id Int64 CODEC(Delta, LZ4)  -- 10-15x compression

-- Random UUID as Int (0% sorted)
uuid_as_int UInt128 CODEC(LZ4)  -- 2-3x compression

-- User ID (partially sorted, clustered)
user_id Int64 CODEC(Delta, LZ4)  -- 5-8x compression
```

### Float/Decimal Columns

**Always use Gorilla codec:**
```sql
price Decimal(10,2) CODEC(Gorilla, LZ4)
temperature Float64 CODEC(Gorilla, LZ4)
```

**Why:** Gorilla is specifically designed for floating-point data
- Handles small deltas extremely well
- Works on scientific/sensor data
- Expected: 5-7x compression

---

## DateTime Optimization

### The Golden Rule

**ALL DateTime columns MUST use DoubleDelta:**

```sql
created_at DateTime CODEC(DoubleDelta, LZ4)
inserted_at DateTime64(3) CODEC(DoubleDelta, LZ4)
event_time DateTime64(6, 'UTC') CODEC(DoubleDelta, LZ4)
```

### Why DoubleDelta?

Timestamps have **constant intervals**:
```
Raw timestamps:     1704067200, 1704067201, 1704067202, 1704067203
Deltas:             1, 1, 1, 1
Delta of deltas:    0, 0, 0, 0  ← compresses to almost nothing!
```

**Expected compression:**
- Regular data: 10-15x
- High-frequency logs: 15-20x
- Irregular timestamps: 8-12x

**NO EXCEPTIONS** - this is always the right choice for DateTime.

---

## Testing & Validation Methodology

### Before Changing Production

#### 1. Create Test Table
```sql
-- Sample your data
CREATE TABLE test_codec_analysis AS 
SELECT * FROM observations.measurement_id_lookup_3 
LIMIT 10000000;  -- 10M rows for realistic test
```

#### 2. Test Different Codecs
```sql
-- Test LZ4
ALTER TABLE test_codec_analysis 
MODIFY COLUMN observation_group_key String CODEC(LZ4);

-- Check compression
SELECT 
    formatReadableSize(sum(data_compressed_bytes)) AS size_lz4
FROM system.parts 
WHERE table = 'test_codec_analysis' AND active = 1;

-- Test ZSTD
ALTER TABLE test_codec_analysis 
MODIFY COLUMN observation_group_key String CODEC(ZSTD(3));

SELECT 
    formatReadableSize(sum(data_compressed_bytes)) AS size_zstd
FROM system.parts 
WHERE table = 'test_codec_analysis' AND active = 1;
```

#### 3. Benchmark Query Performance
```sql
-- Test query speed with LZ4
SET max_threads = 1;  -- Consistent results
SELECT count() FROM test_codec_analysis WHERE observation_group_key = 'some_value';
-- Note the execution time

-- Test query speed with ZSTD
-- Note if decompression slows queries significantly
```

#### 4. Calculate ROI
```
Compression savings: 1.2TB → 400GB = 800GB saved
ZSTD CPU cost: +5% query latency
Decision: Worth it if storage cost > compute cost
```

---

## Production Deployment Checklist

### Pre-Deployment

- [ ] **Analyzed cardinality** for all columns
- [ ] **Identified patterns** (UUID, JSON, etc.)
- [ ] **Tested codecs** on sample data
- [ ] **Measured query impact** (decompression overhead)
- [ ] **Calculated expected savings** (GB/TB)
- [ ] **Prioritized columns** by impact (largest savings first)
- [ ] **Prepared ALTER statements**
- [ ] **Scheduled maintenance window** (low-traffic period)

### Deployment Steps

#### Step 1: Test on Replica
```sql
-- On replica only (NOT leader)
ALTER TABLE observations.measurement_id_lookup_3 
MODIFY COLUMN observation_group_key String CODEC(LZ4);

-- Monitor mutation progress
SELECT * FROM system.mutations 
WHERE table = 'measurement_id_lookup_3' AND is_done = 0;
```

#### Step 2: Validate Replica
```sql
-- Check compression
SELECT 
    formatReadableSize(sum(data_compressed_bytes)) AS new_size
FROM system.parts 
WHERE table = 'measurement_id_lookup_3' AND active = 1;

-- Run test queries
SELECT count() FROM observations.measurement_id_lookup_3;
SELECT * FROM observations.measurement_id_lookup_3 LIMIT 100;
```

#### Step 3: Apply to Leader
```sql
-- Only after replica validation
ALTER TABLE observations.measurement_id_lookup_3 
MODIFY COLUMN observation_group_key String CODEC(LZ4);
```

#### Step 4: Monitor
```bash
# Watch merge progress
watch -n 5 "clickhouse-client --query='SELECT * FROM system.merges'"

# Check parts count
watch -n 10 "clickhouse-client --query='SELECT count() FROM system.parts WHERE table=\\'measurement_id_lookup_3\\' AND active=1'"
```

### Post-Deployment

- [ ] **Verify compression ratio** improved
- [ ] **Measure query latency** (before/after)
- [ ] **Document savings** (GB saved, % improvement)
- [ ] **Update runbooks** with new codec strategy
- [ ] **Monitor for 24-48 hours** for any issues

---

## Common Mistakes to Avoid

### ❌ Mistake #1: Using ZSTD for Everything
**Wrong:**
```sql
-- "ZSTD compresses better, so use it everywhere!"
ALTER TABLE users MODIFY COLUMN user_id String CODEC(ZSTD(3));
```

**Why it's wrong:**
- UUIDs don't compress well with ZSTD
- Adds decompression CPU overhead
- LZ4 is faster with similar ratio for UUIDs

**Right:**
```sql
-- Analyze first, then decide
ALTER TABLE users MODIFY COLUMN user_id String CODEC(LZ4);  -- UUIDs
ALTER TABLE logs MODIFY COLUMN json_payload String CODEC(ZSTD(3));  -- JSON
```

---

### ❌ Mistake #2: Ignoring LowCardinality
**Wrong:**
```sql
-- "I'll just add a codec"
ALTER TABLE events MODIFY COLUMN status String CODEC(LZ4);
-- 5 unique values in 100M rows
```

**Why it's wrong:**
- Cardinality is 0.000005%
- LowCardinality would give 10-30x compression
- Regular codec only gives 3-4x

**Right:**
```sql
-- Check cardinality first
ALTER TABLE events MODIFY COLUMN status LowCardinality(String) CODEC(LZ4);
-- Now getting 15-20x compression
```

---

### ❌ Mistake #3: Forgetting DoubleDelta for DateTime
**Wrong:**
```sql
-- "LZ4 should be fine for timestamps"
ALTER TABLE logs MODIFY COLUMN timestamp DateTime CODEC(LZ4);
```

**Why it's wrong:**
- Missing 10x compression opportunity
- DoubleDelta is specifically designed for this

**Right:**
```sql
-- ALWAYS use DoubleDelta for DateTime
ALTER TABLE logs MODIFY COLUMN timestamp DateTime CODEC(DoubleDelta, LZ4);
```

---

### ❌ Mistake #4: Applying Changes During Peak Traffic
**Wrong:**
```bash
# Running ALTER during business hours
ALTER TABLE huge_table MODIFY COLUMN col String CODEC(ZSTD(3));
```

**Why it's wrong:**
- ALTER rebuilds ALL parts (can take hours)
- Blocks merges and can cause "too many parts" errors
- High CPU/disk I/O during peak load

**Right:**
```bash
# Schedule during maintenance window
# Run on replica first
# Monitor system.mutations progress
```

---

### ❌ Mistake #5: Not Testing First
**Wrong:**
```sql
-- "The script said ZSTD, so I'll run it"
ALTER TABLE production.critical_table MODIFY COLUMN data String CODEC(ZSTD(3));
```

**Why it's wrong:**
- No validation of actual compression improvement
- Unknown query performance impact
- Can't rollback easily (requires rebuilding parts)

**Right:**
```sql
-- Test on sample first
CREATE TABLE test_table AS SELECT * FROM production.critical_table LIMIT 1000000;
ALTER TABLE test_table MODIFY COLUMN data String CODEC(ZSTD(3));
-- Measure, validate, then apply to production
```

---

## Quick Reference Cheat Sheet

### String Codecs
| Cardinality | Pattern | Codec | Compression |
|-------------|---------|-------|-------------|
| <5% | Any | `LowCardinality(String) CODEC(LZ4)` | 5-15x |
| Any | UUID | `String CODEC(LZ4)` | 2-3x |
| Any | JSON | `String CODEC(ZSTD(3))` | 6-8x |
| Any | Large (>500 chars) | `String CODEC(ZSTD(3))` | 6-10x |
| >50% | Short (<100 chars) | `String CODEC(LZ4)` | 3-4x |

### Numeric Codecs
| Type | Condition | Codec | Compression |
|------|-----------|-------|-------------|
| DateTime | Always | `CODEC(DoubleDelta, LZ4)` | 10-15x |
| Int | Sorted >95% | `CODEC(Delta, LZ4)` | 8-12x |
| Int | Random | `CODEC(LZ4)` | 2-3x |
| Float/Decimal | Always | `CODEC(Gorilla, LZ4)` | 5-7x |

### Safety Rules
1. ✅ **Always** test on replica first
2. ✅ **Always** analyze cardinality before choosing codec
3. ✅ **Always** use DoubleDelta for DateTime
4. ✅ **Always** schedule ALTERs during low-traffic windows
5. ❌ **Never** apply codec changes blindly
6. ❌ **Never** run ALTERs on leader and replica simultaneously

---

## Measuring Success

### Before Optimization
```sql
SELECT 
    formatReadableSize(sum(data_uncompressed_bytes)) AS before_uncompressed,
    formatReadableSize(sum(data_compressed_bytes)) AS before_compressed,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS before_ratio
FROM system.parts 
WHERE active = 1 AND table = 'your_table';
```

### After Optimization
```sql
SELECT 
    formatReadableSize(sum(data_uncompressed_bytes)) AS after_uncompressed,
    formatReadableSize(sum(data_compressed_bytes)) AS after_compressed,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS after_ratio
FROM system.parts 
WHERE active = 1 AND table = 'your_table';
```

### Calculate Savings
```
Before: 2.4TB compressed (ratio: 3.2x)
After: 890GB compressed (ratio: 8.5x)
Savings: 1.51TB (63% reduction)
Monthly cost savings: $150-300 depending on provider
```

### Present to Leadership
> "Optimized codec strategy on observations tables resulted in 1.5TB storage reduction (63% improvement) with no impact on query performance. Estimated annual savings: $2,400 in infrastructure costs."

---
