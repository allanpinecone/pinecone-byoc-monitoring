#!/usr/bin/env bash
set -euo pipefail

#
# Deploy Prometheus + Grafana monitoring stack for a Pinecone BYOC cluster.
#
# Usage:
#   export PINECONE_API_KEY="pcsk_..."
#   export PINECONE_PROJECT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#   export BYOC_METRICS_DOMAIN="preprod-aws-us-east-2-xxxx.byoc"
#   ./scripts/deploy.sh
#
# Optional:
#   KUBECONFIG          — path to kubeconfig (defaults to ~/.kube/config)
#   PROMETHEUS_NS       — namespace for Prometheus (default: prometheus)
#   GRAFANA_NS          — namespace for Grafana (default: grafana)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${PINECONE_API_KEY:?Set PINECONE_API_KEY to your Pinecone API key}"
: "${PINECONE_PROJECT_ID:?Set PINECONE_PROJECT_ID to your Pinecone project ID}"
: "${BYOC_METRICS_DOMAIN:?Set BYOC_METRICS_DOMAIN (e.g. preprod-aws-us-east-2-xxxx.byoc)}"

PROMETHEUS_NS="${PROMETHEUS_NS:-prometheus}"
GRAFANA_NS="${GRAFANA_NS:-grafana}"

# ---- Detect private vs public cluster --------------------------------------
# Check the pc-pulumi-outputs configmap for public_access_enabled.  Fall back
# to the EKS API endpoint access configuration if the configmap is unavailable.
PRIVATE_CLUSTER="false"
PULUMI_JSON=$(kubectl get configmap config -n pc-pulumi-outputs \
  -o jsonpath='{.data.pulumi-outputs}' 2>/dev/null || echo "")

if [ -n "$PULUMI_JSON" ]; then
  PAE=$(echo "$PULUMI_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('public_access_enabled','true'))" 2>/dev/null || echo "true")
  if [ "$PAE" = "False" ] || [ "$PAE" = "false" ]; then
    PRIVATE_CLUSTER="true"
  fi
fi

if [ "$PRIVATE_CLUSTER" = "true" ]; then
  METRICS_HOST_PREFIX="metrics.private."
  echo "==> Detected PRIVATE BYOC cluster (public access disabled)"
else
  METRICS_HOST_PREFIX="metrics."
  echo "==> Detected PUBLIC BYOC cluster"
fi

echo "==> Pinecone BYOC Monitoring Deployment"
echo "    Project ID:      $PINECONE_PROJECT_ID"
echo "    BYOC Domain:     $BYOC_METRICS_DOMAIN"
echo "    Metrics Host:    ${METRICS_HOST_PREFIX}${BYOC_METRICS_DOMAIN}.pinecone.io"
echo "    Prometheus NS:   $PROMETHEUS_NS"
echo "    Grafana NS:      $GRAFANA_NS"
echo ""

# ---- Helm repos -----------------------------------------------------------
echo "==> Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

# ---- Namespaces ------------------------------------------------------------
echo "==> Creating namespaces..."
kubectl create namespace "$PROMETHEUS_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$GRAFANA_NS"    --dry-run=client -o yaml | kubectl apply -f -

# ---- Node exporter ---------------------------------------------------------
echo "==> Deploying node-exporter..."
helm upgrade --install node-exporter prometheus-community/prometheus-node-exporter \
  --namespace "$PROMETHEUS_NS" \
  -f "$REPO_ROOT/prometheus/node-exporter-values.yaml"

# ---- Kube-state-metrics ----------------------------------------------------
echo "==> Deploying kube-state-metrics..."
helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --namespace "$PROMETHEUS_NS"

# ---- Pinecone API key secret -----------------------------------------------
echo "==> Creating Pinecone API key secret..."
kubectl create secret generic pinecone-api-key \
  --namespace "$PROMETHEUS_NS" \
  --from-literal=api-key="$PINECONE_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---- Prometheus RBAC -------------------------------------------------------
echo "==> Ensuring Prometheus RBAC..."
kubectl apply -f - <<'RBAC'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-monitoring
rules:
- apiGroups: [""]
  resources: [nodes, nodes/proxy, nodes/metrics, services, endpoints, pods]
  verbs: [get, list, watch]
- apiGroups: [extensions, networking.k8s.io]
  resources: [ingresses]
  verbs: [get, list, watch]
- nonResourceURLs: [/metrics, /metrics/cadvisor]
  verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus-monitoring
subjects:
- kind: ServiceAccount
  name: prometheus-server
  namespace: prometheus
RBAC

# ---- Patch Prometheus config ------------------------------------------------
echo "==> Building and applying Prometheus scrape config..."

EXISTING_CONFIG=$(kubectl get configmap prometheus-server -n "$PROMETHEUS_NS" \
  -o jsonpath='{.data.prometheus\.yml}' 2>/dev/null || echo "")

