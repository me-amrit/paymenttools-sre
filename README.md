# Payment Services — K8s Deployment

This repository deploys the payment-gateway and payment-processor services on a local Kubernetes cluster using k3d. The setup is designed around production concerns: network isolation, pod hardening, autoscaling, health probes, and monitoring. It runs on any machine with Docker.

## Architecture

```
                ┌──────────────────────────────────────┐
                │          k3d cluster                  │
                │                                      │
                │  ┌────────────────────────────────┐  │
                │  │  payment namespace              │  │
                │  │  (pod security: restricted)     │  │
                │  │                                │  │
 POST /pay ────►│  │  gateway ────► processor       │  │
                │  │                                │  │
                │  │  NetworkPolicy: deny-all base  │  │
                │  └────────────────────────────────┘  │
                │                                      │
                │  ┌────────────────────────────────┐  │
                │  │  monitoring namespace           │  │
                │  │  Prometheus ── Grafana          │  │
                │  └────────────────────────────────┘  │
                └──────────────────────────────────────┘
```

The payment-gateway accepts incoming HTTP requests on `POST /pay` and forwards them to the payment-processor over an internal ClusterIP service. Both services expose `/healthz` for health checks and `/metrics` for Prometheus scraping. The gateway discovers the processor through the `PROCESSOR_URL` environment variable, which points to the processor's internal service DNS.


## Prerequisites

Docker, k3d (v5+), and kubectl. All three need to be installed and Docker needs to be running.


## Setup

```bash
./setup.sh          # defaults to dev
./setup.sh qa       # 2 replicas, moderate resources
./setup.sh prod     # 3 replicas, production resources
./teardown.sh       # removes the cluster and stops port forwards
```

The setup script checks prerequisites, creates a k3d cluster with port mappings, deploys the payment services via Kustomize, deploys the monitoring stack, waits for all pods to be healthy, sets up port forwarding, and runs a smoke test. If everything works, it prints the access URLs and the generated Grafana password.

After setup:

| Service | URL |
|---|---|
| Payment Gateway | http://localhost:8080 |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 |

The Grafana admin password is generated at deploy time and printed at the end of setup. It is stored in a Kubernetes Secret and can be retrieved later:

```bash
kubectl get secret grafana-credentials -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

To test the payment flow end to end:

```bash
curl -X POST http://localhost:8080/pay \
  -H "Content-Type: application/json" \
  -d '{"payment_id": "pay-001", "amount": 100, "currency": "EUR", "recipient": "merchant-123"}'
```

Expected response: `{"status":"processed","processor_reference":"proc-default","approved":true}`


## Project layout

```
k8s/
  base/             Deployments, Services, HPA, PDB, NetworkPolicies, ServiceAccounts
  overlays/
    dev/            1 replica, lighter limits
    qa/             2 replicas
    prod/           3 replicas, stricter PDB
monitoring/
  prometheus/       Scrape config, alert rules, namespace-scoped RBAC
  grafana/          Deployment and auto-provisioned datasource
