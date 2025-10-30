-- Calculates cardinality % for all columns (replace table name)
SELECT
    uniq(observation_category) AS uniq_observation_category,
    uniq(observation_type) AS uniq_observation_type,
    uniq(observation_group_identifier) AS uniq_observation_group_identifier,
    uniq(observation_owner_domain) AS uniq_observation_owner_domain,
    uniq(observation_group_key) AS uniq_observation_group_key,
    uniq(asset_key) AS uniq_asset_key,
    uniq(first_seen) AS uniq_first_seen,
    uniq(last_seen) AS uniq_last_seen,
    uniq(asset_type) AS uniq_asset_type,
    uniq(asset_name) AS uniq_asset_name,
    uniq(ip_and_port) AS uniq_ip_and_port,
    uniq(url) AS uniq_url,
    uniq(dns) AS uniq_dns,
    uniq(impact) AS uniq_impact,
    uniq(severity) AS uniq_severity,
    uniq(created_at) AS uniq_created_at,
    uniq(v1_issue_key) AS uniq_v1_issue_key,
    count() AS total_rows
FROM database.table_name;
