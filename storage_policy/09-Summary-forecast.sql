SELECT 
    '9. SUMMARY' as section,
    formatReadableSize(sum(bytes_on_disk)) as total_data,
    count() as total_parts,
    countDistinct(table) as total_tables,
    countDistinct(disk_name) as disks_used,
    formatReadableSize(avg(bytes_on_disk)) as avg_part_size
FROM system.parts
WHERE active = 1;

-- MOVEMENT PREDICTION
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
