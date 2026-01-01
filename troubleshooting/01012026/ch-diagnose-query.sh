#!/usr/bin/env bash
#
# ch-diagnose-query.sh
# Deep-dive analysis of a specific slow query
# Usage: ./ch-diagnose-query.sh <query_hash>
#

source ch_login.sh || {
  echo "❌ ch_login.sh not found"
  exit 1
}

QUERY_HASH="${1:-BAD8B1490FD8F110}"  # Your problematic query

echo "🔍 Diagnosing query: $QUERY_HASH"
echo "========================================"
echo ""

# 1. Get query execution history
echo "📊 EXECUTION HISTORY (Last 7 days)"
echo "-----------------------------------"
ch_query "
SELECT 
  toStartOfHour(event_time) AS hour,
  count() AS executions,
  round(avg(query_duration_ms/1000), 2) AS avg_sec,
  round(min(query_duration_ms/1000), 2) AS min_sec,
  round(max(query_duration_ms/1000), 2) AS max_sec,
  round(quantile(0.95)(query_duration_ms/1000), 2) AS p95_sec,
  formatReadableSize(avg(memory_usage)) AS avg_mem,
  formatReadableSize(max(memory_usage)) AS max_mem,
  round(avg(read_bytes), 0) AS avg_bytes_read
FROM system.query_log
WHERE hex(cityHash64(normalizeQuery(query))) = '$QUERY_HASH'
  AND type = 'QueryFinish'
  AND event_time > now() - INTERVAL 7 DAY
GROUP BY hour
ORDER BY hour DESC
LIMIT 24
FORMAT PrettyCompact
"

echo ""
echo "📈 TREND ANALYSIS"
echo "-----------------"
ch_query "
WITH daily_stats AS (
  SELECT 
    toDate(event_time) AS day,
    count() AS executions,
    round(quantile(0.95)(query_duration_ms/1000), 2) AS p95_sec,
    formatReadableSize(quantile(0.95)(memory_usage)) AS p95_mem
  FROM system.query_log
  WHERE hex(cityHash64(normalizeQuery(query))) = '$QUERY_HASH'
    AND type = 'QueryFinish'
    AND event_time > now() - INTERVAL 7 DAY
  GROUP BY day
)
SELECT 
  day,
  executions,
  p95_sec,
  p95_mem,
  CASE 
    WHEN lag(p95_sec) OVER (ORDER BY day) = 0 THEN 'N/A'
    ELSE concat(
      round((p95_sec - lag(p95_sec) OVER (ORDER BY day)) / lag(p95_sec) OVER (ORDER BY day) * 100, 1),
      '% ',
      if(p95_sec > lag(p95_sec) OVER (ORDER BY day), '📈 SLOWER', '📉 FASTER')
    )
  END AS trend
FROM daily_stats
ORDER BY day DESC
FORMAT PrettyCompact
"

echo ""
echo "🔍 QUERY PLAN ANALYSIS"
echo "----------------------"

