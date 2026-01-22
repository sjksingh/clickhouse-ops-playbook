# ClickHouse JSON Deep Dive Lab
## Hands-On Workshop: 

### Workshop Overview
**Topics Covered:**
- ClickHouse ReplicatedMergeTree tables
- JSON data handling in String vs JSON columns
- Nested JSON extraction limitations
- Performance optimization
- Schema migration strategies

---

## Lab Setup (15 minutes)

### Prerequisites
```bash
# Ensure ClickHouse is running
clickhouse-client --query "SELECT version()"

# Create workshop database
clickhouse-client --query "CREATE DATABASE IF NOT EXISTS workshop"
```

---

## Part 1: Reproduce Priyanka's Issue (30 minutes)

### Step 1.1: Create the Table

```sql
-- Switch to workshop database
USE workshop;

-- Create table mimicking production schema
CREATE TABLE security_observations
(
    `status` String,
    `organization_domain` String,
    `issue_type` String,
    `first_seen` DateTime,
    `last_seen` DateTime,
    `asset` String,
    `evidence` String,  -- ⚠️ This is the problematic String column
    `measurement_id` String,
    `ingest_date` DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}')
PARTITION BY toYYYYMM(ingest_date)
ORDER BY (organization_domain, issue_type, measurement_id, ingest_date)
SETTINGS index_granularity = 8192;
```

**💡 Discussion Point:** Why String column for JSON? (Legacy systems, schema flexibility, initial MVP)

---

### Step 1.2: Insert Sample Data

