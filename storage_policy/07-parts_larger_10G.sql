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
