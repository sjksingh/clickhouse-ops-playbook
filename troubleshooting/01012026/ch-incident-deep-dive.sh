#!/usr/bin/env bash
#
# ch-incident-deep-dive.sh
# Deep forensic analysis of a performance degradation period
# Usage: ./ch-incident-deep-dive.sh '2025-12-28' 'BAD8B1490FD8F110'
#

source ch_login.sh || {
  echo "❌ ch_login.sh not found"
  exit 1
}

INCIDENT_DATE="${1:-2025-12-28}"
QUERY_HASH="${2:-BAD8B1490FD8F110}"

echo "🔍 INCIDENT FORENSICS"
echo "====================="
echo "Date: $INCIDENT_DATE"
echo "Query: $QUERY_HASH"
echo ""

# 1. Find the actual slowest queries
echo "📊 TOP 10 SLOWEST EXECUTIONS"
echo "-----------------------------"
ch_query "
SELECT 
  event_time,
  round(query_duration_ms/1000, 2) AS duration_sec,
  formatReadableSize(memory_usage) AS memory,
  ProfileEvents['SelectedParts'] AS parts,
  formatReadableSize(read_bytes) AS bytes_read,
  ProfileEvents['MergeTreeDataSelectExecutionMicroseconds'] AS select_us,
  ProfileEvents['MergeTreeDataSelectWaitForReadingMilliseconds'] AS wait_read_ms,
  exception_code
FROM system.query_log
WHERE toDate(event_time) = '$INCIDENT_DATE'
  AND hex(cityHash64(normalizeQuery(query))) = '$QUERY_HASH'
  AND type IN ('QueryFinish', 'ExceptionWhileProcessing')
ORDER BY query_duration_ms DESC
LIMIT 10
FORMAT PrettyCompact
"

echo ""
echo "🔥 SYSTEM RESOURCE COMPETITION"
echo "-------------------------------"
echo "What else was happening during slow periods?"

ch_query "
WITH slow_periods AS (
  SELECT 
    toStartOfHour(event_time) AS hour
  FROM system.query_log
  WHERE toDate(event_time) = '$INCIDENT_DATE'
    AND hex(cityHash64(normalizeQuery(query))) = '$QUERY_HASH'
    AND query_duration_ms > 10000  -- Queries over 10s
  GROUP BY hour
)
SELECT 
  toStartOfHour(ql.event_time) AS hour,
  count() AS total_queries,
  countIf(query_duration_ms > 5000) AS slow_queries,
  round(sum(query_duration_ms)/1000, 0) AS total_db_time_sec,
  formatReadableSize(sum(memory_usage)) AS total_memory,
  uniqExact(user) AS unique_users,
  groupUniqArray(5)(user) AS top_users
FROM system.query_log ql
INNER JOIN slow_periods sp ON toStartOfHour(ql.event_time) = sp.hour
WHERE toDate(ql.event_time) = '$INCIDENT_DATE'
  AND type = 'QueryFinish'
GROUP BY hour
ORDER BY hour
FORMAT PrettyCompact
"

echo ""
echo "💾 MERGE ACTIVITY DURING INCIDENT"
echo "----------------------------------"
ch_query "
SELECT 
  toStartOfHour(event_time) AS hour,
  database,
  table,
  count() AS merge_count,
  round(avg(elapsed), 2) AS avg_merge_time_sec,
  round(max(elapsed), 2) AS max_merge_time_sec,
  formatReadableSize(sum(total_size_bytes_compressed)) AS total_merged
FROM system.query_log
WHERE toDate(event_time) = '$INCIDENT_DATE'
  AND query LIKE '%OPTIMIZE%' OR query LIKE '%MERGE%'
  AND type = 'QueryFinish'
GROUP BY hour, database, table
ORDER BY hour, max_merge_time_sec DESC
FORMAT PrettyCompact
" 2>/dev/null || echo "No explicit OPTIMIZE commands found"

# Check background merges (from system.part_log if available)
ch_query "
SELECT 
  toStartOfHour(event_time) AS hour,
  database,
  table,
  count() AS merge_operations,
  round(avg(duration_ms/1000), 2) AS avg_duration_sec,
  round(max(duration_ms/1000), 2) AS max_duration_sec,
  formatReadableSize(sum(size_in_bytes)) AS total_size
FROM system.part_log
WHERE toDate(event_time) = '$INCIDENT_DATE'
  AND event_type = 'MergeParts'
  AND database = 'observations'
GROUP BY hour, database, table
ORDER BY hour, total_size DESC
FORMAT PrettyCompact
" 2>/dev/null || echo "⚠️  system.part_log not available (not enabled or retention expired)"

