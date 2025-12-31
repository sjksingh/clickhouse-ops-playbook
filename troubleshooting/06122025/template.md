#!/bin/bash
# ClickHouse Detached Parts Recovery Script

CLICKHOUSE_HOST="localhost"
CLICKHOUSE_PORT="8123"
DATABASE="issues"
TABLE="scorecard_issue_active"

echo "Starting recovery for $DATABASE.$TABLE"

# Step 1: Verify detached parts exist
DETACHED_PARTS_COUNT=$(clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT -q "
SELECT count()
FROM system.detached_parts 
WHERE database='$DATABASE'
  AND table='$TABLE'
  AND reason=''")

echo "Found $DETACHED_PARTS_COUNT detached parts with empty reason"

if [ "$DETACHED_PARTS_COUNT" -eq 0 ]; then
    echo "No parts to recover, exiting"
    exit 0
fi

# Step 2: Generate and execute ATTACH PART commands
echo "Attaching parts with empty reason..."

clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT -q "
SELECT
    'ALTER TABLE $DATABASE.$TABLE ATTACH PART \\'' || name || '\\';'
FROM system.detached_parts
WHERE database='$DATABASE'
  AND table='$TABLE'
  AND reason=''
ORDER BY partition_id, (max_block_number - min_block_number) DESC
FORMAT TSVRaw" | while read -r CMD; do
    echo "Executing: $CMD"
    clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT -q "$CMD"
    # Sleep briefly to prevent overwhelming the server
    sleep 0.5
done

# Step 3: Verify read-only status and fix if needed
READONLY_COUNT=$(clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT -q "
SELECT count()
FROM system.replicas 
WHERE database='$DATABASE'
  AND table='$TABLE'
  AND is_readonly=1")

if [ "$READONLY_COUNT" -gt 0 ]; then
    echo "Found read-only replicas, attempting to fix..."

    REPAIR_COMMANDS=$(clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT -q "
    SELECT 
        'DETACH TABLE `'
        || database || '`.`' || table || '`; '
        || 'SYSTEM DROP REPLICA \\'' || replica_name || '\\' FROM ZKPATH \\'' || zookeeper_path || '\\'; '
        || 'ATTACH TABLE `'
        || database || '`.`' || table || '`; '
        || 'SYSTEM RESTORE REPLICA `'
        || database || '`.`' || table || '`;'
    FROM system.replicas
    WHERE database='$DATABASE'
      AND table='$TABLE'
      AND is_readonly=1
    FORMAT TSVRaw")

    echo "$REPAIR_COMMANDS" | while read -r CMD; do
        echo "Executing: $CMD"
        clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT -q "$CMD"
    done
else
    echo "No read-only replicas found"
fi

# Step 4: Final verification
ROW_COUNT=$(clickhouse-client --host=$CLICKHOUSE_HOST --port=$CLICKHOUSE_PORT -q "
SELECT total_rows
FROM system.tables 
WHERE database='$DATABASE'
  AND table='$TABLE'")

echo "Recovery complete. Current row count: $ROW_COUNT"
