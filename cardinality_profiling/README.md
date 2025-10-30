# ClickHouse Column Cardinality Profiling

This folder contains scripts and instructions to calculate column cardinality
for ClickHouse tables. Cardinality % helps assess:

- Column uniqueness (high vs low cardinality)
- Appropriateness for `LowCardinality(String)`
- Storage/compression considerations
- Performance considerations

## Steps

1. Generate the cardinality query using `generate_cardinality_query.sql`
2. Execute the query to get raw counts (`uniq(column)` + `count()`)
