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
