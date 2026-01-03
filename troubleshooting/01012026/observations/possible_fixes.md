


-- Takes 5 minutes to set up, fixes problem permanently
CREATE TABLE observations.measurement_id_reverse_lookup_3_buffer AS 
  observations.measurement_id_reverse_lookup_3
ENGINE = Buffer(
  observations, measurement_id_reverse_lookup_3,
  16,          -- num_layers (parallelism)
  10,          -- min_time: flush after 10 seconds
  100,         -- max_time: force flush after 100 seconds
  10000,       -- min_rows: flush after 10K rows
  10000000,    -- max_rows: force flush after 10M rows
  10000000,    -- min_bytes: flush after 10 MB
  1000000000   -- max_bytes: force flush after 1 GB
);

-- Then update application config to write to _buffer tables
-- ClickHouse will batch them automatically
