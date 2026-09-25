#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

MESH_NAMESPACES="${MESH_NAMESPACES:-istio-system bookinfo}"
TEMPO_STORAGE_SECRET="${TEMPO_STORAGE_SECRET:-tempostack-odf}"

wait_for_labeled_resources() {
  local namespace="$1"
  local kind="$2"
  local selector="$3"
  local timeout_seconds="${4:-180}"
  local deadline=$((SECONDS + timeout_seconds))
  local found=""

  while (( SECONDS < deadline )); do
    found="$(oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get "${kind}" -n "${namespace}" -l "${selector}" -o name 2>/dev/null || true)"
    [[ -n "${found}" ]] && break
    sleep 2
  done
  [[ -n "${found}" ]] || {
    echo "ERROR: no ${kind} in ${namespace} matched label selector ${selector}." >&2
    exit 1
  }
  printf '%s\n' "${found}"
}

echo "Checking Sail control plane CR readiness..."
wait_cr_condition "istiocnis.sailoperator.io/default" istio-cni Ready 180
wait_cr_condition "istios.sailoperator.io/default" istio-system Ready 180

echo "Checking Telemetry and Istio metrics monitor CRs..."
wait_resource_exists "telemetries.telemetry.istio.io/mesh-observability" istio-system 60
[[ "$(oc_get telemetry mesh-observability -n istio-system -o jsonpath='{.spec.tracing[0].providers[0].name}')" == "otel-tracing" ]] || {
  echo "ERROR: mesh-observability does not select otel-tracing." >&2
  exit 1
}
[[ "$(oc_get telemetry mesh-observability -n istio-system -o jsonpath='{.spec.tracing[0].randomSamplingPercentage}')" == "10" || \
   "$(oc_get telemetry mesh-observability -n istio-system -o jsonpath='{.spec.tracing[0].randomSamplingPercentage}')" == "10.0" ]] || {
  echo "ERROR: mesh-observability sampling is not 10%." >&2
  exit 1
}
wait_resource_exists "servicemonitors.monitoring.coreos.com/istiod-monitor" istio-system 60
for ns in ${MESH_NAMESPACES}; do
  wait_resource_exists "podmonitors.monitoring.coreos.com/istio-proxies-monitor" "${ns}" 60
done

echo "Checking user workload monitoring..."
cfg="$(oc_get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}')"
printf '%s\n' "${cfg}" | grep -Eq '^[[:space:]]*enableUserWorkload:[[:space:]]*true[[:space:]]*$' || {
  echo "ERROR: user workload monitoring is not enabled." >&2
  exit 1
}
oc_get pods -n openshift-user-workload-monitoring >/dev/null
require_all_pods_ready openshift-user-workload-monitoring 180

echo "Checking ODF and Tempo..."
wait_obc_bound tempo tempo-odf 120
oc_get secret "${TEMPO_STORAGE_SECRET}" -n tempo >/dev/null
for key in bucket endpoint access_key_id access_key_secret; do
  oc_get secret "${TEMPO_STORAGE_SECRET}" -n tempo -o "jsonpath={.data.${key}}" | grep -q . || {
    echo "ERROR: Tempo storage Secret key '${key}' is missing/empty." >&2
    exit 1
  }
done
wait_cr_condition "tempostacks.tempo.grafana.com/mesh" tempo Ready 180
require_selector_pods_ready tempo 'app.kubernetes.io/instance=mesh' 180
wait_resource_exists "services/tempo-mesh-gateway" tempo 60
require_service_endpoints tempo tempo-mesh-gateway 120

echo "Checking Tempo operator-managed monitoring CRs..."
wait_for_labeled_resources tempo servicemonitor 'app.kubernetes.io/instance=mesh' 180 >/dev/null
wait_for_labeled_resources tempo prometheusrule 'app.kubernetes.io/instance=mesh' 180 >/dev/null

echo "Checking OTel CR, operand, RBAC, and monitoring..."
require_tempo_sar \
  "otel-collector" \
  "system:serviceaccount:istio-system:otel-collector" \
  create
