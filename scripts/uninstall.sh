#!/usr/bin/env bash
set -euo pipefail

#
# Remove the monitoring stack from a Pinecone BYOC cluster.
#
# Usage:  ./scripts/uninstall.sh
#

PROMETHEUS_NS="${PROMETHEUS_NS:-prometheus}"
GRAFANA_NS="${GRAFANA_NS:-grafana}"

echo "==> Removing Grafana..."
helm uninstall grafana -n "$GRAFANA_NS" 2>/dev/null || true
kubectl delete configmap grafana-dashboards -n "$GRAFANA_NS" 2>/dev/null || true

echo "==> Removing monitoring exporters..."
helm uninstall node-exporter    -n "$PROMETHEUS_NS" 2>/dev/null || true
helm uninstall kube-state-metrics -n "$PROMETHEUS_NS" 2>/dev/null || true

echo "==> Removing Pinecone API key secret..."
kubectl delete secret pinecone-api-key -n "$PROMETHEUS_NS" 2>/dev/null || true

echo "==> Removing monitoring RBAC..."
kubectl delete clusterrolebinding prometheus-monitoring 2>/dev/null || true
kubectl delete clusterrole prometheus-monitoring 2>/dev/null || true

echo ""
echo "==> Uninstall complete."
echo "    NOTE: The prometheus-server deployment and its configmap were NOT removed,"
echo "    since they are managed by the BYOC cluster itself. If you added scrape jobs"
echo "    to the configmap, you may want to clean those up manually."
echo ""
