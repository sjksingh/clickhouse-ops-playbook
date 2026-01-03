#!/usr/bin/env bash
# Quick Cardinality Checker for String Columns
source ch_login.sh || { echo "❌ missing ch_login.sh"; exit 1; }

TABLE="${1:-observations.measurement_id_lookup_3}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 CARDINALITY ANALYSIS: $TABLE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "📊 Analyzing observation_group_key..."
ch_query "
SELECT
    'observation_group_key' AS column_name,
    count() AS total_rows,
    uniqExact(observation_group_key) AS unique_values,
    round(unique_values::Float64 / total_rows * 100, 2) AS cardinality_pct,
    round(avg(length(observation_group_key)), 1) AS avg_length,
    min(length(observation_group_key)) AS min_length,
    max(length(observation_group_key)) AS max_length,
    any(observation_group_key) AS sample1,
    anyLast(observation_group_key) AS sample2
FROM $TABLE
FORMAT Vertical
"
echo ""

echo "📊 Analyzing asset_key..."
ch_query "
SELECT
    'asset_key' AS column_name,
    count() AS total_rows,
    uniqExact(asset_key) AS unique_values,
    round(unique_values::Float64 / total_rows * 100, 2) AS cardinality_pct,
    round(avg(length(asset_key)), 1) AS avg_length,
    min(length(asset_key)) AS min_length,
    max(length(asset_key)) AS max_length,
    any(asset_key) AS sample1,
    anyLast(asset_key) AS sample2
FROM $TABLE
FORMAT Vertical
"
echo ""

echo "📊 Analyzing observation_owner_domain..."
ch_query "
SELECT
    'observation_owner_domain' AS column_name,
    count() AS total_rows,
    uniqExact(observation_owner_domain) AS unique_values,
    round(unique_values::Float64 / total_rows * 100, 2) AS cardinality_pct,
    round(avg(length(observation_owner_domain)), 1) AS avg_length,
    min(length(observation_owner_domain)) AS min_length,
    max(length(observation_owner_domain)) AS max_length,
    any(observation_owner_domain) AS sample1,
    anyLast(observation_owner_domain) AS sample2
FROM $TABLE
FORMAT Vertical
"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎯 INTERPRETATION GUIDE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Cardinality Thresholds:"
echo "  < 0.1%  → Use LowCardinality(String) - 10-30x compression"
echo "  < 1%    → Use LowCardinality(String) - 8-15x compression"
echo "  < 5%    → Use LowCardinality(String) - 5-10x compression"
echo "  5-50%   → Regular String CODEC(LZ4) - 3-4x compression"
echo "  > 50%   → Analyze pattern (UUID=LZ4, JSON=ZSTD, Text=LZ4)"
echo ""
echo "Pattern Detection (check samples):"
echo "  Length=36 with dashes → UUID → Use String CODEC(LZ4)"
echo "  Contains { or [ → JSON → Use String CODEC(ZSTD(3))"
echo "  Domain format → DNS → Likely low cardinality"
echo "  Variable length → Text → Check cardinality first"
echo ""
echo "Current Compression Analysis:"
echo "  Ratio >100x → EXTREMELY low cardinality (likely <0.01%)"
echo "  Ratio 10-50x → Low cardinality (likely <1%)"
echo "  Ratio 3-10x → Medium cardinality (1-10%)"
echo "  Ratio <3x → High cardinality (>50%)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
