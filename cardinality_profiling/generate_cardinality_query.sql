-- Generates a query for all columns of a table
SELECT concat('SELECT ', groupConcat(concat('uniq(', name, ') AS uniq_', name), ', '), ', count() AS total_rows FROM observations.deduped_observations_lc') AS query_text
FROM system.columns
WHERE (database = 'database') AND (`table` = 'table');
