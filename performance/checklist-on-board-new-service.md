# 📊 ClickHouse Ingestion & Partitioning Guide

## Production Architecture Guidance for High-Volume & Bursty Workloads (DBRE Edition)

This guide explains how to design ingestion and storage in ClickHouse so that the system remains **stable, predictable, and scalable under bursty or continuous write workloads**.

It is written from a **production DBRE perspective**:

> We don’t optimize for theoretical perfect plans —
> we optimize for **predictability, guardrails, and bounded blast radius** when load or estimates are wrong.

---

## 🧭 Goals of This Guide

This document helps engineers avoid failure patterns we repeatedly see in real systems:

* Small-part explosion & endless merge backlogs
* Hot partitions and overloaded merge queues
* Slow queries due to thousands of files per range
* Write amplification / CPU saturation
* Insert throttling & ingestion stalls
* Out-of-control storage growth

It also defines **what we expect from new services onboarding to the platform**.

---

# 1️⃣ Partitioning — The Most Important Design Decision

### ❌ Anti-pattern: Yearly partitions

```sql
PARTITION BY toYear(date)
```

Why this fails in production:

* All activity for a year ends up in one partition
* Merges occur **per partition** → very large jobs
* Backfills & late data amplify write pressure
* Drops / retention operations become coarse-grained
* Operational blast radius becomes **cluster-scale**

---

### 🧠 Partitioning Rules We Enforce

| Principle                                            | Reason                   |
| ---------------------------------------------------- | ------------------------ |
| Partitions must align to query time ranges           | Enables pruning          |
| Hot data must live in **small, rotating partitions** | Reduces merge contention |
| Drop operations must be scoped                       | Safer retention          |
| Partition strategy must support 10× growth           | Future-proofing          |

---

### 🎯 Recommended Defaults (Platform Baseline)

| Workload                            | Partition Strategy           |
| ----------------------------------- | ---------------------------- |
| Analytics or rolling window queries | `toYYYYMM()` (monthly)       |
| Short-range time analytics          | weekly partitions            |
| Very high ingest / real-time        | daily partitions (carefully) |

> Monthly is the **sweet spot** for most read-heavy workloads.

---

# 2️⃣ Part Size — The Stability Envelope

| Metric | Minimum | Optimal   | Upper Risk |
| ------ | ------- | --------- | ---------- |
| Rows   | 100K    | 1–10M     | 100M       |
| Size   | 10MB    | 100MB–1GB | 10GB       |

Too many tiny parts → merge storms, CPU waste
Too large parts → slow merges, memory spikes

Our goal is **fewer, well-sized parts**.

---

# 3️⃣ Migration Playbook — Fixing Bad Schemas Safely

Never mutate broken schemas in-place.

### 🟢 Correct Approach: Shadow Table Migration

1. Create a **new table** with:

   * Correct partitioning
   * Correct codecs
   * Correct ordering keys
2. Backfill with **controlled batch copy**
3. Dual-write if required
4. Validate row counts + query correctness
5. Switch consumers
6. Decommission old table

---

### ✨ Example: Old → New Table

```sql
CREATE TABLE new_table (...) 
ENGINE = MergeTree
PARTITION BY toYYYYMM(date)
ORDER BY (postcode1, postcode2, addr1, addr2);
```

Migration copy pattern

```sql
INSERT INTO new_table
SELECT * FROM old_table
WHERE date >= '...'
```

Batch in **time slices** to avoid merge pressure.

---

# 4️⃣ Ingestion Hardening for Bursty Workloads

### ✅ Enable controlled async inserts

```sql
SET async_insert = 1
SET wait_for_async_insert = 0
```

App guidance:

* Batch **100K–500K rows**
* Use **2–4 parallel workers**
* Add **retry with exponential backoff**

---

### 🧯 Backpressure Protection (Required)

```xml
parts_to_delay_insert = 200
parts_to_throw_insert = 400
min_rows_for_wide_part = 100000
min_bytes_for_wide_part = 10MB
background_pool_size = 16–20
```

Platform rule:

> Inserts must slow down before the cluster melts down.

---

# 5️⃣ Codec Strategy — Compression With Intent

We optimize for:

* Less IO
* Lower cost
* Faster scans on read workloads

Codec cheat sheet (operationally safe defaults) is preserved from prior version.

---

# 6️⃣ Observability & SLO Signals (Platform Requirement)

A ClickHouse cluster is **healthy** when:

* Parts pending merge = stable
* Parts per partition remain below threshold
* Background pool queue does not grow
* Insert latency does not trend upward
* Query latency does not degrade under load

### 🚨 Alert Before Failure

* Merge queue > threshold
* Parts per partition trending upward
* Async insert backlog aging
* Disk growth exponential
* Queries begin scanning > expected partitions

---

# 7️⃣ Pre-Onboarding Checklist for New Services

Teams must provide:

* Expected ingest rate (avg + peak)
* Query date ranges
* Retention policy
* Backfill expectations
* Read-after-write requirements
* Burst tolerance characteristics
* Failure-mode expectations

Unsafe defaults are **blocked at design review**.

---

## 🎯 Final Principle

This platform is designed around reliability discipline:

* Fewer knobs doing predictable work
* Stable merges instead of chaotic merges
* Explicit ingestion trade-offs
* No tables that surprise operators later

ClickHouse performs extremely well **when the storage layout matches workload reality** — and fails loudly when it doesn’t.

Design intentionally.
