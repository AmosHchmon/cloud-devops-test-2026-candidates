# Solution - GCP Cloud DevOps assignment

> Status: in progress. Section 1 is written (stages 2-3). Other sections are filled in by later stages.
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
_TBD_

## 3. Linux pipeline agent failure
_TBD_ (helper commands: [scripts/](../scripts/))

## 4. Failed release
_TBD_ (excerpts: [pipelines/](../pipelines/))

## 5. Git controls
_TBD_

## Time spent and AI disclosure
_TBD_ - substantial AI assistance is disclosed here (see also the README).
