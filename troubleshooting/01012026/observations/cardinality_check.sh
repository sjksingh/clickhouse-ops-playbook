#!/usr/bin/env bash
# Usge cardinality_check.sh observations.observations
source ch_login.sh || { echo "❌ missing ch_login.sh"; exit 1; }

# Get table from argument or use default
TABLE="${1:-observations.issue_severity}"

# Extract DB and Table names
DB_NAME=$(echo $TABLE | awk -F. '{if (NF>1) print $1; else print "default"}')
TBL_NAME=$(echo $TABLE | awk -F. '{if (NF>1) print $2; else print $1}')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 DYNAMIC ANALYSIS: $TABLE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Fetch columns: format as CSV to avoid alignment issues, then strip quotes and header
COLUMNS=$(ch_query "
    SELECT name 
    FROM system.columns 
    WHERE database = '$DB_NAME' 
      AND table = '$TBL_NAME' 
      AND (type = 'String' OR type LIKE 'LowCardinality%')
    FORMAT TabSeparated
" | grep -v "^name$" | xargs)

if [ -z "$COLUMNS" ]; then
    echo "ℹ️ No String columns found in $TABLE to analyze."
else
    for COL in $COLUMNS; do
        echo "📊 Analyzing Column: $COL..."
        ch_query "
        SELECT
            '$COL' AS column_name,
            count() AS total_rows,
            uniqExact(\"$COL\") AS unique_values,
            round(unique_values / total_rows * 100, 2) AS cardinality_pct,
            round(avg(length(\"$COL\")), 1) AS avg_length,
            any(\"$COL\") AS sample_1
        FROM $TABLE
        FORMAT Vertical
        "
        echo "-----------------------------------------------"
    done
fi

echo "📋 Metadata for Non-String Columns (Enums/Integers):"
ch_query "
    SELECT name, type 
    FROM system.columns 
    WHERE database = '$DB_NAME' 
      AND table = '$TBL_NAME' 
      AND type NOT LIKE 'String' AND type NOT LIKE 'LowCardinality%'
    FORMAT TabSeparated
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
