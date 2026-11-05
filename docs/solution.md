# Solution - GCP Cloud DevOps assignment

> Status: in progress. Sections 1 and 2 are written (stages 2-4). Other sections are filled in by later stages.
> Each problem follows: cause/risk, exact fix, safe implementation, verification.

## Assumptions, tradeoffs and testing status

- No GCP account is used. **Everything below is "Proposed only"** unless explicitly marked **Tested locally**.
- Region `me-west1` is assumed to offer three zones (`a`, `b`, `c`). Verify with `gcloud compute zones list --filter="region:me-west1"`.
- Figures for failover time are typical, not guaranteed. They must be measured (see verification).
- Tradeoff: three zones cost more than two (extra nodes, standby database). The extra cost buys zone-failure tolerance, which the current design lacks.
- _More assumptions are added by later stages._

## Architecture

See [diagrams/architecture.mmd](../diagrams/architecture.mmd).

## 1. Service interruptions

This problem has two separate parts: **1A** releases and node maintenance (Kubernetes configuration) and **1B** zone outage (infrastructure).

### 1A. Releases and node maintenance

Manifests: [k8s/](../k8s/) (`api-deployment.yaml`, `api-hpa.yaml`, `api-pdb.yaml`). Cause/risk, exact settings and testing for 1A are summarised in [k8s/README.md](../k8s/README.md) and will be expanded in the final document.

### 1B. Zone outage: cause, risk and fix

#### Cause / risk (current state)

| Component | Current setup | What happens if its zone fails |
| --- | --- | --- |
| GKE nodes | Two nodes in **one zone** | Every pod (web, API, worker) is lost together. No capacity remains to reschedule onto. |
| GKE control plane | Zonal cluster = **single control-plane replica** | No API server: no scheduling, scaling, or deployments, and the pipeline cannot reach the private GKE API. |
| Cloud SQL | **Single-zone** instance | The database is unavailable. Recovery means restoring a backup into another zone, which is slow and loses data since the last backup because point-in-time recovery is off. |
| Application | One replica of each component | A single point of failure even without a zone outage. |

Result: a zone outage is a **full outage** with a manual, hours-long recovery. If the zone is the one hosting both nodes and the database, the two failure domains are the same, so nothing masks it.

#### Fix 1: regional GKE cluster (instead of zonal)

A **regional** GKE Standard cluster has these properties:

- The **control plane is replicated across three zones**, so the Kubernetes API stays available and writable if one zone fails. Scaling, rescheduling and deployments keep working.
- Node pools are created **in each chosen zone**. With `--num-nodes=1` and three zones you get three nodes (one per zone). The setting is per zone.
- Pods can be spread across zones with the `topologySpreadConstraints` already defined in [api-deployment.yaml](../k8s/api-deployment.yaml) (`topology.kubernetes.io/zone`, `maxSkew: 1`).

A zonal cluster **cannot be converted in place** to a regional one. The change means **creating a new regional cluster and migrating workloads**.

Capacity rule (N+1 by zone): size each zone so the remaining two zones can carry the full peak load. For example, with peak load needing 2 nodes' worth of capacity, run at least 1 node per zone with the cluster autoscaler allowed to grow each zone (`--min-nodes 1 --max-nodes 3` per zone), so that the surviving zones can scale up when one zone is lost.

Pseudocode (**proposed, not run**; adjust names, network, and ranges):

```bash
gcloud container clusters create survey-regional \
  --region me-west1 \
  --node-locations me-west1-a,me-west1-b,me-west1-c \
  --num-nodes 1 \
  --enable-autoscaling --min-nodes 1 --max-nodes 3 \
  --enable-private-nodes \
  --enable-ip-alias \
  --workload-pool=PROJECT_ID.svc.id.goog \
  --network EXISTING_VPC --subnetwork EXISTING_SUBNET
```

Notes:

- The existing VPC, VPN, HTTPS load balancer and workload identity model stay as they are (the assignment says not to redesign them). The new cluster reuses the VPC. The private control-plane endpoint must remain reachable from the pipeline agent over the VPN, so its authorized networks must include the agent subnet.
- Replica counts: web >= 2, API >= 3 (HPA minimum 3), worker >= 2. With the topology spread, losing one zone leaves at least 2 of 3 API pods running immediately.
- Optional: lower `tolerations` `tolerationSeconds` for `node.kubernetes.io/unreachable` and `not-ready` (default 300 s) to about 60 s so replacement pods are created sooner. Traffic already stops going to the lost pods as soon as their readiness fails, so this only affects how quickly capacity is restored.

#### Fix 2: Cloud SQL in High Availability (HA) configuration

