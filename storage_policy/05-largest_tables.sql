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