# Get the actual query
FULL_QUERY=$(ch_query "
SELECT query 
FROM system.query_log 
WHERE hex(cityHash64(normalizeQuery(query))) = '$QUERY_HASH'
  AND type = 'QueryFinish'
ORDER BY event_time DESC 
LIMIT 1
" --format=TSVRaw)

if [ -z "$FULL_QUERY" ]; then
  echo "❌ Query not found in query_log"
  exit 1
fi

# Save normalized query for inspection
echo "$FULL_QUERY" | head -c 500
echo "..."
echo ""
echo "(Full query saved to /tmp/query_${QUERY_HASH}.sql for inspection)"
echo "$FULL_QUERY" > "/tmp/query_${QUERY_HASH}.sql"

# Try to get query plan (may fail on complex queries)
echo ""
echo "⚙️  Attempting EXPLAIN PLAN (may skip if query too complex)..."
# Don't fail the whole script if EXPLAIN fails
ch_query "EXPLAIN PLAN $FULL_QUERY" --format=Pretty 2>/dev/null | head -n 30 || \
  echo "⚠️  EXPLAIN PLAN failed (query too complex or has syntax ClickHouse doesn't like in EXPLAIN)"

echo ""
echo "🎯 BOTTLENECK IDENTIFICATION"
echo "----------------------------"

ch_query "
WITH latest_exec AS (
  SELECT 
    query,
    ProfileEvents,
    memory_usage,
    read_rows,
    read_bytes,
    query_duration_ms
  FROM system.query_log
  WHERE hex(cityHash64(normalizeQuery(query))) = '$QUERY_HASH'
    AND type = 'QueryFinish'
  ORDER BY event_time DESC
  LIMIT 1
)
SELECT 
  'Memory Usage' AS metric,
  formatReadableSize(memory_usage) AS value,
  multiIf(
    memory_usage > 2e9, '🔴 CRITICAL: Risk of OOM',
    memory_usage > 1e9, '🟠 HIGH: Monitor closely',
    '🟢 OK'
  ) AS status
FROM latest_exec
UNION ALL
SELECT 
  'Parts Read',
  toString(ProfileEvents['SelectedParts']),
  multiIf(
    ProfileEvents['SelectedParts'] > 1000, '🔴 CRITICAL: Parts explosion',
    ProfileEvents['SelectedParts'] > 100, '🟠 HIGH: Merge needed',
    '🟢 OK'
  )
FROM latest_exec
UNION ALL
SELECT 
  'Data Scanned',
  formatReadableSize(read_bytes),
  multiIf(
    read_bytes > 50e9, '🔴 CRITICAL: Massive scan',
    read_bytes > 10e9, '🟠 HIGH: Consider indexing',
    '🟢 OK'
  )
FROM latest_exec
UNION ALL
SELECT 
  'Processing Rate',
  concat(round(read_rows / (query_duration_ms/1000), 0), ' rows/sec'),
  multiIf(
    read_rows / (query_duration_ms/1000) < 5000, '🔴 CRITICAL: CPU-bound',
    read_rows / (query_duration_ms/1000) < 50000, '🟡 MEDIUM: Review plan',
    '🟢 OK'
  )
FROM latest_exec
UNION ALL
SELECT 
  'Joins Executed',
  toString(ProfileEvents['JoinExecuted']),
  multiIf(
    ProfileEvents['JoinExecuted'] > 5, '🟠 HIGH: Too many joins',
    ProfileEvents['JoinExecuted'] > 3, '🟡 MEDIUM: Consider denormalization',
    '🟢 OK'
  )
FROM latest_exec
FORMAT PrettyCompact
"

echo ""
echo "💡 RECOMMENDATIONS"
echo "------------------"

# Analyze and recommend
ch_query "
WITH latest_exec AS (
  SELECT 
    ProfileEvents,
    memory_usage,
    read_bytes,
    read_rows,
    query_duration_ms
  FROM system.query_log
  WHERE hex(cityHash64(normalizeQuery(query))) = '$QUERY_HASH'
    AND type = 'QueryFinish'
  ORDER BY event_time DESC
  LIMIT 1
)
SELECT 
  recommendation,
  priority,
  impact
FROM (
  SELECT 
    '1. Enable external GROUP BY' AS recommendation,
    '🔴 HIGH' AS priority,
    'Prevents OOM, enables larger aggregations' AS impact
  FROM latest_exec
  WHERE memory_usage > 2e9
  
  UNION ALL
  
  SELECT 
    '2. Force table OPTIMIZE',
    '🟠 MEDIUM',
    'Reduces parts from ' || toString(ProfileEvents['SelectedParts']) || ' to ~10-20'
  FROM latest_exec
  WHERE ProfileEvents['SelectedParts'] > 100
  
  UNION ALL
  
  SELECT 
    '3. Add primary key to WHERE clause',
    '🔴 HIGH',
    'Reduce data scan from ' || formatReadableSize(read_bytes) || ' to <5GB'
  FROM latest_exec
  WHERE read_bytes > 10e9
  
  UNION ALL
  
  SELECT 
    '4. Materialize complex multiIf expressions',
    '🟡 MEDIUM',
    'Improve processing from ' || toString(round(read_rows/(query_duration_ms/1000),0)) || ' to >50k rows/sec'
  FROM latest_exec
  WHERE read_rows / (query_duration_ms/1000) < 10000
  
  UNION ALL
  
  SELECT 
    '5. Convert JOINs to dictionaries',
    '🟠 MEDIUM',
    'Eliminate ' || toString(ProfileEvents['JoinExecuted']) || ' joins, 2-5x speedup'
  FROM latest_exec
  WHERE ProfileEvents['JoinExecuted'] > 3
  
  UNION ALL
  
  SELECT 
    '6. Create materialized view for this pattern',
    '🟢 LOW',
    'Pre-aggregate, serve in <1s instead of ' || toString(round(query_duration_ms/1000,1)) || 's'
  FROM latest_exec
  WHERE query_duration_ms > 5000
)
FORMAT PrettyCompact
"

echo ""
echo "📝 NEXT STEPS"
echo "-------------"
echo "1. Review recommendations above"
echo "2. Apply RB-XXX runbook from the playbook"
echo "3. Test fix in dev/staging first"
echo "4. Measure improvement with: ./ch-diagnose-query.sh $QUERY_HASH"
echo "5. Document in your optimization log"
echo ""
echo "🔗 Related runbooks:"
ch_query "
SELECT DISTINCT
  multiIf(
    ProfileEvents['PeakMemoryUsage'] > 2e9 OR memory_usage > 2e9,
      '  - RB-001: Memory-heavy / OOM Risk',
    ProfileEvents['SelectedParts'] > 1000,
      '  - RB-002: Parts Explosion',
    read_bytes / greatest(query_duration_ms/1000, 0.01) > 200000000,
      '  - RB-003: IO-bound Heavy Scan',
    read_rows / greatest(query_duration_ms/1000, 0.01) < 5000,
      '  - RB-004: CPU-bound / Bad Plan',
    ProfileEvents['JoinExecuted'] > 3,
      '  - RB-005: Join-heavy Workload',
    ''
  ) AS runbook
FROM system.query_log
WHERE hex(cityHash64(normalizeQuery(query))) = '$QUERY_HASH'
  AND type = 'QueryFinish'
ORDER BY event_time DESC
LIMIT 1
" --format=TSVRaw
