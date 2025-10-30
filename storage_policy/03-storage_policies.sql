SELECT 
    '3. STORAGE POLICIES' as section,
    storage_policy,
    count() as tables_count,
    formatReadableSize(sum(total_bytes)) as total_size
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY storage_policy
ORDER BY sum(total_bytes) DESC;