Cloud SQL HA (`availability-type=REGIONAL`) provides:

- A **primary** in one zone and a **standby** in a different zone of the same region.
- **Synchronous** replication of data to both zones (regional persistent disk), so a committed transaction is not lost on failover.
- **Automatic failover** to the standby if the primary or its zone fails. The instance keeps the **same private IP and connection name**, so connection strings do not change.
- Existing connections drop during failover (typically around one to two minutes, to be measured), so the application must reconnect.

Pseudocode (**proposed, not run**):

```bash
# Enable HA on the existing instance (may restart the instance: schedule in a maintenance window).
gcloud sql instances patch SURVEY_DB \
  --availability-type=REGIONAL

# Optional but recommended with HA: keep maintenance predictable.
gcloud sql instances patch SURVEY_DB \
  --maintenance-window-day=SUN --maintenance-window-hour=02
```

Application requirements (otherwise HA does not translate into availability):

- Connection pool with health checks and retry (for example SQLAlchemy `pool_pre_ping=True`, short `pool_recycle`, and bounded retries with backoff on connection errors).
- Request timeouts so requests fail fast instead of hanging during the failover.
- Worker jobs must be idempotent or retried, because a job can fail mid-failover.
- `/readyz` (see [api-deployment.yaml](../k8s/api-deployment.yaml)) may report not-ready during failover. Keep `/healthz` (liveness) independent of the database so the pods are not restarted needlessly.

Important limits:

- **HA is not a backup.** A deletion or corrupt write is replicated to the standby immediately. Backups, point-in-time recovery and file recovery are handled in section 2 (a later stage).
- HA protects against **zone** failure, not **region** failure. A regional outage, or another region's recovery, would need a cross-region replica and is out of scope for this assignment.

#### Other components in a zone outage

| Component | Behaviour |
| --- | --- |
| Cloud Storage (regional bucket in `me-west1`) | Data is stored redundantly across zones in the region, so a single-zone failure does not affect it. |
| Artifact Registry (regional repository) | Regional service, not tied to one zone. |
| HTTPS load balancer | Global/regional managed service. With container-native load balancing (NEGs, see the Service annotation) unhealthy endpoints are removed automatically. |
| **Pipeline agent VM** | A single VM in one zone. If its zone fails, builds and deployments stop, but **the running service is not affected**. Mitigation: keep a recreate-from-image procedure (or a managed instance group of size 1 spanning zones) so the agent can be restored in another zone. This is an accepted tradeoff for a small team. |

#### Behaviour during a zone outage after the fixes

1. Pods and the database primary in the failed zone become unavailable.
2. The load balancer stops sending traffic to the failed endpoints once their health/readiness checks fail.
3. The remaining zones keep serving: at least 2 of 3 API pods, and the web and worker replicas from the other zones.
4. Cloud SQL fails over to the standby in another zone. Requests that need the database may fail for the failover period (typically 1-2 minutes) and then recover automatically after reconnect.
5. The regional control plane stays available, so the HPA and the cluster autoscaler add pods and nodes in the surviving zones.
6. When the zone returns, pods rebalance on the next rollouts and Cloud SQL creates a new standby.

Expected result: **degraded capacity and a short database blip**, instead of a complete outage.

#### Safe implementation

