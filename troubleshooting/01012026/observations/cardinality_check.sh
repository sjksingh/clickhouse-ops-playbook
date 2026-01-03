#!/usr/bin/env bash
# Usge cardinality_check.sh observations.observations
source ch_login.sh || { echo "❌ missing ch_login.sh"; exit 1; }

TABLE="${1:-observations.observations}"
DB_NAME=$(echo $TABLE | awk -F. '{if (NF>1) print $1; else print "default"}')
TBL_NAME=$(echo $TABLE | awk -F. '{if (NF>1) print $2; else print $1}')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 SMART CARDINALITY ANALYSIS: $TABLE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Fetch String/LowCardinality columns
COLUMNS=$(ch_query "
    SELECT name 
    FROM system.columns 
    WHERE database = '$DB_NAME' 
      AND table = '$TBL_NAME' 
      AND (type = 'String' OR type LIKE 'LowCardinality%')
    FORMAT TabSeparated
" | grep -v "^name$" | xargs)

if [ -z "$COLUMNS" ]; then
    echo "ℹ️ No String columns found."
else
    for COL in $COLUMNS; do
        echo "📊 Analyzing: $COL..."
        
        # Get stats into variables
        RESULT=$(ch_query "
            SELECT 
                count(), 
                uniqExact(\"$COL\"), 
                round(uniqExact(\"$COL\") / count() * 100, 2),
                round(avg(length(\"$COL\")), 1),
                any(\"$COL\")
            FROM $TABLE 
            FORMAT TabSeparated" | tr -d '\r')

        # Parse result line
        TOTAL_ROWS=$(echo $RESULT | awk '{print $1}')
        UNIQ_VALS=$(echo $RESULT | awk '{print $2}')
        CARD_PCT=$(echo $RESULT | awk '{print $3}')
        AVG_LEN=$(echo $RESULT | awk '{print $4}')
        SAMPLE=$(echo $RESULT | cut -d' ' -f5-)

        # Logic for Emojis
        STATUS="✅ OK"
        ADVICE="Keep as is."
        
        if (( $(echo "$CARD_PCT < 5.0" | bc -l) )); then
            STATUS="🚀 OPTIMIZE"
            ADVICE="Convert to LowCardinality(String) for HUGE savings!"
        fi

        if (( $(echo "$CARD_PCT > 60.0" | bc -l) )); then
            STATUS="🛑 SKIP"
            ADVICE="High cardinality. LowCardinality would hurt performance."
        fi

        # Output formatting
        echo "   Status:      $STATUS"
        echo "   Recommendation: $ADVICE"
        echo "   Total Rows:  $TOTAL_ROWS"
        echo "   Unique:      $UNIQ_VALS ($CARD_PCT%)"
        echo "   Avg Length:  $AVG_LEN bytes"
        echo "   Sample:      $SAMPLE"
        echo "-----------------------------------------------"
    done
fi

echo "📋 Non-String Columns (Already Efficient):"
ch_query "SELECT name, type FROM system.columns WHERE database='$DB_NAME' AND table='$TBL_NAME' AND type NOT LIKE 'String%' AND type NOT LIKE 'LowCardinality%' FORMAT TabSeparated"

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