```sql
-- Insert breach data with deeply nested JSON
INSERT INTO workshop.security_observations VALUES
(
    'active',
    'acmecorp.com',
    'confirmed_first_party_breach',
    now() - INTERVAL 30 DAY,
    now() - INTERVAL 1 DAY,
    'acmecorp.com',
    '{"evidence":{"breach":{"summary":"Acme Corp experienced a data breach affecting customer records","breach_date":"2024-12-01T00:00:00","originating_party":"acmecorp.com","cluster_id":"abc-123-def","breach_items":[{"breach_date":"2024-12-01T00:00:00","item_id":"item1","link":"https://news.example.com/acme-breach","records_lost":50000,"created_at":"2024-12-02T10:00:00","info_leaked":["email","password"],"source_type":"news","title":"Acme Corp Data Breach Affects 50K Users","affected_parties":["acmecorp.com"],"originating_party":"acmecorp.com","cluster_id":"abc-123-def","threat_actors":["APT29"],"updated_at":"2024-12-02T10:00:00","source_reliability":0.95,"published_date":"2024-12-02T00:00:00"},{"breach_date":"2024-12-01T00:00:00","item_id":"item2","link":"https://techcrunch.example.com/acme-breach","records_lost":50000,"created_at":"2024-12-03T14:30:00","info_leaked":["email","password","phone"],"source_type":"news","title":"Breaking: Acme Corp Confirms Security Incident","affected_parties":["acmecorp.com"],"originating_party":"acmecorp.com","cluster_id":"abc-123-def","threat_actors":["APT29"],"updated_at":"2024-12-03T14:30:00","source_reliability":0.98,"published_date":"2024-12-03T00:00:00"}],"created_at":"2024-12-01T08:00:00","records_lost":50000,"title":"acmecorp.com Breach - December 2024","published_date":"2024-12-02T00:00:00","confirmed":true},"malware":null,"appsec":null}}',
    '550e8400-e29b-41d4-a716-446655440001',
    now()
),
(
    'active',
    'techco.io',
    'confirmed_first_party_breach',
    now() - INTERVAL 45 DAY,
    now() - INTERVAL 2 DAY,
    'techco.io',
    '{"evidence":{"breach":{"summary":"TechCo suffered a ransomware attack with data exfiltration","breach_date":"2024-11-15T00:00:00","originating_party":"techco.io","cluster_id":"xyz-789-ghi","breach_items":[{"breach_date":"2024-11-15T00:00:00","item_id":"item3","link":"https://bleepingcomputer.example.com/techco-ransomware","records_lost":125000,"created_at":"2024-11-16T09:00:00","info_leaked":["ssn","credit_card","address"],"source_type":"news","title":"TechCo Hit by Ransomware, 125K Records Stolen","affected_parties":["techco.io"],"originating_party":"techco.io","cluster_id":"xyz-789-ghi","threat_actors":["LockBit","BlackCat"],"updated_at":"2024-11-16T09:00:00","source_reliability":1.0,"published_date":"2024-11-16T00:00:00"},{"breach_date":"2024-11-15T00:00:00","item_id":"item4","link":"https://krebsonsecurity.example.com/techco-breach","records_lost":125000,"created_at":"2024-11-17T11:20:00","info_leaked":["ssn","credit_card","address","phone"],"source_type":"blog","title":"Analysis: TechCo Ransomware Attack Details","affected_parties":["techco.io"],"originating_party":"techco.io","cluster_id":"xyz-789-ghi","threat_actors":["LockBit"],"updated_at":"2024-11-17T11:20:00","source_reliability":0.92,"published_date":"2024-11-17T00:00:00"},{"breach_date":"2024-11-15T00:00:00","item_id":"item5","link":"https://securityweek.example.com/techco-incident","records_lost":125000,"created_at":"2024-11-18T16:45:00","info_leaked":["ssn","credit_card"],"source_type":"news","title":"TechCo Breach: What We Know So Far","affected_parties":["techco.io","partner1.com","partner2.com"],"originating_party":"techco.io","cluster_id":"xyz-789-ghi","threat_actors":["LockBit","BlackCat"],"updated_at":"2024-11-18T16:45:00","source_reliability":0.89,"published_date":"2024-11-18T00:00:00"}],"created_at":"2024-11-15T10:00:00","records_lost":125000,"title":"techco.io Ransomware Breach - November 2024","published_date":"2024-11-16T00:00:00","confirmed":true},"malware":null,"appsec":null}}',
    '550e8400-e29b-41d4-a716-446655440002',
    now()
),
(
    'active',
    'healthsys.com',
    'confirmed_first_party_breach',
    now() - INTERVAL 60 DAY,
    now() - INTERVAL 3 DAY,
    'healthsys.com',
    '{"evidence":{"breach":{"summary":"HealthSys medical records exposed through misconfigured database","breach_date":"2024-10-20T00:00:00","originating_party":"healthsys.com","cluster_id":"med-456-abc","breach_items":[{"breach_date":"2024-10-20T00:00:00","item_id":"item6","link":"https://hipaa.example.com/healthsys-breach","records_lost":250000,"created_at":"2024-10-21T08:00:00","info_leaked":["medical_records","ssn","insurance"],"source_type":"regulatory","title":"HealthSys Reports HIPAA Breach Affecting 250K Patients","affected_parties":["healthsys.com"],"originating_party":"healthsys.com","cluster_id":"med-456-abc","threat_actors":[],"updated_at":"2024-10-21T08:00:00","source_reliability":1.0,"published_date":"2024-10-21T00:00:00"}],"created_at":"2024-10-20T12:00:00","records_lost":250000,"title":"healthsys.com Medical Records Breach - October 2024","published_date":"2024-10-21T00:00:00","confirmed":true},"malware":null,"appsec":null}}',
    '550e8400-e29b-41d4-a716-446655440003',
    now()
),
(
    'active',
    'retailgiant.com',
    'confirmed_third_party_breach',
    now() - INTERVAL 20 DAY,
    now() - INTERVAL 1 DAY,
    'retailgiant.com',
    '{"evidence":{"breach":{"summary":"RetailGiant customers affected through third-party payment processor breach","breach_date":"2024-12-10T00:00:00","originating_party":"paymentprocessor.com","cluster_id":"retail-999-xyz","breach_items":[{"breach_date":"2024-12-10T00:00:00","item_id":"item7","link":"https://retail-news.example.com/payment-breach","records_lost":500000,"created_at":"2024-12-11T10:00:00","info_leaked":["credit_card","billing_address"],"source_type":"news","title":"Payment Processor Breach Affects Major Retailers","affected_parties":["retailgiant.com","competitor1.com","competitor2.com"],"originating_party":"paymentprocessor.com","cluster_id":"retail-999-xyz","threat_actors":["FIN7"],"updated_at":"2024-12-11T10:00:00","source_reliability":0.94,"published_date":"2024-12-11T00:00:00"},{"breach_date":"2024-12-10T00:00:00","item_id":"item8","link":"https://payments-journal.example.com/major-breach","records_lost":500000,"created_at":"2024-12-12T14:00:00","info_leaked":["credit_card","billing_address","email"],"source_type":"industry","title":"Analysis: Payment Processor Security Failure","affected_parties":["retailgiant.com","competitor1.com"],"originating_party":"paymentprocessor.com","cluster_id":"retail-999-xyz","threat_actors":["FIN7"],"updated_at":"2024-12-12T14:00:00","source_reliability":0.88,"published_date":"2024-12-12T00:00:00"}],"created_at":"2024-12-10T15:00:00","records_lost":500000,"title":"paymentprocessor.com Third-Party Breach - December 2024","published_date":"2024-12-11T00:00:00","confirmed":true},"malware":null,"appsec":null}}',
    '550e8400-e29b-41d4-a716-446655440004',
    now()
),
(
    'active',
    'fintech.co',
    'confirmed_first_party_breach',
    now() - INTERVAL 10 DAY,
    now(),
    'fintech.co',
    '{"evidence":{"breach":{"summary":"FinTech API vulnerability exploited, customer financial data accessed","breach_date":"2024-12-20T00:00:00","originating_party":"fintech.co","cluster_id":"fin-111-222","breach_items":[{"breach_date":"2024-12-20T00:00:00","item_id":"item9","link":"https://finance-security.example.com/fintech-api-breach","records_lost":75000,"created_at":"2024-12-21T09:30:00","info_leaked":["bank_account","transaction_history","ssn"],"source_type":"news","title":"FinTech Startup Discloses API Breach","affected_parties":["fintech.co"],"originating_party":"fintech.co","cluster_id":"fin-111-222","threat_actors":[],"updated_at":"2024-12-21T09:30:00","source_reliability":0.96,"published_date":"2024-12-21T00:00:00"},{"breach_date":"2024-12-20T00:00:00","item_id":"item10","link":"https://venturebeat.example.com/fintech-breach","records_lost":75000,"created_at":"2024-12-22T11:00:00","info_leaked":["bank_account","transaction_history"],"source_type":"news","title":"FinTech Security Incident: What Customers Need to Know","affected_parties":["fintech.co"],"originating_party":"fintech.co","cluster_id":"fin-111-222","threat_actors":[],"updated_at":"2024-12-22T11:00:00","source_reliability":0.91,"published_date":"2024-12-22T00:00:00"},{"breach_date":"2024-12-20T00:00:00","item_id":"item11","link":"https://threatpost.example.com/fintech-analysis","records_lost":75000,"created_at":"2024-12-23T15:20:00","info_leaked":["bank_account","ssn"],"source_type":"blog","title":"Technical Analysis: FinTech API Vulnerability","affected_parties":["fintech.co"],"originating_party":"fintech.co","cluster_id":"fin-111-222","threat_actors":["Initial Access Brokers"],"updated_at":"2024-12-23T15:20:00","source_reliability":0.87,"published_date":"2024-12-23T00:00:00"},{"breach_date":"2024-12-20T00:00:00","item_id":"item12","link":"https://darkreading.example.com/fintech-incident","records_lost":75000,"created_at":"2024-12-24T10:45:00","info_leaked":["bank_account","transaction_history","ssn","email"],"source_type":"news","title":"FinTech Breach Highlights API Security Risks","affected_parties":["fintech.co"],"originating_party":"fintech.co","cluster_id":"fin-111-222","threat_actors":["Initial Access Brokers"],"updated_at":"2024-12-24T10:45:00","source_reliability":0.93,"published_date":"2024-12-24T00:00:00"}],"created_at":"2024-12-20T18:00:00","records_lost":75000,"title":"fintech.co API Breach - December 2024","published_date":"2024-12-21T00:00:00","confirmed":true},"malware":null,"appsec":null}}',
    '550e8400-e29b-41d4-a716-446655440005',
    now()
);
```

