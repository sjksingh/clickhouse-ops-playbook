# 📊 ClickHouse Ingestion & Partitioning Guide — Lessons from Real Production Workloads

This document explains how partitioning, part sizing, batching, compression, and merge settings impact performance in ClickHouse — especially under **continuous ingestion and heavy-read analytics workloads**.

It’s written from a **production DBRE perspective**: the goal is not perfection, but **predictability, guardrails, and minimizing blast radius when ingestion or merges fall behind**.

---

## ✅ What This Guide Helps You Avoid

* Small part explosion
* Endless merge backlogs
* Hot partitions
* Slow queries from too many files
* Write amplification & CPU waste
* Insert throttling & ingestion stalls

---

# 1️⃣ Partitioning Strategy — Where Things Commonly Go Wrong

### ❌ What went wrong

```sql
PARTITION BY toYear(date)
```

This creates **one partition per YEAR**.

**Problems:**

* All rows for a year land in a single partition
* Large partitions = **slow merges + huge parts**
* Inserts compete inside the same merge queue
* Retention deletes can’t be granular
* Operational blast radius increases

ClickHouse merges happen **per partition**, so oversized yearly partitions lead to **long merge cycles and stuck small parts**.

---

### 🧠 Questions you should ask before choosing a partition key

| Question                         | Why It Matters                           |
| -------------------------------- | ---------------------------------------- |
| How far back do we query?        | Drives hot vs cold storage decisions     |
| Do queries span multiple years?  | Cross-partition scans impact latency     |
| What is the retention policy?    | Partition boundaries control DROP cost   |
| What is the typical query range? | Daily? Weekly? Monthly?                  |
| Will we delete/archive old data? | `DROP PARTITION` is instant — if aligned |

---

# 2️⃣ Part Size Sweet Spot — The Science Behind It

### 🎯 Recommended Part Size (ClickHouse best-practice range)

| Metric    | Minimum | Optimal       | Maximum |
| --------- | ------- | ------------- | ------- |
| **Rows**  | 100K    | 1–10M         | 100M    |
| **Bytes** | 10 MB   | 100 MB – 1 GB | 10 GB   |

### Why this matters

#### Too small (< 100K rows)

* Many files → slower queries
* Merge CPU waste
* Extra ZooKeeper chatter (replicated tables)

#### Too large (> 100M rows)

* Merges take hours
* Memory spikes
* Harder to parallelize reads

---

### 📉 Your ingestion profile example

* 500K rows every 5 minutes
* If each insert becomes a part:

```
12 parts per hour
288 parts per day
500K rows per part
```

Borderline acceptable — but grows unstable under bursts or replication.

---

### 🧠 Questions to ask Engineering

| Question                               | Why                               |
| -------------------------------------- | --------------------------------- |
| What is sustained insert rate?         | Determines merge headroom         |
| Is ingestion bursty?                   | Bursts = small part avalanche     |
| How many tables ingest simultaneously? | Merge pool contention             |
| What is peak load?                     | Tune for worst-case, not averages |

---

# 3️⃣ Choosing the Right Partition Granularity — Decision Framework

```
Partition Strategy Decision Tree
```

**< 100M rows/day**

* Queries = last 30 days → `toYYYYMM()` ✅ BEST
* Queries = last 7 days → weekly partitions ✅ OK
* Real-time analytics → daily partitions ⚠️ use carefully

**> 100M rows/day (high-volume)**

* Queries = last 24h → daily partitions ✅
* Short-range scans → hourly partitions ⚠️ advanced
* Extreme streaming → `tuple()` (no partition) 🔴 expert-only

---

### 📌 Example Case

```
500K rows / 5 min  → 144M rows/year
Future: 5M / 5 min → 1.44B rows/year
```

| Strategy | Partitions/Year | Rows/Partition (current) | Rows/Partition (future) | Verdict            |
| -------- | --------------: | -----------------------: | ----------------------: | ------------------ |
| YEAR     |               1 |                     144M |                   1.44B | 🔴 Too coarse      |
| MONTH    |              12 |                      12M |                    120M | ✅ Balanced         |
| WEEK     |              52 |                     2.7M |                     27M | ⚠️ Higher overhead |
| DAY      |             365 |                     400K |                      4M | 🔴 Too many parts  |

👉 **Recommendation: `PARTITION BY toYYYYMM(date)` (Monthly)**

---

### 🧠 Questions for PM / Platform

| Question                       | Why                       |
| ------------------------------ | ------------------------- |
| Typical query window?          | Guides partition horizon  |
| Do we archive / drop old data? | Monthly drops = instant   |
| Expected growth x10 / x100?    | Future-proofing           |
| Retention / compliance rules?  | Impacts partition roll-up |

---

# 4️⃣ Go Client Batching — Sync vs Async Inserts

### ❌ Typical synchronous batching

```go
batch, _ := conn.PrepareBatch(ctx, "INSERT INTO uk_price_paid")
for _, row := range rows {
    batch.Append(...)
}
batch.Send() // Blocks
```

