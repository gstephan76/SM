#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${1:-"$ROOT/.env"}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

printf '\n== Control plane ==\n'
oc get istio default -o wide || true
oc get istiocni default -o wide || true
oc get pods -n istio-system -o wide || true

printf '\n== Monitoring ==\n'
oc get servicemonitor -n istio-system istiod-monitor || true
oc get podmonitor -n istio-system istio-proxies-monitor || true
for ns in ${MESH_NAMESPACES:-}; do
  oc get podmonitor -n "$ns" istio-proxies-monitor || true
done

printf '\n== Tempo ==\n'
oc get tempostack -n tempo mesh -o wide || true
oc get pods -n tempo -o wide || true
oc get svc -n tempo tempo-mesh-gateway || true

printf '\n== OpenTelemetry ==\n'
oc get opentelemetrycollector -n istio-system otel -o wide || true
oc get pods -n istio-system -l app.kubernetes.io/managed-by=opentelemetry-operator -o wide || true
oc get svc -n istio-system otel-collector || true

printf '\n== Kiali ==\n'
oc get kiali -n istio-system kiali || true
oc get pods -n istio-system -l app.kubernetes.io/name=kiali -o wide || true
oc get route -n istio-system kiali || true

printf '\n== Tempo RBAC objects ==\n'
oc get clusterrole tempo-mesh-write tempo-mesh-read || true
oc get clusterrolebinding tempo-mesh-write tempo-mesh-read-kiali || true

printf '\n== Useful metric query ==\n'
echo 'In OpenShift Observe -> Metrics, query: istio_requests_total'
echo 'Generate application traffic before expecting traces or Kiali graph edges.'
