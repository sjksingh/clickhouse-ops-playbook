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