**💡 Discussion Point:** Notice the JSON structure - it's 3 levels deep: `evidence → breach → breach_items`

---

### Step 1.3: Verify Data Inserted

```sql
-- Quick verification
SELECT 
    organization_domain,
    issue_type,
    length(evidence) as evidence_size,
    substring(evidence, 1, 100) as evidence_preview
FROM workshop.security_observations
ORDER BY organization_domain;
```

**Expected Output:** 5 rows with evidence sizes ranging from ~2KB to ~4KB

---

### Step 1.4: Try  Original Query (This FAILS!)

```sql
-- This is what Priyanka tried - IT WILL RETURN EMPTY ARRAYS!
SELECT 
    organization_domain,
    issue_type,
    
    -- Try to extract breach_items using dot notation (FAILS)
    JSONExtractArrayRaw(evidence, 'evidence.breach.breach_items') as breach_items_broken,
    
    -- Try using JSONHas to check (FAILS to detect)
    JSONHas(evidence, 'evidence.breach') as has_breach,
    JSONHas(evidence, 'evidence.breach.breach_items') as has_breach_items
    
FROM workshop.security_observations
ORDER BY organization_domain;
```

**Expected Output:**
```
breach_items_broken: []  (empty array!)
has_breach: 0            (false!)
has_breach_items: 0      (false!)
```

