SELECT
    column AS column_name,
    any(type) AS data_type,
    sum(column_data_compressed_bytes) AS compressed_bytes,
    sum(column_data_uncompressed_bytes) AS uncompressed_bytes,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 2) AS compression_ratio,
    formatReadableSize(sum(column_data_compressed_bytes)) AS compressed_size,
    multiIf(
        compression_ratio < 3, '⚠️ Poor compression',
        compression_ratio < 5, '✅ Good compression',
        compression_ratio < 10, '✅ Great compression',
        '✅ Excellent compression'
    ) AS recommendation
FROM system.parts_columns
WHERE database = 'observations'
  AND table = 'deduped_observations_lc'
  AND active
  AND type NOT LIKE '%LowCardinality%'
GROUP BY column
ORDER BY compressed_bytes DESC;
