-- ============================================================================
-- 🟡 ACTIVE MERGES - What's merging NOW
-- ============================================================================
-- Use: Check during high I/O / understand merge activity
-- Action: Monitor long-running merges, check if merges are stuck
-- ============================================================================

-- Currently running merges
SELECT
    hostName() AS host,
    database,
    table,
    elapsed,
    progress,
    num_parts,
    result_part_name,
    formatReadableSize(total_size_bytes_compressed) AS merge_size,
    formatReadableSize(memory_usage) AS memory,
    formatReadableSize(bytes_read_uncompressed) AS bytes_read,
    formatReadableSize(bytes_written_uncompressed) AS bytes_written,
    rows_read,
    rows_written
FROM clusterAllReplicas('{cluster}', system, merges)
ORDER BY elapsed DESC;

-- ============================================================================
-- Long-running merges (>5 minutes, might be stuck)
-- ============================================================================
SELECT
    hostName() AS host,
    database,
    table,
    elapsed,
    progress,
    num_parts,
    formatReadableSize(total_size_bytes_compressed) AS merge_size,
    result_part_name
FROM clusterAllReplicas('{cluster}', system, merges)
WHERE elapsed > 300
ORDER BY elapsed DESC;