Simple — but blocks the app and prevents pipelining.

---

### ✅ Recommended: Async Inserts

```go
batch, _ := conn.PrepareBatch(
    ctx,
    "INSERT INTO uk_price_paid SETTINGS async_insert=1, wait_for_async_insert=0",
)
```

**Benefits**

* ClickHouse buffers & merges inserts
* Larger parts → fewer merges
* App threads do not stall

**Trade-off**

* Data becomes visible with ~1–2s delay

**Good defaults for high-volume ingestion**

* Batch size: **100K–500K rows**
* Parallel workers: **2–4 goroutines**

---

### 🧠 Questions to ask Engineering

| Question                         | Why                     |
| -------------------------------- | ----------------------- |
| Can we tolerate 1–2s ingest lag? | Async viability         |
| Is read-after-write required?    | If yes → sync or hybrid |
| Concurrency model?               | Worker tuning           |
| Retry strategy?                  | Avoid silent data loss  |

---

# 5️⃣ Compression Codecs — Where Performance Is Won or Lost

### 🎯 Optimized Table Example

```sql
CREATE TABLE uk_price_paid_optimized (
    price UInt32 CODEC(DoubleDelta, ZSTD(3)),
    date Date CODEC(DoubleDelta, LZ4),

    postcode1 LowCardinality(String),
    postcode2 LowCardinality(String),

    type Enum8(...),
    is_new UInt8 CODEC(T64, ZSTD),

    duration Enum8(...),

    addr1 String CODEC(ZSTD(3)),
    addr2 String CODEC(ZSTD(3)),
    street LowCardinality(String),
    locality LowCardinality(String),
    town LowCardinality(String),
    district LowCardinality(String),
    county LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(date)
ORDER BY (postcode1, postcode2, addr1, addr2)
SETTINGS index_granularity = 8192;
```

---

### 🧩 Codec Selection Cheat-Sheet

| Pattern                 | Best Codec         | Example    |
| ----------------------- | ------------------ | ---------- |
| Sequential numbers      | DoubleDelta + LZ4  | timestamps |
| Slowly changing numeric | DoubleDelta + ZSTD | price      |
| Random numeric          | LZ4 / ZSTD(1)      | ids        |
| Boolean flags           | T64 + ZSTD         | is_active  |
| Low-card strings        | LowCardinality     | city       |
| Very low-card           | Enum8 / Enum16     | type       |
| Long text               | ZSTD(3–5)          | address    |

**Impact:** Smaller data → fewer reads → faster queries.

---

# 6️⃣ Merge Settings — Preventing Small-Part Backlogs

### 🔧 Key knobs

```xml
<merge_tree>
  <parts_to_throw_insert>400</parts_to_throw_insert>
  <parts_to_delay_insert>200</parts_to_delay_insert>

  <min_rows_for_wide_part>100000</min_rows_for_wide_part>
  <min_bytes_for_wide_part>10485760</min_bytes_for_wide_part> <!-- 10 MB -->
</merge_tree>

<background_pool_size>20</background_pool_size>
```

### Suggested defaults for ingestion workloads

| Setting                       | Why                                |
| ----------------------------- | ---------------------------------- |
| `parts_to_delay_insert=200`   | Apply backpressure before meltdown |
| `parts_to_throw_insert=400`   | Hard stop to protect cluster       |
| `min_rows_for_wide_part=100K` | Avoid tiny parts                   |
| `background_pool_size=16–20`  | More merge capacity                |

---

### 🧠 Questions to ask Engineering

| Question                             | Why                           |
| ------------------------------------ | ----------------------------- |
| What happens when inserts fail?      | Backpressure tolerance        |
| Can ingestion pause for maintenance? | Merge scheduling              |
| Acceptable insert latency?           | Delay vs throughput trade-off |

---

# 🧾 Deployment Readiness Checklist (For Every New Table)

### 📌 Data Characteristics

* Sustained insert rate (rows/sec)?
* Peak ingestion?
* Growth horizon (6–36 months)?
* Column cardinality?
* Sequential or random distribution?

### 🔎 Query Patterns

* Typical query window?
* Most common filter columns?
* Group-by fields?
* Latency target?
* Point lookups vs aggregations?

### 🗂 Retention & Lifecycle

* Retention policy?
* Archive vs delete?
* Compliance rules?
* PITR requirements?

### 🚚 Ingestion Architecture

* Client language / driver?
* Async inserts allowed?
* Read-after-write required?
* Retry guarantees?
* Burst vs steady ingestion?

### 🛠 Operational Constraints

* Disk budget?
* CPU budget?
* Can ingestion pause?
* Monitoring & alerting coverage?

---

## 🎯 Final Takeaway

We don’t optimize for theoretical perfection.
We optimize for **operational stability, predictable merges, and bounded failure modes** — especially under heavy ingestion.

Design your **partitioning, batching, compression, and merge strategy intentionally** — not accidentally.

---

