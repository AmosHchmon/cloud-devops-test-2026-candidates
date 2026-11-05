# Kubernetes manifests (API)

Proposed only; not applied to a cluster. Static validation status is listed in the solution document.

| File | Purpose |
| --- | --- |
| [api-deployment.yaml](api-deployment.yaml) | Deployment (zero-downtime rolling update, probes, resources, zone spread, graceful shutdown) and Service |
| [api-hpa.yaml](api-hpa.yaml) | HorizontalPodAutoscaler (3-10 replicas, CPU 70%) |
| [api-pdb.yaml](api-pdb.yaml) | PodDisruptionBudget (`maxUnavailable: 1`) |

Test ideas: rolling update under load (no 5xx), `kubectl drain` of one node, kill one pod, delete all pods in one zone (needs a 3-zone cluster).
Worker and frontend should follow the same pattern (the worker needs a shutdown that finishes or requeues the current job).
