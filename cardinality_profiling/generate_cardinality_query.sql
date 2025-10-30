-- Generates a query for all columns of a table
WITH table_cols AS (
    SELECT name
    FROM system.columns
    WHERE database = 'observations'
      AND table = 'deduped_observations_lc'
      AND (type LIKE '%String%' OR type LIKE '%Nullable(String)%')
)
SELECT arrayStringConcat(
    arrayMap(
        col -> concat(
            'SELECT ''', col, ''' AS name, ',
            'uniq(', col, ') AS uniq_value, ',
            'count() AS total_rows, ',
            'round((uniq(', col, ') / count()) * 100, 4) AS cardinality_pct, ',
            'multiIf(',
            '(uniq(', col, ') / count()) * 100 > 1.0, ''❌ Too High'', ',
            '(uniq(', col, ') / count()) * 100 > 0.1, ''⚠️ Borderline'', ',
            '(uniq(', col, ') / count()) * 100 > 0.01, ''✅ Good'', ',
            '''✅ Perfect'') AS lc_recommendation ',
            'FROM observations.deduped_observations_lc'
        ),
        groupArray(name)
    ),
    ' UNION ALL '
) || ' ORDER BY cardinality_pct DESC' AS generated_query
FROM table_cols;
