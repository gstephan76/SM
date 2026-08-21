#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

for script in \
  "${ROOT}/scripts/"*.sh \
  "${ROOT}/storage/odf/"*.sh
do
  bash -n "${script}"
done

"${ROOT}/scripts/check-prereqs.sh"
"${ROOT}/scripts/render.sh"

require_can_i() {
  local verb="$1"
  local resource="$2"
  shift 2
  if [[ "$(oc auth can-i "${verb}" "${resource}" "$@")" != "yes" ]]; then
    echo "ERROR: current user cannot ${verb} ${resource} $*" >&2
    exit 1
  fi
}

require_can_i create namespaces
require_can_i create clusterroles.rbac.authorization.k8s.io
require_can_i create clusterrolebindings.rbac.authorization.k8s.io
require_can_i create configmaps -n openshift-monitoring
require_can_i create objectbucketclaims.objectbucket.io -n tempo
require_can_i create tempostacks.tempo.grafana.com -n tempo
require_can_i create opentelemetrycollectors.opentelemetry.io -n istio-system
require_can_i create kialis.kiali.io -n istio-system
require_can_i get routes.route.openshift.io -n openshift-console

if [[ "${ENABLE_TRACING_UI:-1}" == "1" ]]; then
  require_can_i create uiplugins.observability.openshift.io
fi

if [[ "${APPLY_MESH_BASE:-0}" != "1" ]]; then
  oc get istiocni default -n istio-cni >/dev/null
  oc get istio default -n istio-system >/dev/null

  [[ "$(oc get istiocni default -n istio-cni -o jsonpath='{.spec.version}')" == "v1.30.3" ]] || {
    echo "ERROR: existing IstioCNI is not pinned to v1.30.3." >&2
    exit 1
  }
  [[ "$(oc get istio default -n istio-system -o jsonpath='{.spec.version}')" == "v1.30.3" ]] || {
    echo "ERROR: existing Istio is not pinned to v1.30.3." >&2
    exit 1
  }

  provider_service="$(
    oc get istio default -n istio-system \
      -o jsonpath='{.spec.values.meshConfig.extensionProviders[?(@.name=="otel-tracing")].opentelemetry.service}'
  )"
  provider_port="$(
    oc get istio default -n istio-system \
      -o jsonpath='{.spec.values.meshConfig.extensionProviders[?(@.name=="otel-tracing")].opentelemetry.port}'
  )"
  [[ "${provider_service}" == "otel-collector.istio-system.svc.cluster.local" && "${provider_port}" == "4317" ]] || {
    echo "ERROR: existing Istio lacks the required otel-tracing provider." >&2
    echo "Expected otel-collector.istio-system.svc.cluster.local:4317." >&2
    echo "Set APPLY_MESH_BASE=1 to reconcile manifests/03-istio.yaml intentionally." >&2
    exit 1
  }
fi

existing="$(
  oc get telemetry -n istio-system \
    -o jsonpath='{range .items[?(!@.spec.selector)]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null || true
)"
if [[ -n "${existing}" ]] &&
   ! printf '%s\n' "${existing}" | grep -qx 'mesh-observability'
then
  echo "ERROR: another selectorless Telemetry exists in istio-system:" >&2
  printf '%s\n' "${existing}" >&2
  exit 1
fi

for f in "${ROOT}"/manifests/*.yaml; do
  echo "server dry-run ${f#${ROOT}/}"
  oc apply --dry-run=server -f "${f}" >/dev/null
done

echo "server dry-run storage/odf/07-tempo-obc.yaml"
oc apply --dry-run=server -f "${ROOT}/storage/odf/07-tempo-obc.yaml" >/dev/null

for f in "${ROOT}"/rendered/*.yaml; do
  echo "server dry-run ${f#${ROOT}/}"
  oc apply --dry-run=server -f "${f}" >/dev/null
done

if [[ "${ENABLE_TRACING_UI:-1}" == "1" ]]; then
  oc get crd uiplugins.observability.openshift.io >/dev/null 2>&1 || {
    echo "ERROR: tracing UI is enabled by default but UIPlugin CRD is unavailable." >&2
    exit 1
  }
  oc apply --dry-run=server \
    -f "${ROOT}/optional/15-distributed-tracing-uiplugin.yaml" >/dev/null

  if [[ "${ENABLE_TRACING_UI_RBAC:-0}" == "1" ]]; then
    oc apply --dry-run=server \
      -f "${ROOT}/optional/15-tempo-console-reader-rbac.yaml" >/dev/null
  fi
fi

echo "Validation passed."
