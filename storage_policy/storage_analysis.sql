-- ============================================
-- CLICKHOUSE STORAGE POLICY ANALYSIS
-- Complete diagnostic script
-- ============================================

-- 1. STORAGE OVERVIEW BY DISK
SELECT 
    '1. STORAGE BY DISK' as section,
    disk_name,
    formatReadableSize(sum(bytes_on_disk)) as size,
    count() as parts_count,
    countDistinct(table) as tables_count
FROM system.parts
WHERE active = 1
GROUP BY disk_name
ORDER BY sum(bytes_on_disk) DESC;

-- 2. DISK CAPACITY & USAGE
SELECT 
    '2. DISK CAPACITY' as section,
    name as disk_name,
    path,
    formatReadableSize(total_space) as total,
    formatReadableSize(free_space) as free,
    formatReadableSize(total_space - free_space) as used,
    round((total_space - free_space) / total_space * 100, 2) as used_pct,
    CASE 
        WHEN (total_space - free_space) / total_space >= 0.9 THEN '⚠️ WILL TRIGGER MOVE'
        WHEN (total_space - free_space) / total_space >= 0.7 THEN '⚠️ GETTING FULL'
        ELSE '✓ OK'
    END as status
FROM system.disks
ORDER BY (total_space - free_space) DESC;

-- 3. TABLES BY STORAGE POLICY
SELECT 
    '3. STORAGE POLICIES' as section,
    storage_policy,
    count() as tables_count,
    formatReadableSize(sum(total_bytes)) as total_size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY storage_policy
ORDER BY sum(total_bytes) DESC;

-- 4. DATA DISTRIBUTION BY TABLE AND DISK
SELECT 
    '4. TABLE DISTRIBUTION' as section,
    table,
    disk_name,
    formatReadableSize(sum(bytes_on_disk)) as size,
    count() as parts_count,
    min(modification_time) as oldest_part,
    max(modification_time) as newest_part
FROM system.parts
WHERE active = 1
GROUP BY table, disk_name
HAVING sum(bytes_on_disk) > 100000000  -- Only show tables > 100MB
ORDER BY sum(bytes_on_disk) DESC
LIMIT 50;

-- 5. LARGEST TABLES (TOTAL)
SELECT 
    '5. LARGEST TABLES' as section,
    table,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    count() as total_parts,
    countDistinct(disk_name) as disks_used,
    groupUniqArray(disk_name) as disk_list
FROM system.parts
WHERE active = 1
GROUP BY table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 20;

-- 6. PARTS ON WARM THAT COULD FIT ON HOT
SELECT 
    '6. WARM PARTS < 10GB' as section,
    table,
    count() as parts_count,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    formatReadableSize(max(bytes_on_disk)) as largest_part
FROM system.parts
WHERE active = 1
  AND disk_name LIKE '%jbod%'
  AND bytes_on_disk < 10000000000
GROUP BY table
ORDER BY sum(bytes_on_disk) DESC;

-- 7. PARTS TOO LARGE FOR HOT
SELECT 
    '7. PARTS > 10GB (SKIP HOT)' as section,
    table,
    count() as parts_count,
    formatReadableSize(sum(bytes_on_disk)) as total_size,
    formatReadableSize(avg(bytes_on_disk)) as avg_part_size,
    formatReadableSize(max(bytes_on_disk)) as largest_part
FROM system.parts
WHERE active = 1
  AND bytes_on_disk > 10000000000
GROUP BY table
ORDER BY sum(bytes_on_disk) DESC;

-- 8. STORAGE POLICY CONFIGURATION
SELECT 
    '8. POLICY CONFIG' as section,
    policy_name,
    volume_name,
    volume_priority,
    disks,
    formatReadableSize(max_data_part_size) as max_part_size,
    move_factor
FROM system.storage_policies
ORDER BY policy_name, volume_priority;

-- 9. SUMMARY STATISTICS
SELECT 
    '9. SUMMARY' as section,
    formatReadableSize(sum(bytes_on_disk)) as total_data,
    count() as total_parts,
    countDistinct(table) as total_tables,
    countDistinct(disk_name) as disks_used,
    formatReadableSize(avg(bytes_on_disk)) as avg_part_size
FROM system.parts
WHERE active = 1;

-- 10. MOVEMENT PREDICTION
SELECT 
    '10. MOVEMENT FORECAST' as section,
    name as disk_name,
    formatReadableSize(total_space) as capacity,
    formatReadableSize(total_space - free_space) as used,
    round((total_space - free_space) / total_space * 100, 1) as used_pct,
    formatReadableSize(total_space * 0.9 - (total_space - free_space)) as space_until_90pct,
    CASE 
        WHEN (total_space - free_space) / total_space >= 0.9 THEN '🔴 MOVING DATA NOW'
        WHEN (total_space - free_space) / total_space >= 0.8 THEN '🟡 WILL MOVE SOON'
        WHEN (total_space - free_space) / total_space >= 0.7 THEN '🟢 MOVE IN FUTURE'
        ELSE '⚪ NO MOVE NEEDED'
    END as move_status
FROM system.disks
WHERE name IN ('hot', 'chi_cluster01_clickhouse_jbod_01', 'ch_observations_clickhouse_jbod_01', 's3_cached')
ORDER BY (total_space - free_space) / total_space DESC;
