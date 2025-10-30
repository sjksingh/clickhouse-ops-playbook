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
