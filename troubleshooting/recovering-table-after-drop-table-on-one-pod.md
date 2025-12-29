```sql
select create_table_query||';' from system.tables WHERE database NOT IN ('system','INFORMATION_SCHEMA','information_schema') SETTINGS show_table_uuid_in_table_create_query_if_not_nil=1 format TSVRaw;
```



```sql
SELECT 
     'DETACH TABLE `'||database||'`.`'||table||'`; ' || 
     'SYSTEM DROP REPLICA \''||replica_name||'\' FROM ZKPATH \''||zookeeper_path||'\'; ' || 
     'ATTACH TABLE `'||database||'`.`'||table||'`; ' ||
     'SYSTEM RESTORE REPLICA `'||database||'`.`'||table||'`; '
FROM 
    system.replicas
WHERE 
    database = 'ssc_dbre'
    AND 
    table = 't111'
    -- AND is_readonly
FORMAT TSVRaw;
```
### - Helpful trouble-shooting detach parts.....
```sql
select database, table, reason, count() from system.detached_parts group by database, table, reason;
```
```sql
SELECT
       concat('alter table ',database,'.',table,' drop detached part ''',a.name,''' settings allow_drop_detached=1;') as drop
FROM system.detached_parts a
ALL LEFT JOIN
(SELECT database, table, partition_id, name, active, min_block_number, max_block_number
   FROM system.parts WHERE active
) b
USING (database, table, partition_id)
WHERE a.min_block_number >= b.min_block_number
  AND a.max_block_number <= b.max_block_number
ORDER BY table, min_block_number, max_block_number
FORMAT TSVRaw;
```

```sql
SELECT 'ALTER TABLE `'||database||'`.`'||table||'` ATTACH PART \''||name||'\';'
FROM system.detached_parts WHERE reason = '';
```
