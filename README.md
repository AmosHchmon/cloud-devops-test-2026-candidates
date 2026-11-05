# GCP Cloud DevOps Engineer exercise

A practical assignment: improve a small existing GCP service and explain how to operate it.

- [Candidate assignment](assignment/ASSIGNMENT.md) — scenario, five problems and submission requirements.

Seven calendar days, with a suggested effort of 6–8 hours. No GCP account, deployment or paid resources required. All systems, incidents and targets are fictional.

## Candidate solution

**Start here: [docs/solution.md](docs/solution.md)** - one section per problem (cause/risk, exact fix, safe implementation, verification).

| Problem | Where |
| --- | --- |
| Architecture diagram (corrected system, traffic/data paths, Azure DevOps agent connection) | [diagrams/architecture.mmd](diagrams/architecture.mmd) (Mermaid) |
| 1. Service interruptions (releases, node maintenance, zone outage) | [solution.md section 1](docs/solution.md#1-service-interruptions) and [k8s/](k8s/) |
| 2. Backup and recovery (PITR, versioning, soft delete, RPO/RTO) | [solution.md section 2](docs/solution.md#2-backup-and-recovery) and [scripts/restore-drill.sh](scripts/restore-drill.sh) |
| 3. Linux pipeline agent failure (disk full) | [solution.md section 3](docs/solution.md#3-linux-pipeline-agent-failure) and [scripts/](scripts/) |
| 4. Failed release (immutable tags, digest, approval, rollback, Expand/Contract) | [solution.md section 4](docs/solution.md#4-failed-release) and [pipelines/azure-pipelines.yaml](pipelines/azure-pipelines.yaml) |
| 5. Git controls (branch policies, PR flow, hotfix) | [solution.md section 5](docs/solution.md#5-git-controls) |

Git and CI/CD remain in Azure DevOps Server. GitHub is used only for this submission. Jenkins is not used.

## Assumptions

- **No real GCP environment.** No GCP account, cluster, database or Azure DevOps organisation was available, so no cloud command was run. Cloud and pipeline commands are **pseudocode / proposals** and flag names must be verified with `--help`.
- **Region and platform:** `me-west1` offers three zones; GKE Standard; Cloud SQL for PostgreSQL; the edition and its limits (for example PITR log retention) match the assumptions in the document.
- **Application:** FastAPI API on port 8000 with `/healthz` (liveness, independent of the database) and `/readyz` (readiness, checks the database); the app handles `SIGTERM` gracefully (for example `uvicorn --timeout-graceful-shutdown`); namespace `survey`, Deployment `survey-api`, container `api`.
- **Migrations:** **Alembic** is assumed as the migration tool (`alembic upgrade head`), run as a one-off Kubernetes Job; migrations are written to be backward compatible (Expand/Contract).
- **Database names (recovery):** tables `surveys` and `uploads` (column `object_name`, primary key `id`) reference uploaded files.
- **Bucket:** a single regional bucket (placeholder `survey-uploads` / `SURVEY_UPLOADS`) in `me-west1`; object names in the database equal the object names in the bucket.
- **Build agent:** Ubuntu VM; agent installed at `/opt/ado-agent` and running as `vsts.agent.*` systemd services; the Azure DevOps agent process is `Agent.Worker`; the disk figures come from the simplified output in the assignment.
- **Azure DevOps:** Server 2022 supports multi-stage YAML, Environments with approvals and checks, and Azure Repos branch policies. Pool `gcp-build-agents`, Environment `production` and variable group `survey-nonsecret` are placeholders.
- **Times:** failover, clone and recovery durations are estimates that must be measured in a drill. Israel time is UTC+2 in winter and UTC+3 in summer.
- **Scope:** the VPN, HTTPS load balancer and workload identity already work and are not redesigned. A regional (whole-region) disaster is out of scope.
- **Data:** all data and names are synthetic or placeholders; no secrets are stored in this repository.

## Time spent

Approximately **6-8 hours** (candidate's estimate), covering planning, writing the Kubernetes manifests, scripts, the pipeline excerpt and the documentation.

## AI disclosure

> **Substantial AI assistance was used for this submission.** I used **Google Antigravity** (an AI coding agent) with the **GitHub MCP server** (plus local `git`). I reviewed the content and can explain the solution.

What the AI agent was used for:

- **GitHub operations via MCP:** forking the source repository into my account (public fork), creating branches, opening and merging pull requests (PR #1 to #7), and reading the assignment text from the source repository.
- **Drafting the architecture** proposal and the corrected-system diagram (Mermaid).
- **Writing the YAML:** Kubernetes manifests (`k8s/`) and the Azure DevOps pipeline excerpt (`pipelines/`).
- **Writing the Bash and systemd scripts** (`scripts/`) and the solution document (`docs/solution.md`).

Outside material: only the assignment text and general public documentation (GCP, Kubernetes, Azure DevOps) were used as reference. No secrets or real data were given to the AI agent or stored in the repository.

## Execution status

| Item | Status |
| --- | --- |
| `k8s/*.yaml` and `pipelines/azure-pipelines.yaml` | **Tested locally:** YAML **syntax only** (parsed with PyYAML). **Not** validated against the Kubernetes or Azure DevOps schemas, and not applied or run. |
| Kubernetes manifests (Deployment, HPA, PDB, Service) | **Proposed only** (not applied to a cluster; `kubeconform` / `kubectl` were not available) |
| Regional GKE cluster, Cloud SQL HA, PITR, bucket versioning and soft delete | **Proposed only** (design and pseudocode) |
| Recovery procedure and `scripts/restore-drill.sh` | **Proposed only** (not run; the script prints commands unless `EXECUTE=1`; shell syntax not checked) |
| `scripts/agent-disk-*.sh` and `scripts/systemd/*` | **Proposed only** (not run on a real agent; not tested) |
| Azure DevOps pipeline, branch policies, environment approvals | **Proposed only** (not run or configured in Azure DevOps) |
| Architecture diagram (Mermaid) | Written, **not** rendered or reviewed in a Mermaid tool |
| Failover/restore times, RPO/RTO claims | **Estimates**; a restore drill is described to prove them |
