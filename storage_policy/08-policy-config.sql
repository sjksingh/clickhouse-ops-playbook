SELECT 
    '8. POLICY CONFIG' as section,
    policy_name,
    volume_name,
    volume_priority,
    disks,
    formatReadableSize(max_data_part_size) as max_part_size,
    move_factor
FROM system.storage_policies
ORDER BY policy_name, volume_priority;