```


## Design decisions

I chose k3d because it runs Kubernetes inside Docker containers with no VM overhead. It starts in about 30 seconds, includes a built-in load balancer for port mapping, and is easy to reproduce on any developer machine. Compared to minikube, there is less setup friction and fewer resource requirements.

For packaging I went with Kustomize over Helm. These are two services with straightforward configuration, and Kustomize is built into kubectl so there is no additional tooling to install. The base/overlay pattern makes it clear what changes between environments without the indirection of Helm templates and values files.


## Security

This is a payment system, so the security model starts from deny-all and opens up only what is needed.

The payment namespace has default deny-all NetworkPolicies for both ingress and egress. Traffic is allowed through a set of explicit policies: the gateway can talk to the processor on port 8080, Prometheus can scrape both services from the monitoring namespace, and kubelet health probes reach the processor through a policy scoped to the cluster CIDR. The gateway is the ingress point so its port 8080 is open to external traffic.

I did not install Cilium or Calico for this local setup to keep the assignment reproducible and time-boxed. The manifests define the intended network policy model, but actual enforcement depends on running the cluster with a policy-capable CNI. In a production cluster I would make this non-optional and validate enforcement with connectivity tests.

The payment namespace enforces the restricted Pod Security Standard. Both services run as non-root (UID 1000) with a read-only root filesystem, all Linux capabilities dropped, privilege escalation disabled, and seccomp profiles enabled. Each service has its own ServiceAccount with `automountServiceAccountToken: false` because neither service interacts with the Kubernetes API.

Prometheus uses namespace-scoped Roles rather than a cluster-wide ClusterRole. It can discover pods in the payment and monitoring namespaces and nothing else.

Grafana credentials are generated by the setup script at deploy time and stored as a Kubernetes Secret. No credentials are committed to the repository.


## Reliability

Each service has three health probes. The startup probe gives the application up to 150 seconds to become ready, which accounts for cold starts and image pull time. The liveness probe detects deadlocks and triggers a restart. The readiness probe controls whether the pod receives traffic from the Service.

A preStop lifecycle hook adds a 5-second delay before SIGTERM is sent. This gives the Kubernetes Service time to remove the pod from its endpoints, so in-flight requests finish before the container shuts down. The termination grace period is set to 30 seconds.

HPA is configured to scale on CPU utilization at 70% and memory at 80%. Scale-down has a 5-minute stabilization window to prevent flapping under bursty traffic. Pod Disruption Budgets guarantee at least 1 pod stays available during voluntary disruptions in dev and QA, and at least 2 in prod. Pod anti-affinity prefers spreading replicas across different nodes so a single node failure does not take out all instances.


## Environment overlays

The Kustomize overlays adjust replicas, resource limits, HPA bounds, and PDB thresholds per environment.

| | dev | qa | prod |
|---|---|---|---|
| Replicas | 1 | 2 | 3 |
| CPU req/limit | 50m/200m | 250m/500m | 500m/1000m |
| Memory req/limit | 128Mi/256Mi | 256Mi/512Mi | 512Mi/1Gi |
| HPA min/max | 1/2 | 2/5 | 3/10 |
| PDB minAvailable | 1 | 1 | 2 |


## Observability

Prometheus scrapes both services using pod annotations and runs five alert rules. The rules use the actual metric names exposed by the services (`gateway_requests_total`, `processor_request_duration_seconds_bucket`, etc.) rather than generic names. Each alert includes an action annotation with the specific kubectl commands you would run to diagnose the issue.

The alert rules cover service down (scrape target unreachable for over 1 minute), high error rate (5xx responses above 5% for either service), and high latency (p99 above 1 second for either service).

I chose not to deploy kube-state-metrics to keep the local setup focused. This means there is no pod restart alert, since that metric comes from kube-state-metrics. In production I would add it.

Grafana is deployed with the Prometheus datasource auto-provisioned. There are no pre-built dashboards yet. As a next step I would add RED metrics dashboards showing request rate, error rate, and duration for each service.


## What I would do next

Gateway-to-processor traffic is currently plain HTTP. For a production payment system I would add Linkerd to encrypt all pod-to-pod communication with mTLS. This is a PCI-DSS requirement for payment data in transit, and Linkerd is the lightest service mesh option.

The Kubernetes Secret storing Grafana credentials is base64-encoded but not encrypted at rest by default. A production setup would use External Secrets Operator to pull credentials from HashiCorp Vault or AWS Secrets Manager, with automatic rotation.

Alert rules exist but there is no Alertmanager to route notifications. In production, alerts need to reach on-call engineers through PagerDuty or Slack, with proper grouping, deduplication, and silencing.

Pod logs are ephemeral and disappear when a container restarts. I would add Loki and Promtail for persistent, searchable log aggregation correlated with metrics. Without centralized logging, debugging a crash that already happened is difficult.

For CI/CD I would set up a GitHub Actions pipeline that lints manifests with kubeconform, deploys to a kind cluster, runs smoke tests against the deployed services, and scans container images with Trivy before they reach the cluster.
