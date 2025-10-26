-- ============================================================================
-- 🟡 MERGE BACKLOG - Too many parts = performance killer
-- ============================================================================
-- Use: Page for slow queries / "too many parts" errors
-- Action: Trigger manual merges, adjust merge settings, check disk I/O
-- Docs: See troubleshooting/too-many-parts.md
-- ============================================================================

-- Tables with too many parts (>200 is concerning, >500 is critical)
SELECT
    database,
    table,
    count() AS active_parts,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    max(modification_time) AS newest_part,
    min(modification_time) AS oldest_part,
    count() FILTER (WHERE modification_time < now() - INTERVAL 1 HOUR) AS old_parts
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE active = 1
GROUP BY database, table
HAVING active_parts > 200
ORDER BY active_parts DESC
LIMIT 20;

-- ============================================================================
-- Parts breakdown by partition (find hot partitions)
-- ============================================================================
SELECT
    database,
    table,
    partition,
    count() AS parts_in_partition,
    formatReadableSize(sum(bytes_on_disk)) AS partition_size,
    max(modification_time) AS newest_part
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE active = 1
GROUP BY database, table, partition
HAVING parts_in_partition > 50
ORDER BY parts_in_partition DESC
LIMIT 30;

-- ============================================================================
-- Small parts that should have merged (merge candidates)
-- ============================================================================
SELECT
    database,
    table,
    partition,
    count() AS small_parts,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    round(avg(rows)) AS avg_rows_per_part
FROM clusterAllReplicas('{cluster}', system, parts)
WHERE active = 1
  AND rows < 10000
  AND modification_time < now() - INTERVAL 30 MINUTES
GROUP BY database, table, partition
HAVING small_parts > 10
ORDER BY small_parts DESC
LIMIT 20;
