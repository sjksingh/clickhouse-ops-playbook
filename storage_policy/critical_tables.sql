-- ============================================
-- PART SIZE MONITORING FOR CRITICAL TABLES
-- Tables: observations_in, deduped_observations_2
-- Purpose: Monitor part sizes to prevent merge pressure
-- ============================================

-- 1. CURRENT PART SIZE OVERVIEW
SELECT 
    '=== CURRENT PART SIZES ===' as section,
    table,
    disk_name,
    count() as parts_count,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    formatReadableSize(avg(bytes_on_disk)) as avg_part_size,
    formatReadableSize(min(bytes_on_disk)) as min_part_size,
    formatReadableSize(max(bytes_on_disk)) as max_part_size,
    formatReadableSize(quantile(0.5)(bytes_on_disk)) as median_part_size,
    formatReadableSize(quantile(0.95)(bytes_on_disk)) as p95_part_size,
    CASE 
        WHEN max(bytes_on_disk) > 50000000000 THEN '🔴 VERY LARGE PARTS (>50GB)'
        WHEN max(bytes_on_disk) > 30000000000 THEN '🟠 LARGE PARTS (>30GB)'
        WHEN max(bytes_on_disk) > 10000000000 THEN '🟡 MODERATE PARTS (>10GB)'
        ELSE '🟢 SMALL PARTS (<10GB)'
    END as size_status
FROM system.parts
WHERE active = 1
  AND database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
GROUP BY table, disk_name
ORDER BY table, max(bytes_on_disk) DESC;

-- 2. PART SIZE DISTRIBUTION (BUCKETED)
SELECT 
    '=== PART SIZE DISTRIBUTION ===' as section,
    table,
    CASE 
        WHEN bytes_on_disk < 1000000000 THEN '1. <1GB'
        WHEN bytes_on_disk < 5000000000 THEN '2. 1-5GB'
        WHEN bytes_on_disk < 10000000000 THEN '3. 5-10GB (HOT LIMIT)'
        WHEN bytes_on_disk < 20000000000 THEN '4. 10-20GB'
        WHEN bytes_on_disk < 30000000000 THEN '5. 20-30GB'
        WHEN bytes_on_disk < 50000000000 THEN '6. 30-50GB'
        ELSE '7. >50GB ⚠️'
    END as size_bucket,
    count() as parts_count,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    round(count() * 100.0 / sum(count()) OVER (PARTITION BY table), 2) as pct_of_parts
FROM system.parts
WHERE active = 1
  AND database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
GROUP BY table, size_bucket
ORDER BY table, size_bucket;

-- 3. TOP 20 LARGEST PARTS (ACTIONABLE - CANDIDATES FOR OPTIMIZATION)
SELECT 
    '=== TOP 20 LARGEST PARTS ===' as section,
    table,
    name as part_name,
    partition,
    disk_name,
    formatReadableSize(bytes_on_disk) as size,
    bytes_on_disk,
    rows,
    formatReadableSize(bytes_on_disk / rows) as bytes_per_row,
    modification_time,
    dateDiff('hour', modification_time, now()) as age_hours,
    CASE 
        WHEN bytes_on_disk > 50000000000 THEN '🔴 CRITICAL - Consider splitting'
        WHEN bytes_on_disk > 30000000000 THEN '🟠 HIGH - Monitor closely'
        WHEN bytes_on_disk > 10000000000 THEN '🟡 ELEVATED - Normal for warm tier'
        ELSE '🟢 OK'
    END as action_needed
FROM system.parts
WHERE active = 1
  AND database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
ORDER BY bytes_on_disk DESC
LIMIT 20;

-- 4. RECENT PART GROWTH TREND (LAST 7 DAYS)
SELECT 
    '=== PART GROWTH TREND (7 DAYS) ===' as section,
    table,
    toDate(modification_time) as date,
    count() as parts_created,
    formatReadableSize(sum(bytes_on_disk)) as total_size_created,
    formatReadableSize(avg(bytes_on_disk)) as avg_part_size,
    formatReadableSize(max(bytes_on_disk)) as max_part_size,
    CASE 
        WHEN max(bytes_on_disk) > 50000000000 THEN '🔴 ALERT'
        WHEN max(bytes_on_disk) > 30000000000 THEN '🟠 WARNING'
        ELSE '🟢 OK'
    END as daily_status
FROM system.parts
WHERE active = 1
  AND database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
  AND modification_time >= now() - INTERVAL 7 DAY
GROUP BY table, date
ORDER BY table, date DESC;

-- 5. PARTS EXCEEDING 10GB (HOT TIER LIMIT)
SELECT 
    '=== PARTS EXCEEDING 10GB THRESHOLD ===' as section,
    table,
    count() as parts_over_10gb,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    formatReadableSize(avg(bytes_on_disk)) as avg_size,
    formatReadableSize(max(bytes_on_disk)) as largest_part,
    round(count() * 100.0 / (SELECT count() FROM system.parts WHERE active = 1 AND database = 'observations' AND table = p.table), 2) as pct_of_total_parts
FROM system.parts p
WHERE active = 1
  AND database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
  AND bytes_on_disk > 10000000000
GROUP BY table;

