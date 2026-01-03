# 🛠 ClickHouse Schema Evolution: Dos and DON'Ts

## 📖 Overview
ClickHouse is an OLAP database. Unlike PostgreSQL, which is row-oriented and uses a B-Tree heap, ClickHouse is column-oriented and uses **MergeTree** storage. Modifications in ClickHouse are "Mutations" that rewrite data parts in the background.

---

## 🟢 The "Green Zone" (Safe & Online)
*These operations are metadata-only or background mutations. They do not block reads.*

| Operation | Command Reference | Operational Impact |
| :--- | :--- | :--- |
| **Add Column** | `ALTER TABLE db.tbl ADD COLUMN new_col String DEFAULT 'val'` | Metadata only. Instant. |
| **Drop Column** | `ALTER TABLE db.tbl DROP COLUMN old_col` | Metadata only. Disk reclaimed in background. |
| **LowCardinality** | `ALTER TABLE db.tbl MODIFY COLUMN col LowCardinality(String)` | Background mutation. Rewrites only the specific column files. |
| **Enum Expansion** | `ALTER TABLE db.tbl MODIFY COLUMN status Enum8('A'=1, 'B'=2, 'C'=3)` | Instant if only adding values to the end of the list. |
| **Rename Column** | `ALTER TABLE db.tbl RENAME COLUMN old TO new` | Instant metadata change. |



---

## 🟡 The "Yellow Zone" (Proceed with Caution)
*Technically online, but resource-intensive.*

* **Large Table MODIFY (>500GB):** Triggers massive Background I/O. Monitor `system.mutations`.
* **Changing Data Types:** `ALTER TABLE db.tbl MODIFY COLUMN price Float64`. Will fail if data isn't perfectly castable.
* **Default Value Changes:** `ALTER TABLE db.tbl MODIFY COLUMN col DEFAULT new_val`. Only applies to *new* rows. Old rows remain unchanged unless "materialized."

---

## 🔴 The "Red Zone" (The "DON'Ts")
*These require a full table recreation (Create-Swap-Drop).*

1. **Changing the `ORDER BY` (Sort Key):** This is the "DNA" of the table. Data is physically sorted on disk by this key. You cannot modify it via ALTER.
2. **Changing the `PARTITION BY`:** This determines the folder structure of the data parts. Changes require a full rewrite.
3. **Changing the `PRIMARY KEY`:** Usually must match the prefix of the Sort Key. 

---

## 🔄 Optimal Backfill Strategy
When you must change the "DNA" (Sort Key or Partition) of a multi-terabyte table, do not use `INSERT INTO ... SELECT` in one go. Use the **Atomic Swap** method to ensure zero downtime and resumeability.

### 1. Create the Shadow Table
Create a new table with the identical schema but your new optimized settings.
```sql
CREATE TABLE db.table_new 
AS db.table_old
ENGINE = MergeTree
ORDER BY (new_sort_key)
PARTITION BY (new_partition_scheme);
    STATUS="✅ OK"
    [[ $(echo "$CARD_PCT < 5.0" | bc -l) -eq 1 ]] && STATUS="🚀 OPTIMIZE"
    [[ $(echo "$CARD_PCT > 60.0" | bc -l) -eq 1 ]] && STATUS="🛑 SKIP"

    echo "📊 Column: $COL | Status: $STATUS ($CARD_PCT%)"
done
```

2. Partition-by-Partition Backfill
Loop through partitions to manage memory and disk pressure. If it fails, you only lose the progress of the current partition.

```bash
# Example logic for a backfill loop
for part in $(ch_query "SELECT DISTINCT partition_id FROM system.parts WHERE table='table_old' AND active"); do
    ch_query "INSERT INTO db.table_new SELECT * FROM db.table_old WHERE partition_id = '$part'"
    echo "✅ Partition $part migrated"
done
```

3. Atomic Exchange
Swap the tables instantly. This is a metadata-only operation.
```sql
EXCHANGE TABLES db.table_old AND db.table_new;
```

### 🚀 Operational Checklist for Mutations
- Check Mutation Queue: Never start an ALTER if the queue is backed up.
```sql
SELECT table, command, is_done FROM system.mutations WHERE is_done = 0;
```
- Verify Disk Space: Mutations require temp space. Ensure at least 20% free disk before modifying large columns.
- Monitor Merges: If system.merges is saturated, your ALTER will be slow.
- The Sampling Rule: Never run cardinality checks on TiB-scale tables without sampling.
- Safe Check: SELECT count() FROM table SAMPLE 0.01


### 📊 Cardinality Optimization Guide
Use the following logic to decide when to use LowCardinality(String):

- Cardinality < 5%: 🚀 Strong Yes. Significant storage and query speed gains.
- Cardinality 5% - 50%: ⚖️ Maybe. Usually better to use standard String with CODEC(LZ4).
- Cardinality > 50%: 🛑 No. Dictionary overhead will make the table larger and slower.
