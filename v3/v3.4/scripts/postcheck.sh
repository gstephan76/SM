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
  local found=""
  for _ in $(seq 1 60); do
    found="$(
      oc get "${kind}" -n "${namespace}" -l "${selector}" -o name 2>/dev/null || true
    )"
    [[ -n "${found}" ]] && break
    sleep 2
  done
  [[ -n "${found}" ]] || {
    echo "ERROR: no ${kind} in ${namespace} matched label selector ${selector}." >&2
    exit 1
  }
  printf '%s\n' "${found}"
}

echo "Checking Sail control plane..."
oc wait --for=condition=Ready istiocni/default \
  -n istio-cni --timeout=1m
oc wait --for=condition=Ready istio/default \
  -n istio-system --timeout=1m

echo "Checking Telemetry and Istio metrics monitors..."
oc get telemetry mesh-observability -n istio-system
oc get servicemonitor istiod-monitor -n istio-system
for ns in ${MESH_NAMESPACES}; do
  oc get podmonitor istio-proxies-monitor -n "${ns}"
done

echo "Checking user workload monitoring..."
cfg="$(
  oc get configmap cluster-monitoring-config \
    -n openshift-monitoring \
    -o jsonpath='{.data.config\.yaml}'
)"
printf '%s\n' "${cfg}" |
  grep -Eq '^[[:space:]]*enableUserWorkload:[[:space:]]*true[[:space:]]*$'
oc get pods -n openshift-user-workload-monitoring

echo "Checking ODF and Tempo..."
[[ "$(
  oc get obc tempo-odf -n tempo -o jsonpath='{.status.phase}'
)" == "Bound" ]]
oc get secret "${TEMPO_STORAGE_SECRET}" -n tempo >/dev/null
for key in bucket endpoint access_key_id access_key_secret; do
  oc get secret "${TEMPO_STORAGE_SECRET}" \
    -n tempo \
    -o "jsonpath={.data.${key}}" |
    grep -q .
done
oc wait --for=condition=Ready tempostack/mesh \
  -n tempo --timeout=1m
oc get svc tempo-mesh-gateway -n tempo

echo "Checking Tempo operator-managed monitoring..."
wait_for_labeled_resources tempo servicemonitor 'app.kubernetes.io/instance=mesh' >/dev/null
wait_for_labeled_resources tempo prometheusrule 'app.kubernetes.io/instance=mesh' >/dev/null
oc get servicemonitor -n tempo
oc get prometheusrule -n tempo

echo "Checking OTel..."
require_tempo_sar \
  "otel-collector" \
  "system:serviceaccount:istio-system:otel-collector" \
  create
oc get clusterrolebinding tempo-mesh-traces-writer-otel >/dev/null
oc get opentelemetrycollector otel -n istio-system
oc wait --for=condition=Available deployment/otel-collector \
  -n istio-system --timeout=1m
oc get svc otel-collector -n istio-system

echo "Checking OTel operator-managed monitoring..."
for _ in $(seq 1 60); do
  otel_monitors="$(
    oc get servicemonitor,podmonitor -n istio-system -o name 2>/dev/null |
    grep -Ei 'otel|opentelemetry' || true
  )"
  [[ -n "${otel_monitors}" ]] && break
  sleep 2
done
[[ -n "${otel_monitors:-}" ]] || {
  echo "ERROR: OTel observability is enabled but no ServiceMonitor/PodMonitor was created." >&2
  exit 1
}
printf '%s\n' "${otel_monitors}"

echo "Checking Kiali and its role bindings..."
require_tempo_sar \
  "kiali-service-account" \
  "system:serviceaccount:istio-system:kiali-service-account" \
  get
[[ "$(
  oc auth can-i get pods \
    --as=system:serviceaccount:istio-system:kiali-service-account \
    -n istio-system
)" == "yes" ]] || {
  echo "ERROR: kiali-service-account cannot read the mesh namespace." >&2
  exit 1
}
oc get clusterrolebinding kiali-monitoring-rbac-v34 >/dev/null
oc get clusterrolebinding tempo-mesh-traces-reader-kiali >/dev/null
oc get kiali kiali -n istio-system
oc wait --for=condition=Available deployment/kiali \
  -n istio-system --timeout=1m
kiali_sa="$(
  oc get deployment kiali -n istio-system \
    -o jsonpath='{.spec.template.spec.serviceAccountName}'
)"
[[ "${kiali_sa}" == "kiali-service-account" ]] || {
  echo "ERROR: Kiali deployment uses ServiceAccount '${kiali_sa}', but RBAC targets kiali-service-account." >&2
  exit 1
}
oc get svc thanos-querier -n openshift-monitoring

console_url="https://$(
  oc get route console -n openshift-console -o jsonpath='{.spec.host}'
)"
[[ "$(oc get kiali kiali -n istio-system -o jsonpath='{.spec.external_services.tracing.external_url}')" == "${console_url}" ]] || {
  echo "ERROR: Kiali tracing external_url does not target the OpenShift console." >&2
  exit 1
}
[[ "$(oc get kiali kiali -n istio-system -o jsonpath='{.spec.external_services.tracing.tempo_config.url_format}')" == "openshift" ]] || {
  echo "ERROR: Kiali tempo_config.url_format is not openshift." >&2
  exit 1
}

if [[ "${ENABLE_TRACING_UI:-1}" == "1" ]]; then
  echo "Checking OpenShift distributed tracing UI..."
  oc get uiplugin distributed-tracing >/dev/null
fi

echo
echo "Core OSSM 3.4 observability readiness checks passed."
echo "For an actual trace round-trip, run:"
echo "  TRACE_TEST_URL=https://<mesh-app-url>/ ./scripts/e2e-check.sh"
