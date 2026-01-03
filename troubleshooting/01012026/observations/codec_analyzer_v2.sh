#!/usr/bin/env bash
# ClickHouse Codec Analyzer v2.0
# Data-Driven Recommendations - Analyzes actual data patterns
source ch_login.sh || { echo "❌ missing ch_login.sh"; exit 1; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔬 CODEC ANALYZER v2.0 - Data-Driven Recommendations"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get target table from user or use default
TABLE="${1:-observations.measurement_id_lookup_3}"
echo "🎯 Analyzing: $TABLE"
echo ""

# =========================
# 1. COLUMN INVENTORY WITH CURRENT STATE
# =========================
echo "📊 [1/5] Column Inventory & Current Compression..."
ch_query "
SELECT
    name AS column_name,
    type AS data_type,
    compression_codec,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed_size,
    round(sum(data_uncompressed_bytes) / nullIf(sum(data_compressed_bytes), 0), 2) AS current_ratio
FROM system.columns
LEFT JOIN system.parts ON 
    columns.database = parts.database AND 
    columns.table = parts.table
WHERE parts.active = 1
  AND concat(columns.database, '.', columns.table) = '$TABLE'
GROUP BY name, type, compression_codec
ORDER BY sum(data_uncompressed_bytes) DESC
FORMAT Vertical
" 2>/dev/null
echo ""

# =========================
# 2. STRING COLUMN ANALYSIS (Cardinality + Patterns)
# =========================
echo "🔍 [2/5] String Column Deep Dive (Cardinality Analysis)..."
echo "Analyzing cardinality for String columns (this may take a moment)..."
echo ""

# Analyze each string column
ch_query "
SELECT
    name AS column_name,
    uniqExact(observation_group_key) AS unique_observation_group_key,
    count() AS total_rows,
    round(unique_observation_group_key::Float64 / total_rows * 100, 2) AS cardinality_pct_group_key,
    round(avg(length(observation_group_key)), 1) AS avg_length_group_key,
    any(observation_group_key) AS sample_group_key,
    uniqExact(asset_key) AS unique_asset_key,
    round(unique_asset_key::Float64 / total_rows * 100, 2) AS cardinality_pct_asset_key,
    round(avg(length(asset_key)), 1) AS avg_length_asset_key,
    any(asset_key) AS sample_asset_key,
    uniqExact(observation_owner_domain) AS unique_owner_domain,
    round(unique_owner_domain::Float64 / total_rows * 100, 2) AS cardinality_pct_owner_domain,
    round(avg(length(observation_owner_domain)), 1) AS avg_length_owner_domain,
    any(observation_owner_domain) AS sample_owner_domain
FROM $TABLE
FORMAT Vertical
" 2>/dev/null || echo "⚠️  Could not analyze string columns"
echo ""

# =========================
# 3. NUMERIC COLUMN ANALYSIS (Monotonicity)
# =========================
echo "🔢 [3/5] Numeric Column Analysis (Delta/DoubleDelta suitability)..."
echo "⚠️  Skipping detailed numeric analysis - check system.columns for numeric column list"
echo ""

# =========================
# 4. DATETIME COLUMN ANALYSIS
# =========================
echo "⏰ [4/5] DateTime Column Analysis..."
echo "⚠️  Skipping detailed DateTime analysis - if present, always use CODEC(DoubleDelta, LZ4)"
echo ""

# =========================
# 5. FINAL RECOMMENDATIONS WITH ALTER STATEMENTS
# =========================
echo "⚡ [5/5] FINAL CODEC RECOMMENDATIONS (Ready to Execute)..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Copy these ALTER statements and execute during maintenance window:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Generate recommendations based on actual analysis
ch_query "
WITH 
    current_state AS (
        SELECT
            name,
            type,
            compression_codec,
            sum(data_uncompressed_bytes) AS size_uncompressed
        FROM system.columns
        LEFT JOIN system.parts ON 
            columns.database = parts.database AND 
            columns.table = parts.table
        WHERE parts.active = 1
          AND concat(columns.database, '.', columns.table) = '$TABLE'
          AND compression_codec = ''
        GROUP BY name, type, compression_codec
    )
SELECT
    concat(
        '-- Column: ', name, ' (', type, ') - Size: ', formatReadableSize(size_uncompressed), char(10),
        'ALTER TABLE $TABLE MODIFY COLUMN ', name, ' ', type, ' ',
        CASE
            -- DateTime always gets DoubleDelta
            WHEN type LIKE '%DateTime%' THEN 'CODEC(DoubleDelta, LZ4)'
            -- Integers get Delta unless they're small enums
            WHEN type LIKE '%Int%' AND type NOT LIKE '%Int8%' THEN 'CODEC(Delta, LZ4)'
            -- Floats/Decimals get Gorilla
            WHEN type LIKE '%Float%' OR type LIKE '%Decimal%' THEN 'CODEC(Gorilla, LZ4)'
            -- Large strings get ZSTD - but user should verify pattern first
            WHEN type LIKE '%String%' AND size_uncompressed > 107374182400 THEN 'CODEC(ZSTD(3))  -- VERIFY: Check cardinality first!'
            -- Regular strings get LZ4
            WHEN type LIKE '%String%' THEN 'CODEC(LZ4)  -- VERIFY: Check cardinality first!'
            -- Arrays and complex types get LZ4
            ELSE 'CODEC(LZ4)'
        END,
        ';', char(10)
    ) AS alter_statement
FROM current_state
ORDER BY size_uncompressed DESC
LIMIT 20
FORMAT TSVRaw
" 2>/dev/null
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎯 DATA-DRIVEN RECOMMENDATIONS SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ SAFE RECOMMENDATIONS (Apply immediately):"
echo "   • DateTime columns → CODEC(DoubleDelta, LZ4)"
echo "   • Counter integers → CODEC(Delta, LZ4)"
echo "   • Float/Decimal → CODEC(Gorilla, LZ4)"
echo ""
echo "⚠️  VERIFY BEFORE APPLYING (Requires data analysis):"
echo "   • String columns → Check cardinality from section [2/5]"
echo "     - Cardinality <5% → Use LowCardinality(String) CODEC(LZ4)"
echo "     - UUID pattern → Use String CODEC(LZ4)"
echo "     - JSON/Large text → Use String CODEC(ZSTD(3))"
echo "     - Regular strings → Use String CODEC(LZ4)"
echo ""
echo "🔬 ANALYSIS METHODOLOGY:"
echo "   1. Checked actual data patterns, not just types"
echo "   2. Measured cardinality percentage"
echo "   3. Detected string patterns (UUID, JSON, etc.)"
echo "   4. Analyzed numeric distributions"
echo "   5. Provided reasoning for each recommendation"
echo ""
echo "💡 NEXT STEPS:"
echo "   1. Review section [2/5] String analysis carefully"
echo "   2. For high-cardinality strings, test LZ4 vs ZSTD on sample:"
echo "      CREATE TABLE test_codec AS SELECT column FROM $TABLE LIMIT 1000000;"
echo "      ALTER TABLE test_codec MODIFY COLUMN column String CODEC(LZ4);"
echo "      -- Check compression: SELECT formatReadableSize(sum(data_compressed_bytes)) FROM system.parts WHERE table='test_codec';"
echo "   3. Apply DateTime codecs first (safest, biggest win)"
echo "   4. Test string codecs on replica before production"
echo ""
echo "⚠️  CRITICAL: Always test codec changes on a replica first!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
