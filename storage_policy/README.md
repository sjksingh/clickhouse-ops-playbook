# ClickHouse Storage Policy Analysis

A comprehensive SQL script for monitoring and analyzing ClickHouse storage policies, disk usage, and data distribution across tiered storage.

## Overview

This repository contains a diagnostic script (`storage_analysis.sql`) that provides complete visibility into ClickHouse storage operations, helping you understand where your data resides and when it will move between storage tiers.

## Storage Policy Configuration

Our ClickHouse cluster uses a **three-tier storage policy** (`standardv2`) with automatic data movement based on disk capacity:

### Storage Tiers

| Tier | Disk | Purpose | Max Part Size | Move Factor |
|------|------|---------|---------------|-------------|
| **HOT** | `hot` (NVMe) | Fast local disk for active data | ≤ 10GB | 0.1 (90%) |
| **WARM** | `chi_cluster01_clickhouse_jbod_01` (JBOD) | Intermediate storage for less active data | Unlimited | 0.1 (90%) |
| **COLD** | `s3_cached` (S3 + cache) | Archival storage on object storage | Unlimited | N/A |

### How Data Moves

Data movement is **disk-based**, not table-based or time-based:

1. **Initial Placement**
   - Parts **≤ 10GB** → Inserted to **HOT** tier
   - Parts **> 10GB** → Skip HOT, inserted directly to **WARM** tier

2. **Automatic Movement**
   - **HOT → WARM**: Triggered when HOT disk reaches **90% capacity**
   - **WARM → COLD**: Triggered when WARM disk reaches **90% capacity**
   - Oldest data parts move first (by modification time)

3. **Cold Tier Behavior**
   - `prefer_not_to_merge: true` - Avoids expensive merge operations on S3
   - `perform_ttl_move_on_insert: false` - Prevents immediate TTL-based moves

### Key Characteristics

- ✅ **Capacity-driven**: Movement happens only when disks fill up
- ✅ **Size-aware**: Large parts (>10GB) bypass HOT tier entirely
- ✅ **Background process**: Movement is handled by ClickHouse background merges
- ✅ **Oldest-first**: Data moves in order of part modification time

## Storage Analysis Script

### What It Analyzes

The `storage_analysis.sql` script provides 10 comprehensive reports:

1. **Storage by Disk** - Data distribution across all disks
2. **Disk Capacity** - Current usage and capacity status
3. **Storage Policies** - Tables grouped by storage policy
4. **Table Distribution** - Where each table's data resides
5. **Largest Tables** - Top 20 tables by size
6. **Warm Parts < 10GB** - Parts on WARM that could fit on HOT
7. **Parts > 10GB** - Parts that skip HOT tier
8. **Policy Configuration** - Storage policy details from system tables
9. **Summary Statistics** - Overall cluster statistics
10. **Movement Forecast** - Predicts when data will move between tiers

### Usage

```bash
# Run the complete analysis
clickhouse-client --multiquery < storage_analysis.sql

# Or connect and run interactively
clickhouse-client
```

```sql
-- Paste the contents of storage_analysis.sql
```

### Sample Output

```
1. STORAGE BY DISK
┌─disk_name──────────────────────────┬─size───────┬─parts_count─┬─tables_count─┐
│ ch_observations_clickhouse_jbod_01 │ 673.90 GiB │          17 │            2 │
│ hot                                │ 45.77 GiB  │         544 │           23 │
│ default                            │ 14.45 GiB  │         281 │           17 │
└────────────────────────────────────┴────────────┴─────────────┴──────────────┘

10. MOVEMENT FORECAST
┌─disk_name──────────────────────────┬─used_pct─┬─move_status────────┐
│ hot                                │     3.0% │ ⚪ NO MOVE NEEDED   │
│ ch_observations_clickhouse_jbod_01 │     7.0% │ ⚪ NO MOVE NEEDED   │
└────────────────────────────────────┴──────────┴────────────────────┘
```

## Common Scenarios

### Why is my data on WARM instead of HOT?

**Reason**: Your table has data parts larger than 10GB. These parts skip the HOT tier and are written directly to WARM.

**Check with**:
```sql
SELECT 
    table,
    name as part_name,
    disk_name,
    formatReadableSize(bytes_on_disk) as size,
    CASE 
        WHEN bytes_on_disk > 10000000000 THEN 'TOO LARGE FOR HOT (>10GB)'
        ELSE 'Fits on hot'
    END as reason
FROM system.parts
WHERE active = 1 AND table = 'your_table_name'
ORDER BY bytes_on_disk DESC;
```

### When will my data move to the next tier?

Data moves when the source disk reaches **90% capacity**. Monitor with:

```sql
SELECT 
    name,
    formatReadableSize(total_space) as total,
    formatReadableSize(free_space) as free,
    round((total_space - free_space) / total_space * 100, 2) as used_pct,
    CASE 
        WHEN (total_space - free_space) / total_space >= 0.9 THEN '🔴 MOVING NOW'
        WHEN (total_space - free_space) / total_space >= 0.8 THEN '🟡 MOVE SOON'
        ELSE '✓ OK'
    END as status
FROM system.disks;
```

### How do I force data to stay on HOT?

**Option 1**: Keep data parts small (< 10GB) by:
- Adjusting `max_bytes_to_merge_at_max_space_in_pool`
- Using smaller partitions
- More frequent merges of smaller parts

**Option 2**: Modify the storage policy to increase `max_data_part_size_bytes` on the HOT volume (requires configuration change and restart).

## Policy Configuration

```xml
<policies>
  <standardv2>
    <volumes>
      <hot>
        <disk>hot</disk>
        <max_data_part_size_bytes>10000000000</max_data_part_size_bytes>
        <move_factor>0.1</move_factor>
      </hot>
      <warm>
        <disk>chi_cluster01_clickhouse_jbod_01</disk>
        <move_factor>0.1</move_factor>
      </warm>
      <cold>
        <disk>s3_cached</disk>
        <prefer_not_to_merge>true</prefer_not_to_merge>
        <perform_ttl_move_on_insert>false</perform_ttl_move_on_insert>
      </cold>
    </volumes>
    <move_factor>0.1</move_factor>
  </standardv2>
</policies>
```


## References

- [ClickHouse Storage Policies Documentation](https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree#table_engine-mergetree-multiple-volumes)
- [ClickHouse System Tables](https://clickhouse.com/docs/en/operations/system-tables/)
- [Tiered Storage Best Practices](https://clickhouse.com/docs/en/operations/storing-data)