echo ""
echo "📈 PARTS COUNT EVOLUTION"
echo "------------------------"
echo "Did parts explosion cause the slowdown?"

ch_query "
SELECT 
  hour,
  avg_parts,
  max_parts,
  CASE 
    WHEN max_parts > 50 THEN '🔴 HIGH'
    WHEN max_parts > 40 THEN '🟡 ELEVATED'
    ELSE '🟢 NORMAL'
  END AS status
FROM (
  SELECT 
    toStartOfHour(event_time) AS hour,
    round(avg(ProfileEvents['SelectedParts']), 1) AS avg_parts,
    max(ProfileEvents['SelectedParts']) AS max_parts
  FROM system.query_log
  WHERE toDate(event_time) = '$INCIDENT_DATE'
    AND hex(cityHash64(normalizeQuery(query))) = '$QUERY_HASH'
    AND type = 'QueryFinish'
  GROUP BY hour
)
ORDER BY hour
FORMAT PrettyCompact
"

echo ""
echo "🌐 ZOOKEEPER / REPLICATION ISSUES"
echo "----------------------------------"
ch_query "
SELECT 
  toStartOfHour(event_time) AS hour,
  countIf(event_type = 'ReplicatedPartFetchesFailure') AS fetch_failures,
  countIf(event_type = 'ReplicatedPartMerges') AS part_merges,
  countIf(event_type = 'ReplicatedPartFailedFetches') AS failed_fetches
FROM system.replication_queue_log
WHERE toDate(event_time) = '$INCIDENT_DATE'
GROUP BY hour
HAVING fetch_failures > 0 OR failed_fetches > 0
ORDER BY hour
FORMAT PrettyCompact
" 2>/dev/null || echo "⚠️  system.replication_queue_log not available"

echo ""
echo "💡 LIKELY ROOT CAUSES (Ranked by Evidence)"
echo "--------------------------------------------"

# Analyze and rank probable causes
ch_query "
WITH 
  slow_query_stats AS (
    SELECT 
      toStartOfHour(event_time) AS hour,
      avg(query_duration_ms/1000) AS avg_duration,
      max(ProfileEvents['SelectedParts']) AS max_parts
    FROM system.query_log
    WHERE toDate(event_time) = '$INCIDENT_DATE'
      AND hex(cityHash64(normalizeQuery(query))) = '$QUERY_HASH'
      AND type = 'QueryFinish'
    GROUP BY hour
  ),
  system_load AS (
    SELECT 
      toStartOfHour(event_time) AS hour,
      count() AS concurrent_queries
    FROM system.query_log
    WHERE toDate(event_time) = '$INCIDENT_DATE'
      AND type = 'QueryFinish'
    GROUP BY hour
  )
SELECT 
  sq.hour,
  round(sq.avg_duration, 2) AS avg_duration_sec,
  sq.max_parts,
  sl.concurrent_queries,
  multiIf(
    sq.max_parts > 50, 
      '🔴 Parts explosion (max_parts=' || toString(sq.max_parts) || ')',
    sl.concurrent_queries > 100,
      '🟠 High system load (' || toString(sl.concurrent_queries) || ' concurrent queries)',
    sq.avg_duration > 10,
      '🟡 General system slowdown',
    '🟢 Normal operation'
  ) AS likely_cause
FROM slow_query_stats sq
LEFT JOIN system_load sl ON sq.hour = sl.hour
WHERE sq.avg_duration > 8
ORDER BY sq.hour
FORMAT PrettyCompact
"

echo ""
echo "🎯 RECOMMENDATIONS"
echo "------------------"
echo "Based on the evidence above:"
echo ""
echo "1. If PARTS EXPLOSION detected:"
echo "   → Run: OPTIMIZE TABLE observations.deduped_observations_2 FINAL"
echo "   → Consider: Adjusting merge settings to be more aggressive"
echo ""
echo "2. If HIGH SYSTEM LOAD detected:"
echo "   → Implement: Query throttling or rate limiting"
echo "   → Consider: Read replicas to distribute load"
echo ""
echo "3. If REPLICATION ISSUES detected:"
echo "   → Check: ZooKeeper health and connectivity"
echo "   → Review: Replication queue length"
echo ""
echo "4. If GENERAL SLOWDOWN (no specific cause):"
echo "   → Monitor: Disk I/O, network latency"
echo "   → Consider: This might be external (AWS/cloud provider issues)"

echo ""
echo "📝 NEXT STEPS"
echo "-------------"
echo "1. Review the data above to identify patterns"
echo "2. Check if similar patterns exist on other dates"
echo "3. Set up alerts for these conditions BEFORE they cause incidents"
echo "4. Document findings in your incident log"