**💡 Discussion Point:** 
- Why does this fail? The data IS there!
- This is the exact problem Priyanka encountered
- ClickHouse can't navigate multi-level paths with dot notation on String columns

---

## Part 2: Diagnostic Process (30 minutes)

### Step 2.1: Verify Data Exists

```sql
-- Let's confirm the JSON actually contains breach data
SELECT 
    organization_domain,
    evidence LIKE '%breach_items%' as contains_breach_items,
    evidence LIKE '%breach%' as contains_breach,
    length(evidence) as size
FROM workshop.security_observations;
```

**Expected:** All rows should show `contains_breach_items: 1`, `contains_breach: 1`

**💡 Discussion Point:** Data is definitely there, so why can't we extract it?

---

### Step 2.2: Test Single-Level Extraction

```sql
-- Extract evidence object (first level) - THIS WORKS
SELECT 
    organization_domain,
    JSONExtractRaw(evidence, 'evidence') as evidence_obj,
    length(JSONExtractRaw(evidence, 'evidence')) as evidence_obj_size
FROM workshop.security_observations
LIMIT 2;
```

**Expected:** Returns the inner evidence object successfully

---

### Step 2.3: Test Two-Level Extraction

```sql
-- Extract evidence, then breach (two levels) - THIS WORKS
SELECT 
    organization_domain,
    JSONExtractRaw(evidence, 'evidence') as evidence_obj,
    JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach') as breach_obj,
    length(JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach')) as breach_obj_size
FROM workshop.security_observations
LIMIT 2;
```

**Expected:** Returns the breach object successfully

**💡 Discussion Point:** Single-level extraction works, multi-level paths don't!

---

### Step 2.4: Test Three-Level Extraction (The Fix!)

```sql
-- Extract evidence → breach → breach_items (three levels) - THIS WORKS!
SELECT 
    organization_domain,
    JSONExtractArrayRaw(
        JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
        'breach_items'
    ) as breach_items,
    length(JSONExtractArrayRaw(
        JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
        'breach_items'
    )) as breach_items_count
FROM workshop.security_observations
ORDER BY organization_domain;
```

**Expected Output:**
```
acmecorp.com:     breach_items_count: 2
fintech.co:       breach_items_count: 4
healthsys.com:    breach_items_count: 1
retailgiant.com:  breach_items_count: 2
techco.io:        breach_items_count: 3
```

**💡 Discussion Point:** SUCCESS! This is the fix - extract one level at a time!

---

## Part 3: Implement The Full Fix (45 minutes)

### Step 3.1: Complete Working Query

```sql
SELECT 
    organization_domain,
    issue_type,
    first_seen,
    last_seen,
    measurement_id,
    
    -- =========================
    -- Breach Fields (FIXED)
    -- =========================
    
    -- Scalar fields
    JSONExtractString(
        JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
        'cluster_id'
    ) as cluster_id,
    
    JSONExtractString(
        JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
        'originating_party'
    ) as originating_party,
    
    JSONExtractUInt(
        JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
        'records_lost'
    ) as records_lost,
    
    JSONExtractBool(
        JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
        'confirmed'
    ) as confirmed,
    
    -- Array of breach items with full details
    arrayMap(b ->
        tuple(
            JSONExtractString(b, 'title'),
            JSONExtractString(b, 'link'),
            JSONExtractString(b, 'source_type'),
            JSONExtract(b, 'affected_parties', 'Array(String)'),
            JSONExtract(b, 'threat_actors', 'Array(String)'),
            JSONExtractUInt(b, 'records_lost'),
            JSONExtractFloat(b, 'source_reliability'),
            JSONExtract(b, 'info_leaked', 'Array(String)')
        ),
        JSONExtractArrayRaw(
            JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
            'breach_items'
        )
    ) as breach_items_detailed,
    
    -- Count of breach items
    length(JSONExtractArrayRaw(
        JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
        'breach_items'
    )) as breach_items_count

FROM workshop.security_observations
ORDER BY records_lost DESC;
```

