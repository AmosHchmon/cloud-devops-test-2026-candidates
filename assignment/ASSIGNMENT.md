# GCP Cloud DevOps Engineer — practical assignment

## Goal and time

Improve the reliability and delivery of a small existing service. Propose concrete fixes that a small DevOps team could implement.

You have seven calendar days. Aim for 6–8 hours and report your time spent. No cloud account, paid resources or deployment is required.

## Existing system

A survey service accepts files, validates them and produces reports.

| Component | Current setup |
| --- | --- |
| GCP | One production project, one VPC, region `me-west1` |
| Application | Web frontend, Python/FastAPI API and background worker on GKE Standard |
| GKE | Private cluster; two worker nodes in one zone; one replica of each application |
| User access | HTTPS load balancer routes requests to the web frontend and API |
| PostgreSQL | Cloud SQL, private IP, single-zone instance |
| Files | Private Cloud Storage bucket; database records refer to uploaded objects |
| Images | Artifact Registry |
| Git and CI/CD | Azure DevOps Server 2022 on premises |
| Pipeline agent | Self-hosted Ubuntu VM in GCP; Docker builds and deployments run here |
| Connectivity | Existing site-to-site VPN; agent can reach Azure DevOps and the private GKE API |
| Identity | Agent uses an attached service account; application uses workload identity. No service-account key files |
| Secrets | Secret Manager; access is already configured |

The VPN, HTTPS entry point and identity setup work. You do not need to redesign them. There is no development environment to design in this assignment.

The current pipeline checks out Git, builds images tagged `latest`, pushes them, runs a database migration and deploys to GKE. There are no pull-request checks or production approval.

## Problems to fix

### 1. Service interruptions

Users receive errors during releases and node maintenance. The API has one replica, no readiness or startup probe, no resource requests/limits and no graceful shutdown configuration. Both GKE nodes are in the same zone.

Propose specific Kubernetes changes for safer releases and maintenance. Include a short API Deployment YAML example or patch. Explain the purpose of each important setting and how you would test it.

Also explain what happens during a zone outage and the minimum infrastructure changes needed to keep the service available. Include the database in your answer. Separate this from the deployment fix.

### 2. Backup and recovery

Cloud SQL has a daily automated backup with seven-day retention. Point-in-time recovery is disabled. Object versioning and soft delete are disabled for the file bucket. Nobody has tested recovery.

At 10:20, an operator accidentally deletes survey records and several uploaded objects. The mistake is discovered at 10:35.

The task targets are a maximum of 15 minutes of lost database changes (RPO) and service recovery within two hours (RTO). Deleted files should be recoverable for seven days.

Propose the changes needed before such an incident, then describe recovery in numbered steps. Cover the restore destination, database/file consistency, application reconnection and checks before reopening the service. Explain the limits of the current setup and how you would prove the improved recovery meets the targets.

### 3. Linux pipeline agent failure

Builds stop with `No space left on device`. The agent VM has this simplified diagnostic output:

```text
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1        100G   99G     0 100% /

$ sudo du -xhd1 /var/lib
76G /var/lib/docker
4G  /var/lib/other

$ sudo du -xhd1 /opt/ado-agent
12G /opt/ado-agent/_work
```

List the commands you would use to investigate further, a safe immediate recovery procedure and a simple prevention plan. Explain what you would check before deleting anything. This VM is a build agent, not an application host.

### 4. Failed release

A release introduces API errors after its database migration succeeds. All images use `latest`; the previous deployed image digest was not recorded.

Propose a simple Azure DevOps pipeline flow for build, validation, production approval and deployment. Include a short YAML excerpt for immutable image tagging and recording the deployed version. Pseudocode is acceptable for environment-specific commands; label it clearly.

Explain how to recover from a failed application release and what changes when its migration is incompatible with the previous application. Do not assume redeploying an old image restores the database.

Keep Azure DevOps Server as Git and CI/CD. Use GitHub only for this submission. Do not use Jenkins.

### 5. Git controls

Developers push directly to `main`, and any push may deploy to production.

Describe a lightweight workflow for a small team: branches, pull requests, required checks, review and production release authorization. Name the Azure DevOps branch policies or pipeline controls you would use. Explain how an urgent fix would follow the same controls.

## What to submit

Submit a GitHub repository or branch with:

- A README linking to your solution.
- A concise solution, approximately 3–5 pages plus snippets. For each problem: cause/risk, exact fix, safe implementation and verification.
- One architecture diagram showing the corrected system, traffic/data paths and Azure DevOps agent connections.
- Optionally, one release/recovery diagram if it makes your explanation clearer.
- The Kubernetes example and Azure DevOps excerpt, either in the solution or as separate files.

Editable draw.io or Mermaid diagrams are sufficient. No Terraform, working application or full pipeline is required.

State assumptions and tradeoffs. Mark what you tested locally and what you only proposed. Use synthetic data and no secrets. Disclose substantial use of AI or outside material; you must be able to explain your solution.

## Evaluation

| Area | Weight |
| --- | ---: |
| Kubernetes availability and release behaviour | 25% |
| PostgreSQL/file recovery and verification | 25% |
| Linux diagnosis and safe remediation | 20% |
| Azure DevOps delivery, rollback and Git controls | 20% |
| Clarity, diagrams and practical scope | 10% |

We value specific, workable fixes and clear verification. More services, longer documents and cloud spending do not earn extra points.
