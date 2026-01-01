#!/usr/bin/env bash
#
# ch-pattern-analyzer.sh
# Builds a historical profile of query patterns to detect anomalies
# Run this every 5 minutes via cron to build your baseline
#

source ch_login.sh || {
  echo "❌ ch_login.sh not found"
  exit 1
}

LOGDIR="${HOME}/.clickhouse_patterns"
mkdir -p "$LOGDIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${LOGDIR}/pattern_${TIMESTAMP}.json"

echo "🔍 Analyzing query patterns..."

# Capture query fingerprints with their resource profiles
ch_query "
WITH query_patterns AS (
  SELECT
    hex(cityHash64(normalizeQuery(query))) AS query_hash,
    normalizeQuery(query) AS query_template,
    user,
    query_kind,
    
    -- Resource profile
    count() AS execution_count,
    round(avg(query_duration_ms/1000), 2) AS avg_sec,
    round(max(query_duration_ms/1000), 2) AS max_sec,
    round(quantile(0.95)(query_duration_ms/1000), 2) AS p95_sec,
    
    formatReadableSize(avg(memory_usage)) AS avg_memory,
    formatReadableSize(max(memory_usage)) AS max_memory,
    
    formatReadableSize(avg(read_bytes)) AS avg_bytes,
    formatReadableSize(max(read_bytes)) AS max_bytes,
    
    round(avg(read_rows), 0) AS avg_rows,
    round(max(read_rows), 0) AS max_rows,
    
    avg(ProfileEvents['SelectedParts']) AS avg_parts,
    max(ProfileEvents['SelectedParts']) AS max_parts,
    
    -- Trend indicators
    max(event_time) AS last_seen,
    min(event_time) AS first_seen
    
  FROM system.query_log
  WHERE event_time > now() - INTERVAL 1 HOUR
    AND type = 'QueryFinish'
    AND query NOT LIKE '%system.query_log%'  -- exclude monitoring queries
  GROUP BY query_hash, query_template, user, query_kind
)
SELECT 
  *,
  multiIf(
    max_sec > 10 AND execution_count > 10, '🚨 CRITICAL: Frequent slow query',
    max_sec > 30, '⚠️  ALERT: Very slow execution detected',
    max_parts > 1000, '🔥 WARNING: Parts explosion pattern',
    p95_sec > 5, '⚡ WATCH: Performance degrading',
    '✅ Normal'
  ) AS severity
FROM query_patterns
ORDER BY max_sec DESC
LIMIT 20
FORMAT JSONEachRow
" > "$REPORT"

# Generate human-readable summary
echo ""
echo "📊 TOP RESOURCE CONSUMERS (Last hour)"
echo "======================================="

cat "$REPORT" | jq -r '
  "Hash: \(.query_hash) | Executions: \(.execution_count) | P95: \(.p95_sec)s | Max: \(.max_sec)s
  User: \(.user) | Memory: \(.max_memory) | Parts: \(.max_parts)
  Severity: \(.severity)
  Template: \(.query_template[0:150])...
  ---"
' | head -n 40

# Detect anomalies by comparing to historical baseline
if [ -f "${LOGDIR}/baseline.json" ]; then
  echo ""
  echo "🔔 ANOMALY DETECTION"
  echo "===================="
  
  # Compare current patterns against baseline
  jq -s '
    .[0] as $baseline |
    .[1] as $current |
    
    ($current | map({(.query_hash): .}) | add) as $current_map |
    ($baseline | map({(.query_hash): .}) | add) as $baseline_map |
    
    $current_map | to_entries | map(
      .value as $curr |
      ($baseline_map[.key] // {}) as $base |
      
      select($base != {}) |
      
      {
        query_hash: .key,
        user: $curr.user,
        baseline_p95: ($base.p95_sec // 0),
        current_p95: ($curr.p95_sec // 0),
        degradation: (
          if ($base.p95_sec // 0) > 0 
          then (($curr.p95_sec // 0) / ($base.p95_sec // 0) * 100) - 100
          else 0
          end
        ),
        template: $curr.query_template[0:100]
      } |
      select(.degradation > 50)  -- Alert if 50% slower than baseline
    ) | 
    sort_by(-.degradation) |
    .[] |
    "⚠️  Query \(.query_hash) is \(.degradation | round)% SLOWER than baseline
    Baseline P95: \(.baseline_p95)s → Current P95: \(.current_p95)s
    User: \(.user)
    Template: \(.template)...
    "
  ' "${LOGDIR}/baseline.json" "$REPORT"
else
  echo "💡 No baseline found. Run this script regularly to establish baseline."
  cp "$REPORT" "${LOGDIR}/baseline.json"
fi

# Keep only last 100 reports (prevent disk bloat)
ls -t "$LOGDIR"/pattern_*.json | tail -n +101 | xargs -r rm

echo ""
echo "✅ Pattern data saved to: $REPORT"
echo "💡 Schedule this via cron: */5 * * * * $0"
