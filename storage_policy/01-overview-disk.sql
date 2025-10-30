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
