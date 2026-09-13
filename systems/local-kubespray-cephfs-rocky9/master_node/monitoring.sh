#!/usr/bin/env bash
set -euo pipefail

SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
SOURCE_INVENTORY="${SOURCE_INVENTORY:-$SYSTEM_ROOT/inventory.ini}"

if [[ ! -f "$SOURCE_INVENTORY" ]]; then
  echo "Inventory not found: $SOURCE_INVENTORY" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$SYSTEM_ROOT/common/inventory.sh"

PROMETHEUS_CHART_VERSION="$(require_inventory_var "$SOURCE_INVENTORY" prometheus_chart_version)"
GRAFANA_CHART_VERSION="$(require_inventory_var "$SOURCE_INVENTORY" grafana_chart_version)"
STORAGE_CLASS="$(require_inventory_var "$SOURCE_INVENTORY" monitoring_storage_class)"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  --version "$PROMETHEUS_CHART_VERSION" \
  --namespace monitoring --create-namespace \
  --set "alertmanager.persistence.storageClass=$STORAGE_CLASS" \
  --set "server.persistentVolume.storageClass=$STORAGE_CLASS"

helm upgrade --install grafana grafana/grafana \
  --version "$GRAFANA_CHART_VERSION" \
  --namespace monitoring --create-namespace \
  --set persistence.enabled=true \
  --set "persistence.storageClassName=$STORAGE_CLASS" \
  --set service.type=NodePort \
  --set 'datasources.datasources\.yaml.apiVersion=1' \
  --set 'datasources.datasources\.yaml.datasources[0].name=Prometheus' \
  --set 'datasources.datasources\.yaml.datasources[0].type=prometheus' \
  --set 'datasources.datasources\.yaml.datasources[0].url=http://prometheus-server.monitoring.svc.cluster.local' \
  --set 'datasources.datasources\.yaml.datasources[0].access=proxy' \
  --set 'datasources.datasources\.yaml.datasources[0].isDefault=true'

echo "Retrieve the generated Grafana password with:"
echo "kubectl get secret --namespace monitoring grafana -o jsonpath='{.data.admin-password}'"