wait_resource_exists "clusterrolebindings.rbac.authorization.k8s.io/tempo-mesh-traces-writer-otel" "" 60
wait_cr_condition "opentelemetrycollectors.opentelemetry.io/otel" istio-system Ready 180
wait_deployment_available istio-system otel-collector 120
wait_resource_exists "services/otel-collector" istio-system 60
require_service_endpoints istio-system otel-collector 120
for _ in $(seq 1 90); do
  otel_monitors="$(oc_get servicemonitor,podmonitor -n istio-system -o name 2>/dev/null | grep -Ei 'otel|opentelemetry' || true)"
  [[ -n "${otel_monitors}" ]] && break
  sleep 2
done
[[ -n "${otel_monitors:-}" ]] || {
  echo "ERROR: OTel observability is enabled but no ServiceMonitor/PodMonitor was created." >&2
  exit 1
}
printf '%s\n' "${otel_monitors}"

echo "Checking Kiali CR, operand, RBAC, and tracing configuration..."
require_tempo_sar \
  "kiali-service-account" \
  "system:serviceaccount:istio-system:kiali-service-account" \
  get
[[ "$(oc auth can-i get pods --as=system:serviceaccount:istio-system:kiali-service-account -n istio-system)" == "yes" ]] || {
  echo "ERROR: kiali-service-account cannot read the mesh namespace." >&2
  exit 1
}
wait_resource_exists "clusterrolebindings.rbac.authorization.k8s.io/kiali-monitoring-rbac-v34" "" 60
wait_resource_exists "clusterrolebindings.rbac.authorization.k8s.io/tempo-mesh-traces-reader-kiali" "" 60
wait_cr_condition "kialis.kiali.io/kiali" istio-system Successful 180
wait_deployment_available istio-system kiali 120
require_service_endpoints istio-system kiali 120
kiali_sa="$(oc_get deployment kiali -n istio-system -o jsonpath='{.spec.template.spec.serviceAccountName}')"
[[ "${kiali_sa}" == "kiali-service-account" ]] || {
  echo "ERROR: Kiali deployment uses ServiceAccount '${kiali_sa}', but RBAC targets kiali-service-account." >&2
  exit 1
}
wait_resource_exists "services/thanos-querier" openshift-monitoring 60

console_url="https://$(oc_get route console -n openshift-console -o jsonpath='{.spec.host}')"
[[ "$(oc_get kiali kiali -n istio-system -o jsonpath='{.spec.external_services.tracing.external_url}')" == "${console_url}" ]] || {
  echo "ERROR: Kiali tracing external_url does not target the OpenShift console." >&2
  exit 1
}
[[ "$(oc_get kiali kiali -n istio-system -o jsonpath='{.spec.external_services.tracing.tempo_config.url_format}')" == "openshift" ]] || {
  echo "ERROR: Kiali tempo_config.url_format is not openshift." >&2
  exit 1
}


if [[ "${ENABLE_MESH_CONSOLE:-1}" == "1" ]]; then
  echo "Checking OpenShift Service Mesh Console reconciliation..."
  wait_cr_condition "ossmconsoles.kiali.io/ossmconsole" openshift-operators Successful 180
  require_console_plugin_backend ossmconsole 180
fi

if [[ "${ENABLE_TRACING_UI:-1}" == "1" ]]; then
  echo "Checking OpenShift distributed tracing UIPlugin reconciliation..."
  wait_cr_condition "uiplugins.observability.openshift.io/distributed-tracing" "" Available 180
fi

if [[ "${DEPLOY_BOOKINFO:-1}" == "1" ]]; then
  echo "Checking Bookinfo application, sidecars, gateway CRs, and Route..."
  for deployment in details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3 productpage-v1 istio-ingressgateway; do
    wait_deployment_available bookinfo "${deployment}" 120
  done
  for service in details ratings reviews productpage istio-ingressgateway; do
    require_service_endpoints bookinfo "${service}" 120
  done
  for app in details ratings reviews productpage; do
    require_selector_pods_container bookinfo "app=${app}" istio-proxy 120
  done
  require_istio_bookinfo_routing bookinfo 60
  wait_route_admitted bookinfo istio-ingressgateway 120
  require_bookinfo_ingress_contract bookinfo
fi

echo
echo "Core OSSM 3.4 observability and Bookinfo readiness checks passed."