if [ -z "$EXISTING_CONFIG" ]; then
  echo "    WARNING: Existing prometheus-server configmap not found."
  echo "    The BYOC cluster should already have a prometheus-server configmap."
  echo "    Please ensure Prometheus is installed and re-run."
  exit 1
fi

SCRAPE_JOBS=$(cat "$REPO_ROOT/prometheus/prometheus-scrape-jobs.yaml" \
  | sed "s|YOUR_PROJECT_ID|$PINECONE_PROJECT_ID|g" \
  | sed "s|YOUR_BYOC_DOMAIN|$BYOC_METRICS_DOMAIN|g" \
  | sed "s|YOUR_METRICS_HOST_PREFIX|$METRICS_HOST_PREFIX|g")

EXISTING_YAML_BASE=$(echo "$EXISTING_CONFIG" | python3 -c "
import sys, yaml
config = yaml.safe_load(sys.stdin)
config.pop('scrape_configs', None)
yaml.dump(config, sys.stdout, default_flow_style=False)
" 2>/dev/null || echo "$EXISTING_CONFIG")

EXISTING_SCRAPE=$(echo "$EXISTING_CONFIG" | python3 -c "
import sys, yaml
config = yaml.safe_load(sys.stdin)
jobs = config.get('scrape_configs', [])
new_job_names = set()
yaml.dump(jobs, sys.stdout, default_flow_style=False)
")

MERGED_FILE=$(mktemp)
trap "rm -f $MERGED_FILE" EXIT

python3 -c "
import sys, yaml

existing = yaml.safe_load('''$EXISTING_CONFIG''')

with open('$REPO_ROOT/prometheus/prometheus-scrape-jobs.yaml') as f:
    content = f.read()
    content = content.replace('YOUR_PROJECT_ID', '$PINECONE_PROJECT_ID')
    content = content.replace('YOUR_BYOC_DOMAIN', '$BYOC_METRICS_DOMAIN')
    content = content.replace('YOUR_METRICS_HOST_PREFIX', '$METRICS_HOST_PREFIX')
    new_jobs = yaml.safe_load(content)

existing_names = {j['job_name'] for j in existing.get('scrape_configs', [])}
for job in new_jobs:
    if job['job_name'] not in existing_names:
        existing.setdefault('scrape_configs', []).append(job)
    else:
        for i, ej in enumerate(existing['scrape_configs']):
            if ej['job_name'] == job['job_name']:
                existing['scrape_configs'][i] = job
                break

yaml.dump(existing, open('$MERGED_FILE', 'w'), default_flow_style=False)
"

kubectl create configmap prometheus-server \
  --namespace "$PROMETHEUS_NS" \
  --from-file=prometheus.yml="$MERGED_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---- Patch Prometheus deployment for secret volume --------------------------
echo "==> Patching Prometheus server deployment for API key mount..."
kubectl patch deployment prometheus-server -n "$PROMETHEUS_NS" \
  --type strategic \
  --patch-file "$REPO_ROOT/prometheus/prometheus-secret-volume-patch.yaml"

# ---- Grafana dashboards configmap -------------------------------------------
echo "==> Creating Grafana dashboards configmap..."
kubectl create configmap grafana-dashboards \
  --namespace "$GRAFANA_NS" \
  --from-file="$REPO_ROOT/grafana/dashboards/" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---- Grafana ----------------------------------------------------------------
echo "==> Deploying Grafana..."
helm upgrade --install grafana grafana/grafana \
  --namespace "$GRAFANA_NS" \
  -f "$REPO_ROOT/grafana/grafana-values.yaml"

# ---- Restart pods to pick up changes ----------------------------------------
echo "==> Restarting Prometheus..."
kubectl rollout restart deployment/prometheus-server -n "$PROMETHEUS_NS"
kubectl rollout status deployment/prometheus-server -n "$PROMETHEUS_NS" --timeout=120s

echo "==> Restarting Grafana..."
kubectl rollout restart deployment/grafana -n "$GRAFANA_NS"
kubectl rollout status deployment/grafana -n "$GRAFANA_NS" --timeout=120s

echo ""
echo "==> Deployment complete!"
echo ""
echo "To access Grafana, set up an SSH tunnel through your bastion host:"
echo ""
echo "  GRAFANA_NODE=\$(kubectl get pods -n $GRAFANA_NS -l app.kubernetes.io/name=grafana \\"
echo "    -o jsonpath='{.items[0].status.hostIP}')"
echo ""
echo "  ssh -L 3000:\$GRAFANA_NODE:30300 -A ec2-user@<BASTION_IP>"
echo ""
echo "  Then open http://localhost:3000  (admin / pinecone-monitoring)"
echo ""
