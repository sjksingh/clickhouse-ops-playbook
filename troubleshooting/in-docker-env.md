# Runbook: ClickHouse Table Read-Only Recovery (P0)


### Why do tables go Read-Only?
Before fixing it, an SRE needs to know the "Why." In your EKS environment, the common culprits are:

1. ZooKeeper Quorum Loss: If 2 out of your 3 ZK nodes go down, the ClickHouse pods lose their session. All replicated tables immediately become ReadOnly.

2. Session Expiration/Network Partition: High CPU on the ZK nodes or network jitter in the EKS cluster causing a session timeout.

3. Metadata Mismatch (The "Divergence"): If you manually delete a path in ZK, the ClickHouse node detects that its expected log pointer or replica path is missing.

4. Disk I/O Errors: If the underlying EBS volume (or local NVMe) has hardware issues, ClickHouse might remount the filesystem as RO, forcing the table to follow suit.



## 1. Metadata & Overview
| Attribute | Description |
| :--- | :--- |
| **Service** | ClickHouse |
| **Environment** | EKS |
| **Critical Table** | `ssc_dbre.uk_price_paid` |
| **Severity** | P0 - Data Ingestion Blocked |
| **Symptom** | `is_readonly: 1` or `UNEXPECTED_ZOOKEEPER_ERROR` |

---

## 2. Scenario Simulation (DBRE Testing Only)
To simulate a metadata corruption/loss event, delete the replica registration from ZooKeeper.

**Target Path:** `/clickhouse/tables/<uuid>/<shard>/replicas/<replica_name>`
```sql
SELECT
    database,
    `table`,
    engine,
    replica_name,
    zookeeper_path,
    replica_path,
    is_leader,
    is_readonly,
    lost_part_count,
    active_replicas,
    total_replicas
FROM clusterAllReplicas('{cluster}', system, replicas)
WHERE (database = 'ssc_dbre') AND (`table` = 'uk_price_paid')
ORDER BY replica_name ASC
FORMAT Vertical
```


```bash
# 1. Log into a ZooKeeper/Keeper pod
kubectl exec -it zookeeper-0 -- bash

# 2. Connect to ZK CLI
./zkCli.sh -server localhost:2181

# 3. Delete the replica metadata recursively
# Replace the UUID with your table's specific UUID
deleteall /clickhouse/tables/f73fb9e3-1439-4ef5-a763-73838d14f208/01/replicas/clickhouse02

```


###3  - Target POD02 
```sql
-- 1. Detach to clear the memory cache
DETACH TABLE ssc_dbre.uk_price_paid;

-- 2. Re-attach to force a fresh ZooKeeper handshake
ATTACH TABLE ssc_dbre.uk_price_paid;

-- 3. Confirm the table is officially Read-Only
SELECT is_readonly FROM system.replicas WHERE table = 'uk_price_paid';
-- Logic: If result is 1, proceed to Phase B.
```

###4 Reconstruct Metadata (Run on BROKEN Pod)
Use the local disk data and the healthy replica to rebuild the missing ZooKeeper nodes.

```sql
-- Reconstructs ZK paths, log pointers, and part metadata
SYSTEM RESTORE REPLICA ssc_dbre.uk_price_paid;
```

### JUST FYI... 
Phase C: Quorum Reform (Run on HEALTHY Pod)
Often, the healthy pod will not automatically detect the newly restored peer. We must force it to refresh its watches.

Target Pod: e.g., clickhouse01

```sql
-- Force the healthy node to re-scan ZooKeeper for peers
SYSTEM RESTART REPLICA ssc_dbre.uk_price_paid;
```

###5. Final Validation
Both pods must show identical counts and full quorum status.

Verify Consensus:
```sql
SELECT replica_name, is_readonly, active_replicas, total_replicas 
FROM clusterAllReplicas('{cluster}', system, replicas)
WHERE table = 'uk_price_paid';
```

Success Criteria: Both rows show is_readonly: 0, active_replicas: 2, total_replicas: 2.

Verify Data Parity:   

```sql
SELECT hostName(), count() 
FROM clusterAllReplicas('{cluster}', ssc_dbre.uk_price_paid) 
GROUP BY hostName();
```


SRE Safety Guardrails
1. NEVER run SYSTEM RESTORE REPLICA on all replicas at once. This destroys the cluster's ability to determine the "Source of Truth."

2. Disk Space: Ensure the broken pod has > 20% disk headroom. Re-initializing metadata may trigger a flurry of background merges.

3. Force Drop: If DETACH fails, you may need to use SET force_drop_table_confirm = 1; followed by a DROP and a fresh CREATE, though RESTORE REPLICA is always the preferred non-destructive path.