**💡 Activity:** Have participants run this query and examine the output

---

### Step 3.2: Performance Benchmark (Baseline)

```sql
-- Benchmark the fixed query
SELECT 
    count() as total_rows,
    sum(breach_items_count) as total_breach_items,
    avg(breach_items_count) as avg_items_per_breach,
    max(breach_items_count) as max_items
FROM (
    SELECT 
        length(JSONExtractArrayRaw(
            JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
            'breach_items'
        )) as breach_items_count
    FROM workshop.security_observations
);
```

**Note the execution time** - We'll compare this later!

---

## Part 4: Schema Optimization - Materialized Column (45 minutes)

### Step 4.1: Add Materialized JSON Column

```sql
-- Add a materialized column that parses JSON automatically
ALTER TABLE workshop.security_observations
ADD COLUMN evidence_json JSON MATERIALIZED 
    if(evidence != '', parseJSON(evidence), null);
```

**💡 Discussion Point:** 
- What is a MATERIALIZED column?
- It's computed automatically on INSERT
- No need to backfill existing data (computed on-the-fly when queried)

---

### Step 4.2: Verify Materialized Column

```sql
-- Check that the materialized column is working
SELECT 
    organization_domain,
    evidence_json.breach.cluster_id as cluster_id,
    evidence_json.breach.originating_party as originating_party,
    evidence_json.breach.records_lost as records_lost,
    length(evidence_json.breach.breach_items) as breach_items_count
FROM workshop.security_observations
ORDER BY organization_domain;
```

**Expected:** All data populates correctly!

**💡 Discussion Point:** Notice how much simpler the syntax is!

---

### Step 4.3: Query Comparison - Old vs New

```sql
-- OLD METHOD (nested JSONExtractRaw)
-- Time this query!
SELECT 
    organization_domain,
    arrayMap(b ->
        tuple(
            JSONExtractString(b, 'title'),
            JSONExtractString(b, 'link'),
            JSONExtractString(b, 'source_type')
        ),
        JSONExtractArrayRaw(
            JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
            'breach_items'
        )
    ) as breach_items
FROM workshop.security_observations;
```

```sql
-- NEW METHOD (materialized column)
-- Time this query!
SELECT 
    organization_domain,
    arrayMap(b ->
        tuple(
            b.title,
            b.link,
            b.source_type
        ),
        evidence_json.breach.breach_items
    ) as breach_items
FROM workshop.security_observations;
```

**💡 Activity:** 
1. Have participants time both queries
2. Compare execution times
3. Discuss code readability improvement

---

### Step 4.4: Complex Query with Materialized Column

```sql
-- Extract all breach items with threat actors
SELECT 
    organization_domain,
    issue_type,
    evidence_json.breach.cluster_id as cluster_id,
    evidence_json.breach.records_lost as total_records_lost,
    
    -- Flatten all threat actors from all breach items
    arrayDistinct(arrayFlatten(
        arrayMap(item -> item.threat_actors, evidence_json.breach.breach_items)
    )) as all_threat_actors,
    
    -- Flatten all affected parties
    arrayDistinct(arrayFlatten(
        arrayMap(item -> item.affected_parties, evidence_json.breach.breach_items)
    )) as all_affected_parties,
    
    -- Get highest source reliability
    arrayMax(
        arrayMap(item -> item.source_reliability, evidence_json.breach.breach_items)
    ) as max_reliability,
    
    -- Count news sources vs blogs
    countIf(item -> item.source_type = 'news', evidence_json.breach.breach_items) as news_sources,
    countIf(item -> item.source_type = 'blog', evidence_json.breach.breach_items) as blog_sources

FROM workshop.security_observations
ORDER BY total_records_lost DESC;
```

**💡 Discussion Point:** This would be EXTREMELY complex with the old nested extraction method!

---

## Part 5: Advanced - Full Schema Migration (30 minutes)

### Step 5.1: Create New Table with Native JSON