1. Create the regional cluster **next to** the existing one (blue/green at cluster level), deploy the manifests, and test with synthetic data.
2. Enable Cloud SQL HA in a maintenance window, because it can restart the instance. Take an on-demand backup first.
3. Switch traffic at the load balancer (add the new cluster's backend, shift gradually, keep the old cluster until stable).
4. Decommission the old zonal cluster after a stable period.

#### Verification (proposed tests, not yet run)

| Test | How | Pass criteria |
| --- | --- | --- |
| Zone loss, compute | Under steady load (for example `hey` or `k6`), cordon and drain all nodes in one zone: `kubectl cordon` then `kubectl drain` for nodes with `topology.kubernetes.io/zone=me-west1-a` | API error rate stays low; at least 2 API pods stay Ready; replacement pods are scheduled in the other zones |
| Database failover | `gcloud sql instances failover SURVEY_DB` under load | Failover time recorded; application recovers without manual action; no committed data lost; the connection string is unchanged |
| Control plane | Confirm `kubectl get nodes` and deployments still work while a zone is drained | API server stays available |
| Spread check | `kubectl get pods -o wide -l app=survey-api` | Pods are distributed over three zones |

## 2. Backup and recovery

> **Status: design only.** Nothing in this section was run against a cloud environment. The commands are proposals and the draft script [scripts/restore-drill.sh](../scripts/restore-drill.sh) only prints commands by default. Timings are estimates that must be measured in a drill (see "Proving the targets").

Targets: **RPO 15 minutes** (maximum lost database changes), **RTO 2 hours** (service recovered), **deleted files recoverable for 7 days**.

### Cause / risk (current state)

| Area | Current setup | Consequence |
| --- | --- | --- |
| Cloud SQL | Daily automated backup, 7-day retention, **PITR disabled** | The only restore point is the last daily backup. Data loss can be up to about 24 hours, so the 15-minute RPO is **not met**. |
| Cloud Storage | Object versioning and soft delete **disabled** | Deleted or overwritten files are **permanently lost**. |
| Process | Recovery never tested | Unknown real RTO; steps, permissions and consistency checks are unproven. |
| Restore method | Restoring a backup onto the production instance overwrites it | Legitimate changes made after the backup are lost, and a failed restore can make things worse. |

### Backup configuration (before an incident)

**Cloud SQL for PostgreSQL: enable point-in-time recovery (PITR).** PITR continuously archives the write-ahead log (WAL) in addition to daily backups and allows restoring to any second inside the retention window.

```bash
# Proposed, not run
gcloud sql instances patch SURVEY_DB \
  --backup-start-time=01:00 \
  --enable-point-in-time-recovery \
  --retained-transaction-log-days=7 \
  --retained-backups-count=7 \
  --deletion-protection
```

Notes:

- PITR needs automated backups to be enabled (they already are). It only helps for the period **after** it is enabled.
- Log retention of 7 days matches the file-recovery period. The limit depends on the Cloud SQL edition, so confirm it for the edition in use.
- Deletion protection prevents someone deleting the instance (which would also delete its backups).
- Monitor that PITR is healthy: alert if `gcloud sql instances get-latest-recovery-time SURVEY_DB` is more than about 10 minutes behind the current time. This keeps the 15-minute RPO honest.
- Optional: enable database audit logging (for example the `pgaudit` extension) and Cloud Storage **Data Access audit logs** (`DATA_WRITE`) so the incident time, the user and the deleted rows/objects can be identified quickly.

**Cloud Storage: object versioning and soft delete.**

```bash
# Proposed, not run
gcloud storage buckets update gs://SURVEY_UPLOADS \
  --versioning \
  --soft-delete-duration=7d

# Control cost: remove non-current versions after 14 days
cat > lifecycle.json <<'JSON'
{"rule":[{"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":14,"isLive":false}}]}
JSON
gcloud storage buckets update gs://SURVEY_UPLOADS --lifecycle-file=lifecycle.json
```

| Feature | What it protects | Retention | Cost note |
| --- | --- | --- | --- |
| Soft delete (7 days) | Deleted objects (and overwritten ones) can be restored for 7 days | 7 days, matches the requirement | Soft-deleted data is billed during retention |
| Object versioning | Keeps older versions when an object is overwritten or deleted, so a specific version can be restored | Until the lifecycle rule removes non-current versions | Grows with every overwrite; limit with lifecycle rules |

Soft delete alone satisfies "recoverable for 7 days". Versioning is added because it also protects against **overwrites**, with a lifecycle rule to cap cost. Both are low risk to enable and are not applied retroactively (objects deleted before they are enabled stay lost).

### Recovery procedure: deletion at 10:20, discovered at 10:35

Principle: **never restore over production.** Restore to a **new** instance at the point just before the mistake (10:19), then copy back **only what was deleted**. This recovers the deleted data **and keeps all legitimate changes made after 10:19**.

Why not just roll the whole database back to 10:19? Restoring everything to 10:19 and switching to it loses every legitimate change made between 10:19 and the cutover (at least 16 minutes, more in practice). That is more than the 15-minute RPO. The selective restore loses none of them.

Assumptions: the DB tables referencing files are named `surveys` and `uploads` (with an `object_name` column), the operator's deletes did not touch other users' data, and times are Israel local time (convert to UTC for commands; 10:19 local is 08:19 UTC in winter, 07:19 UTC in summer).

| Step | Time (est.) | Action |
| --- | --- | --- |
| 1. Contain | 10:35-10:45 | Declare the incident and name an incident lead. Stop further damage: scale the worker to 0 and put the API in maintenance/read-only mode (or block the operator's access). Record exact times and the user from audit logs. |
| 2. Safety snapshot | 10:45-10:55 | Take an on-demand Cloud SQL backup of the current state, and note the bucket state (the soft-delete retention is already protecting the files). Never skip this: it makes every later step reversible. |
| 3. Restore DB to 10:19 | 10:55-11:40 | Clone the production instance with `--point-in-time` set to 10:19 as a **new** instance (same VPC/private IP configuration, different IP). Confirm the clone's state is `RUNNABLE` and that the deleted rows exist in it. |
| 4. Re-insert deleted rows | 11:40-12:00 | Export the affected tables from the clone, load them into a scratch schema on production, and `INSERT ... WHERE NOT EXISTS` only the missing rows, parents before children (foreign keys), in one transaction. Compare row counts, then commit. Existing rows are never overwritten. |
| 5. Restore files | 12:00-12:15 | List soft-deleted objects in the bucket for the 10:20-10:35 window, and restore those objects (`gcloud storage restore` with `--deleted-after-time` / `--deleted-before-time`, without overwriting live objects). If versioning provides a specific older version, copy that generation back. |
| 6. Consistency checks | 12:15-12:25 | Run the checks below. Fix gaps before reopening. |
| 7. Reconnect and reopen | 12:25-12:35 | The production instance was never replaced, so **no connection-string change** is needed. Scale the worker back up, remove maintenance mode, run smoke tests, then watch errors and latency. |
| 8. Cleanup | After sign-off | Drop the scratch schema, delete the clone, and write a post-incident review. |

Estimated total: about **2 hours** from discovery (10:35 to about 12:35). This is **tight**, and the clone time depends on the database size, so it must be measured. If the clone is slow, the main saving is to start step 3 immediately after step 1 and run step 2 in parallel.

Fallback if the deletion cascaded broadly (many tables) and selective copy is too complex: switch the application to the clone (changing the Cloud SQL connection/secret and restarting), after stopping writes. Accept the loss of changes between 10:19 and the cutover, report it to the business, and document that the RPO was exceeded.

### Consistency between database and files

The database holds records pointing to objects. After recovery, both sides must agree:

1. **Database to bucket:** every `uploads.object_name` must exist in the bucket. List the names from the database, list the bucket, and use `comm -23` to show names present in the database but missing from the bucket. This must be **empty**. Anything missing is restored from soft delete or versions, or the record is flagged.
2. **Bucket to database:** `comm -13` lists objects with no record (orphans). **Review them; do not auto-delete.** They may be uploads whose record was lost, or files uploaded during the incident.
3. **Content integrity:** if the database stores a checksum or size, compare it with the object metadata (`gcloud storage objects describe`). If it does not, sample and open a few files.
4. **Referential integrity:** run foreign-key and orphan-row queries on the restored tables (for example, uploads without a survey).
5. **Application checks:** open a sample of restored surveys, download their files, and generate one report end to end through the worker.
6. **Counts:** restored row/object counts equal the numbers deleted (from audit logs and soft-delete listing).

Sign-off from the owner is required before removing maintenance mode.

### Proving the targets (verification)

Run a **restore drill** in a non-production project using synthetic data of production-like size, at least once now and then regularly (for example every quarter).

1. Seed the database and bucket. Record a timestamp `T0`.
2. At `T0 + 1 min` delete some rows and objects (simulating the operator), and let other synthetic users keep writing.
3. Start a stopwatch at "discovery" and follow the procedure (or [scripts/restore-drill.sh](../scripts/restore-drill.sh) with `EXECUTE=1`).
4. Record each step's duration. **RTO is met** if service is reopened within 2 hours (target with margin: under 90 minutes in the drill).
5. **RPO is met** if the rows written by other users after the mistake are still present (zero loss with the selective restore), and the PITR clone reflects the restore point within 15 minutes (check `get-latest-recovery-time`).
6. Run all consistency checks above. Save the results and the timings as drill evidence.
7. Confirm alerts fire when PITR falls behind, and that a restored object is downloadable.

### Limits and tradeoffs

- PITR cannot recover from before it was enabled or beyond the retention window; the first deletion before that is not recoverable.
- Cloud SQL HA (section 1B) does **not** replace backups: a delete replicates to the standby immediately.
- A PITR clone is a new instance with a new IP, so a full cutover to it requires configuration changes (and downtime), which is why selective restore is preferred.
- Soft delete and versioning increase storage cost, and only protect for the configured period. Longer legal retention needs a different policy.
- A regional disaster (the whole region) is out of scope. It would need cross-region backups or replicas.
- This procedure assumes the table and column names above and that the database engine, edition and limits match the assumptions; confirm against the real schema.

## 3. Linux pipeline agent failure
_TBD_ (helper commands: [scripts/](../scripts/))

## 4. Failed release
_TBD_ (excerpts: [pipelines/](../pipelines/))

## 5. Git controls
_TBD_

## Time spent and AI disclosure
_TBD_ - substantial AI assistance is disclosed here (see also the README).
