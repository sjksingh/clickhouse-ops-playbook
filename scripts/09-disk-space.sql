-- ============================================================================
-- 🟢 DISK SPACE - Running out?
-- ============================================================================
-- Use: Page for disk space alerts / plan capacity
-- Action: Clean old data, add storage, optimize compression
-- Docs: See troubleshooting/compression.md
-- ============================================================================

-- Disk usage per host (>70% triggers this query)
SELECT
    hostName() AS host,
    name AS disk,
    path,
    formatReadableSize(free_space) AS free,
    formatReadableSize(total_space) AS total,
    formatReadableSize(total_space - free_space) AS used,
    round((total_space - free_space) / total_space * 100, 1) AS used_pct
FROM clusterAllReplicas('{cluster}', system, disks)
ORDER BY used_pct DESC;

-- ============================================================================
-- Largest tables by disk space
-- ============================================================================
SELECT
    database,
    table,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 2) AS compression_ratio,
    sum(rows) AS total_rows,
    count() AS parts
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE active = 1
GROUP BY database, table
ORDER BY sum(bytes_on_disk) DESC
LIMIT 20;

-- ============================================================================
-- Disk space by database
-- ============================================================================
SELECT
    database,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    count(DISTINCT table) AS tables,
    sum(rows) AS total_rows
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE active = 1
GROUP BY database
ORDER BY sum(bytes_on_disk) DESC;

-- ============================================================================
-- Old partitions that could be dropped (>90 days)
-- ============================================================================
SELECT
    database,
    table,
    partition,
    formatReadableSize(sum(bytes_on_disk)) AS partition_size,
    max(modification_time) AS newest_part,
    min(modification_time) AS oldest_part,
    count() AS parts
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE active = 1
  AND modification_time < now() - INTERVAL 90 DAY
GROUP BY database, table, partition
ORDER BY sum(bytes_on_disk) DESC
LIMIT 20;