-- 6. MERGE PRESSURE INDICATORS
SELECT 
    '=== MERGE PRESSURE INDICATORS ===' as section,
    table,
    count() as total_parts,
    countIf(level = 0) as level_0_parts,
    countIf(level >= 3) as deeply_merged_parts,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    formatReadableSize(sumIf(bytes_on_disk, level = 0)) as unmerged_size,
    round(countIf(level = 0) * 100.0 / count(), 2) as pct_unmerged,
    CASE 
        WHEN countIf(level = 0) > 100 THEN '🔴 HIGH MERGE BACKLOG'
        WHEN countIf(level = 0) > 50 THEN '🟠 MODERATE MERGE ACTIVITY'
        ELSE '🟢 HEALTHY MERGE RATE'
    END as merge_status
FROM system.parts
WHERE active = 1
  AND database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
GROUP BY table;

-- 7. DISK PLACEMENT ANALYSIS
SELECT 
    '=== DISK PLACEMENT BREAKDOWN ===' as section,
    table,
    disk_name,
    count() as parts,
    formatReadableSize(sum(bytes_on_disk)) as size,
    round(sum(bytes_on_disk) * 100.0 / sum(sum(bytes_on_disk)) OVER (PARTITION BY table), 2) as pct_of_table,
    countIf(bytes_on_disk > 10000000000) as parts_over_10gb,
    formatReadableSize(avg(bytes_on_disk)) as avg_part_size
FROM system.parts
WHERE active = 1
  AND database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
GROUP BY table, disk_name
ORDER BY table, sum(bytes_on_disk) DESC;

-- 8. COMPRESSION RATIO (EFFICIENCY CHECK)
SELECT 
    '=== COMPRESSION EFFICIENCY ===' as section,
    table,
    formatReadableSize(sum(data_compressed_bytes)) as compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) as uncompressed_size,
    round(sum(data_compressed_bytes) * 100.0 / sum(data_uncompressed_bytes), 2) as compression_pct,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) as compression_ratio,
    CASE 
        WHEN sum(data_compressed_bytes) * 100.0 / sum(data_uncompressed_bytes) > 50 THEN '🟠 LOW COMPRESSION'
        WHEN sum(data_compressed_bytes) * 100.0 / sum(data_uncompressed_bytes) > 30 THEN '🟡 MODERATE COMPRESSION'
        ELSE '🟢 GOOD COMPRESSION'
    END as compression_status
FROM system.parts
WHERE active = 1
  AND database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
GROUP BY table;

-- 9. ACTIVE MERGES (REAL-TIME)
SELECT 
    '=== ACTIVE MERGES (NOW) ===' as section,
    table,
    count() as active_merges,
    formatReadableSize(sum(total_size_bytes_compressed)) as total_merge_size,
    formatReadableSize(sum(bytes_read_uncompressed)) as bytes_read,
    formatReadableSize(sum(bytes_written_uncompressed)) as bytes_written,
    round(avg(progress), 2) as avg_progress_pct,
    sum(num_parts) as parts_being_merged
FROM system.merges
WHERE database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
GROUP BY table;

-- 10. ACTIONABLE ALERTS (SUMMARY)
SELECT 
    '=== ACTIONABLE ALERTS ===' as section,
    table,
    CASE 
        WHEN max(bytes_on_disk) > 50000000000 THEN '🔴 CRITICAL: Parts >50GB detected - Risk of merge pressure'
        WHEN max(bytes_on_disk) > 30000000000 THEN '🟠 WARNING: Parts >30GB detected - Monitor CPU/MEM during merges'
        WHEN count() > 500 THEN '🟡 INFO: High part count (>500) - Normal but monitor merge backlog'
        ELSE '🟢 HEALTHY: Part sizes within acceptable range'
    END as alert_level,
    count() as total_parts,
    formatReadableSize(max(bytes_on_disk)) as largest_part,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    CASE 
        WHEN max(bytes_on_disk) > 50000000000 THEN 'ACTION: Review partitioning strategy, consider more granular partitions'
        WHEN max(bytes_on_disk) > 30000000000 THEN 'ACTION: Monitor system resources during merge operations'
        WHEN count() > 500 THEN 'ACTION: Verify merge settings, check for merge backlog'
        ELSE 'ACTION: Continue monitoring'
    END as recommended_action
FROM system.parts
WHERE active = 1
  AND database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
GROUP BY table;

-- 11. HISTORICAL COMPARISON (IF NEEDED - RUN PERIODICALLY AND COMPARE)
SELECT 
    '=== SNAPSHOT FOR COMPARISON ===' as section,
    now() as snapshot_time,
    table,
    count() as parts_count,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    formatReadableSize(avg(bytes_on_disk)) as avg_part_size,
    formatReadableSize(max(bytes_on_disk)) as max_part_size,
    countIf(bytes_on_disk > 10000000000) as parts_over_10gb,
    countIf(bytes_on_disk > 30000000000) as parts_over_30gb,
    countIf(bytes_on_disk > 50000000000) as parts_over_50gb
FROM system.parts
WHERE active = 1
  AND database = 'observations'
  AND table IN ('observations_in', 'deduped_observations_2')
GROUP BY table;