```sql
-- Create a new table with JSON type from the start
CREATE TABLE workshop.security_observations_v2
(
    `status` String,
    `organization_domain` String,
    `issue_type` String,
    `first_seen` DateTime,
    `last_seen` DateTime,
    `asset` String,
    `evidence` JSON,  -- ✅ Native JSON type!
    `measurement_id` String,
    `ingest_date` DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}')
PARTITION BY toYYYYMM(ingest_date)
ORDER BY (organization_domain, issue_type, measurement_id, ingest_date)
SETTINGS index_granularity = 8192;
```

---

### Step 5.2: Migrate Data to New Table

```sql
-- Migrate data from old table to new table
INSERT INTO workshop.security_observations_v2
SELECT 
    status,
    organization_domain,
    issue_type,
    first_seen,
    last_seen,
    asset,
    if(evidence != '', parseJSON(evidence), null) as evidence,
    measurement_id,
    ingest_date
FROM workshop.security_observations;
```

---

### Step 5.3: Query the New Table

```sql
-- Now queries are incredibly simple!
SELECT 
    organization_domain,
    
    -- Direct JSON path access
    evidence.breach.cluster_id as cluster_id,
    evidence.breach.records_lost as records_lost,
    evidence.breach.confirmed as confirmed,
    
    -- Array access is natural
    evidence.breach.breach_items as all_items,
    length(evidence.breach.breach_items) as item_count,
    
    -- Array operations are clean
    arrayMap(item -> item.title, evidence.breach.breach_items) as all_titles
    
FROM workshop.security_observations_v2
ORDER BY organization_domain;
```

**💡 Discussion Point:** This is the cleanest approach, but requires migration

---

## Part 6: Performance Testing & Comparison (30 minutes)

### Step 6.1: Create Performance Test Dataset

```sql
-- Insert 10,000 more rows for performance testing
-- (We'll use a simple script to generate varied data)

INSERT INTO workshop.security_observations
SELECT 
    status,
    concat('company', toString(number % 1000), '.com') as organization_domain,
    if(number % 3 = 0, 'confirmed_first_party_breach', 'confirmed_third_party_breach') as issue_type,
    now() - INTERVAL (number % 90) DAY as first_seen,
    now() - INTERVAL (number % 10) DAY as last_seen,
    concat('company', toString(number % 1000), '.com') as asset,
    concat('{"evidence":{"breach":{"summary":"Breach ', toString(number), '","breach_date":"2024-12-01T00:00:00","originating_party":"company', toString(number % 1000), '.com","cluster_id":"cluster-', toString(number), '","breach_items":[{"breach_date":"2024-12-01T00:00:00","item_id":"item', toString(number), '","link":"https://example.com/breach', toString(number), '","records_lost":', toString((number % 10 + 1) * 1000), ',"created_at":"2024-12-02T10:00:00","info_leaked":["email","password"],"source_type":"news","title":"Breach Report ', toString(number), '","affected_parties":["company', toString(number % 1000), '.com"],"originating_party":"company', toString(number % 1000), '.com","cluster_id":"cluster-', toString(number), '","threat_actors":["APT', toString(number % 50), '"],"updated_at":"2024-12-02T10:00:00","source_reliability":0.', toString(90 + (number % 10)), ',"published_date":"2024-12-02T00:00:00"}],"created_at":"2024-12-01T08:00:00","records_lost":', toString((number % 10 + 1) * 1000), ',"title":"Breach ', toString(number), '","published_date":"2024-12-02T00:00:00","confirmed":true},"malware":null,"appsec":null}}') as evidence,
    concat('550e8400-e29b-41d4-a716-4466554400', lpad(toString(number), 2, '0')) as measurement_id,
    now() as ingest_date
FROM numbers(10000);
```

---

### Step 6.2: Benchmark Queries

```sql
-- Test 1: Original broken query (returns empty)
-- Measure execution time
SELECT count(*)
FROM (
    SELECT JSONExtractArrayRaw(evidence, 'evidence.breach.breach_items') as items
    FROM workshop.security_observations
)
WHERE length(items) > 0;
-- Expected: 0 rows (broken)

-- Test 2: Fixed nested extraction
-- Measure execution time
SELECT count(*), sum(item_count)
FROM (
    SELECT 
        length(JSONExtractArrayRaw(
            JSONExtractRaw(JSONExtractRaw(evidence, 'evidence'), 'breach'),
            'breach_items'
        )) as item
```
