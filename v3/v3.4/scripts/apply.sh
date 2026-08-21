#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

"${ROOT}/scripts/validate.sh"

echo "== 2. Namespaces =="
oc apply -f "${ROOT}/manifests/00-namespaces.yaml"

echo "== 3. User workload monitoring =="
"${ROOT}/scripts/enable-uwm.sh"

echo "== 4. IstioCNI + Istio =="
if [[ "${APPLY_MESH_BASE:-0}" == "1" ]]; then
  oc apply -f "${ROOT}/manifests/02-istio-cni.yaml"
  oc wait --for=condition=Ready istiocni/default \
    -n istio-cni --timeout=5m

  oc apply -f "${ROOT}/manifests/03-istio.yaml"
  oc wait --for=condition=Ready istio/default \
    -n istio-system --timeout=5m
else
  oc get istiocni default -n istio-cni >/dev/null
  oc get istio default -n istio-system >/dev/null

  cni_version="$(
    oc get istiocni default -n istio-cni -o jsonpath='{.spec.version}'
  )"
  istio_version="$(
    oc get istio default -n istio-system -o jsonpath='{.spec.version}'
  )"

  [[ "${cni_version}" == "v1.30.3" ]] || {
    echo "ERROR: existing IstioCNI spec.version=${cni_version}; expected v1.30.3." >&2
    exit 1
  }
  [[ "${istio_version}" == "v1.30.3" ]] || {
    echo "ERROR: existing Istio spec.version=${istio_version}; expected v1.30.3." >&2
    exit 1
  }

  oc wait --for=condition=Ready istiocni/default \
    -n istio-cni --timeout=1m
  oc wait --for=condition=Ready istio/default \
    -n istio-system --timeout=1m

  provider_service="$(
    oc get istio default -n istio-system \
      -o jsonpath='{.spec.values.meshConfig.extensionProviders[?(@.name=="otel-tracing")].opentelemetry.service}'
  )"
  provider_port="$(
    oc get istio default -n istio-system \
      -o jsonpath='{.spec.values.meshConfig.extensionProviders[?(@.name=="otel-tracing")].opentelemetry.port}'
  )"

  [[ "${provider_service}" == "otel-collector.istio-system.svc.cluster.local" && "${provider_port}" == "4317" ]] || {
    echo "ERROR: existing Istio does not define otel-tracing at the required endpoint." >&2
    echo "Set APPLY_MESH_BASE=1 to reconcile manifests/03-istio.yaml." >&2
    exit 1
  }

  echo "Preserving existing healthy v1.30.3 mesh base with validated otel-tracing provider."
fi

echo "== 5. Mesh Telemetry =="
oc apply -f "${ROOT}/manifests/04-mesh-telemetry.yaml"

echo "== 6. Istio monitoring =="
oc apply -f "${ROOT}/manifests/05-istiod-servicemonitor.yaml"
for f in "${ROOT}"/rendered/06-istio-proxies-podmonitor-*.yaml; do
  oc apply -f "${f}"
done

echo "== 7. ODF object bucket =="
oc apply -f "${ROOT}/storage/odf/07-tempo-obc.yaml"
for _ in $(seq 1 120); do
  phase="$(
    oc get obc tempo-odf -n tempo \
      -o jsonpath='{.status.phase}' 2>/dev/null || true
  )"
  [[ "${phase}" == "Bound" ]] && break
  sleep 5
done
[[ "$(
  oc get obc tempo-odf -n tempo -o jsonpath='{.status.phase}'
)" == "Bound" ]] || {
  echo "ERROR: ObjectBucketClaim tempo/tempo-odf did not become Bound." >&2
  exit 1
}

echo "== 8. Tempo storage Secret =="
"${ROOT}/storage/odf/create-tempo-secret.sh"

echo "== 9. Tempo tenant roles =="
oc apply -f "${ROOT}/manifests/09-tempo-tenant-rbac.yaml"

echo "== 10. TempoStack =="
oc apply -f "${ROOT}/rendered/10-tempostack.yaml"
oc wait --for=condition=Ready tempostack/mesh \
  -n tempo --timeout=10m

echo "== 11. OTel ServiceAccount + Tempo writer binding =="
oc apply -f "${ROOT}/manifests/11-otel-rbac.yaml"

echo "== 12. OTel Collector =="
oc apply -f "${ROOT}/manifests/12-otel-collector.yaml"
oc wait --for=condition=Available deployment/otel-collector \
  -n istio-system --timeout=5m

echo "== 13. Kiali monitoring + Tempo reader bindings =="
oc apply -f "${ROOT}/manifests/13-kiali-rbac.yaml"

echo "== 14. Kiali =="
oc apply -f "${ROOT}/rendered/14-kiali.yaml"
oc wait --for=condition=Available deployment/kiali \
  -n istio-system --timeout=5m

echo "== 15. OpenShift distributed tracing UI =="
if [[ "${ENABLE_TRACING_UI:-1}" == "1" ]]; then
  oc apply -f "${ROOT}/optional/15-distributed-tracing-uiplugin.yaml"

  if [[ "${ENABLE_TRACING_UI_RBAC:-0}" == "1" ]]; then
    oc apply -f "${ROOT}/optional/15-tempo-console-reader-rbac.yaml"
  else
    echo "Tracing UI enabled without broad system:authenticated reader RBAC."
    echo "Users need GET permission on tempo.grafana.com/mesh resourceName=traces."
  fi
else
  echo "Skipped explicitly (ENABLE_TRACING_UI=0)."
fi

echo "== 16. Post-deployment validation =="
"${ROOT}/scripts/postcheck.sh"
