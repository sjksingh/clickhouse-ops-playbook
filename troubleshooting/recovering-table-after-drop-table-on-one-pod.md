```sql
select create_table_query||';' from system.tables WHERE database NOT IN ('system','INFORMATION_SCHEMA','information_schema') SETTINGS show_table_uuid_in_table_create_query_if_not_nil=1 format TSVRaw;
```

```sql
SELECT 'SYSTEM DROP REPLICA \'chi-observations-observations-0-1\' FROM ZK_PATH \''||zookeeper_path||'\';' FROM system.replicas FORMAT TSVRaw;
```

