-- Generates a query for all columns of a table
SELECT 
    'SELECT ' || groupConcat('uniq(' || name || ') AS uniq_' || name, ', ') || ', count() AS total_rows FROM ' || database || '.' || table AS query_text
FROM system.columns
WHERE database = 'your_database' AND table = 'your_table';
