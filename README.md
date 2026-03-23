# Pinecone BYOC Monitoring

Prometheus + Grafana monitoring stack for [Pinecone BYOC](https://docs.pinecone.io/guides/operations/understanding-byoc) (Bring Your Own Cloud) Kubernetes clusters.

Provides pre-built dashboards covering:

- **Kubernetes cluster health** — node CPU, memory, disk; pod resource usage; PVC capacity
- **Pinecone index metrics** — record counts, storage, DRN CPU, query/upsert rates, latency percentiles, read/write units
- **Pinecone API metrics** — `pinecone_db_*` metrics pulled from the Pinecone metrics API

## Architecture

```
┌─────────────────────────────────────────────────────┐
│ BYOC Kubernetes Cluster                             │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐                 │
│  │ node-exporter│  │kube-state-   │                 │
│  │ (DaemonSet)  │  │metrics       │                 │
│  └──────┬───────┘  └──────┬───────┘                 │
│         │                 │                         │
│  ┌──────▼─────────────────▼──────┐                  │
│  │       Prometheus Server       │◄── scrapes ──┐   │
│  │   (already in BYOC cluster)   │              │   │
│  └──────────────┬────────────────┘              │   │
│                 │                     ┌─────────┴─┐ │
│          ┌──────▼──────┐              │ Pinecone  │ │
│          │   Grafana   │              │ Metrics   │ │
│          │  (NodePort  │              │ API       │ │
│          │   :30300)   │              └───────────┘ │
│          └─────────────┘                            │
└─────────────────────────────────────────────────────┘
```

## Prerequisites

- `kubectl` configured with access to your BYOC cluster
- `helm` v3+
- `python3` with PyYAML (`pip install pyyaml`)
- A Pinecone API key with access to your project
- SSH access to a bastion host in the BYOC VPC (for Grafana access)

## Quick Start

### 1. Configure kubectl

```bash
aws eks update-kubeconfig --region <REGION> --name <CLUSTER_NAME>
```

### 2. Set environment variables

```bash
export PINECONE_API_KEY="pcsk_..."
export PINECONE_PROJECT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export BYOC_METRICS_DOMAIN="preprod-aws-us-east-2-xxxx.byoc"
```

| Variable | Description | Example |
|---|---|---|
| `PINECONE_API_KEY` | Your Pinecone API key | `pcsk_abc123...` |
| `PINECONE_PROJECT_ID` | Project ID (from Pinecone console URL) | `d2e983b7-8ead-48ac-8fd4-f4bcc3f3e71a` |
| `BYOC_METRICS_DOMAIN` | BYOC domain prefix from your cluster | `preprod-aws-us-east-2-c97f.byoc` |

### 3. Deploy

```bash
./scripts/deploy.sh
```

This will:
1. Install `node-exporter` and `kube-state-metrics` via Helm
2. Create a Kubernetes secret for the Pinecone API key
3. Set up RBAC for Prometheus to scrape kubelet/cAdvisor metrics
4. Merge monitoring scrape jobs into the existing Prometheus config
5. Mount the API key into the Prometheus server pod
6. Deploy Grafana with pre-configured dashboards

### 4. Access Grafana

Grafana is exposed as a NodePort service on port **30300**. Since BYOC clusters run in a private VPC, use an SSH tunnel through your bastion host:

```bash
# Find the node IP where Grafana is running
GRAFANA_NODE=$(kubectl get pods -n grafana -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].status.hostIP}')

# SSH tunnel through the bastion
ssh -L 3000:$GRAFANA_NODE:30300 -A ec2-user@<BASTION_IP>
```

Then open [http://localhost:3000](http://localhost:3000) and log in with:
- **Username:** `admin`
- **Password:** `pinecone-monitoring` (change this in `grafana/grafana-values.yaml`)

## Dashboards

### Pinecone BYOC - Kubernetes Cluster

Overview of cluster-wide and pod-level resources:

| Section | Panels |
|---|---|
| Cluster Overview | Running pods, total nodes, CPU %, memory % |
| Node Resources | Per-node CPU, memory, disk usage; filesystem % bar gauge |
| Pod CPU | Top-10 pods by CPU, CPU by namespace (stacked), requests/limits/actual table |
| Pod Memory | Top-10 pods by memory, memory by namespace (stacked), requests/limits/actual table |
| Pod Storage | PVC usage bar gauge, capacity vs. used over time |

### Pinecone BYOC - Index Metrics

Index-level operational and API metrics:

| Section | Panels |
|---|---|
| Index Pod Resources | Active pods, total CPU, total memory, total records |
| CPU & Memory Over Time | Per-pod CPU and memory timeseries |
| Pinecone API Metrics | Records & storage per index, DRN CPU %, query/upsert rates, avg query latency, read/write units |
| Internal Pod Metrics | DRN CPU (internal), request rate, p50/p95/p99 latency, error rate, vector count, read/write units |

## Multiple Projects

To monitor indexes across multiple Pinecone projects, add extra scrape jobs to `prometheus/prometheus-scrape-jobs.yaml`. For each additional project:

1. Create a separate secret:

```bash
kubectl create secret generic pinecone-api-key-2 \
  -n prometheus \
  --from-literal=api-key="<SECOND_API_KEY>"
```

2. Add a volume + volume mount to the Prometheus deployment patch for `/etc/pinecone-2/`

3. Duplicate the `pinecone-serverless-metrics` and `pinecone-byoc-metrics` jobs in the scrape config, changing:
   - `job_name` (must be unique)
   - `YOUR_PROJECT_ID` to the second project's ID
   - `credentials_file` to `/etc/pinecone-2/api-key`

## File Structure

```
pinecone-byoc-monitoring/
├── README.md
├── grafana/
│   ├── grafana-values.yaml          # Helm values for Grafana
│   └── dashboards/
│       ├── kubernetes-cluster.json   # K8s cluster dashboard
│       └── pinecone-metrics.json     # Pinecone index metrics dashboard
├── prometheus/
│   ├── node-exporter-values.yaml             # Helm values for node-exporter
│   ├── prometheus-scrape-jobs.yaml           # Additional scrape jobs (templatized)
│   └── prometheus-secret-volume-patch.yaml   # Deployment patch for API key mount
└── scripts/
    ├── deploy.sh                    # Full deploy script
    └── uninstall.sh                 # Cleanup script
```

## Manual Setup (Step by Step)

If you prefer to run each step individually instead of using the deploy script:

<details>
<summary>Click to expand manual steps</summary>

#### Install node-exporter

```bash
helm install node-exporter prometheus-community/prometheus-node-exporter \
  -n prometheus -f prometheus/node-exporter-values.yaml
```

#### Install kube-state-metrics

```bash
helm install kube-state-metrics prometheus-community/kube-state-metrics \
  -n prometheus
```

#### Create Pinecone API key secret

```bash
kubectl create secret generic pinecone-api-key \
  -n prometheus \
  --from-literal=api-key="$PINECONE_API_KEY"
```

#### Get existing Prometheus config, merge new scrape jobs, and apply

```bash
kubectl get configmap prometheus-server -n prometheus \
  -o jsonpath='{.data.prometheus\.yml}' > /tmp/prometheus.yml

# Edit /tmp/prometheus.yml to append the jobs from prometheus-scrape-jobs.yaml
# (replacing YOUR_PROJECT_ID and YOUR_BYOC_DOMAIN with actual values)

kubectl create configmap prometheus-server -n prometheus \
  --from-file=prometheus.yml=/tmp/prometheus.yml \
  --dry-run=client -o yaml | kubectl apply -f -
```

#### Mount the API key secret in Prometheus

```bash
kubectl patch deployment prometheus-server -n prometheus \
  --type strategic \
  --patch-file prometheus/prometheus-secret-volume-patch.yaml
```

#### Deploy Grafana

```bash
kubectl create namespace grafana

kubectl create configmap grafana-dashboards -n grafana \
  --from-file=grafana/dashboards/

helm install grafana grafana/grafana \
  -n grafana -f grafana/grafana-values.yaml
```

</details>

## Uninstall

```bash
./scripts/uninstall.sh
```

This removes Grafana, node-exporter, kube-state-metrics, the API key secret, and monitoring RBAC. The Prometheus server deployment itself is **not** removed, as it is managed by the BYOC cluster.

## Troubleshooting

### node-exporter pods not scheduling on all nodes

The BYOC cluster uses a Kyverno policy (`protect-dedicated-nodes`) that mutates pods with wildcard tolerations. The `node-exporter-values.yaml` uses a specific toleration key (`pinecone.io/dedicated`) to avoid this. If you see pod churn, check:

```bash
kubectl get pods -n prometheus -l app.kubernetes.io/name=prometheus-node-exporter
kubectl get clusterpolicy protect-dedicated-nodes -o yaml
```

### Pinecone API metrics showing "No data"

`pinecone_db_*` metrics only appear when your indexes are actively serving traffic. If indexes are idle, the API export endpoint returns no data. Run some queries/upserts and check again.

Verify targets in Prometheus:

```bash
kubectl port-forward -n prometheus svc/prometheus-server 9090:80
# Open http://localhost:9090/targets
```

### Grafana PVC multi-attach error on restart

The `grafana-values.yaml` sets `strategy.type: Recreate` to prevent this. If you still hit it:

```bash
kubectl patch deployment grafana -n grafana --type=json \
  -p '[{"op":"remove","path":"/spec/strategy/rollingUpdate"},{"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'
```

## References

- [Pinecone BYOC Monitoring Docs](https://docs.pinecone.io/guides/production/monitoring#monitor-with-prometheus)
- [Prometheus Helm Chart](https://github.com/prometheus-community/helm-charts)
- [Grafana Helm Chart](https://github.com/grafana/helm-charts)
