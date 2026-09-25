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
validate_readiness_compatibility_filters || {
  echo "ERROR: Kubernetes readiness compatibility filter self-test failed." >&2
  exit 1
}
validate_script_api_qualification "${ROOT}" || exit 1
"${ROOT}/scripts/render.sh"

for flag in APPLY_MESH_BASE ENABLE_MESH_CONSOLE ENABLE_TRACING_UI ENABLE_TRACING_UI_RBAC DEPLOY_BOOKINFO RUN_E2E; do
  value="${!flag:-}"
  [[ -z "${value}" || "${value}" == "0" || "${value}" == "1" ]] || {
    echo "ERROR: ${flag} must be 0 or 1; got '${value}'." >&2
    exit 1
  }
done
if [[ "${RUN_E2E:-1}" == "1" && "${DEPLOY_BOOKINFO:-1}" != "1" && -z "${TRACE_TEST_URL:-}" ]]; then
  echo "ERROR: RUN_E2E=1 requires DEPLOY_BOOKINFO=1 unless TRACE_TEST_URL explicitly points to another mesh application." >&2
  exit 1
fi

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
if [[ "${ENABLE_MESH_CONSOLE:-1}" == "1" ]]; then
  require_can_i create ossmconsoles.kiali.io -n openshift-operators
  require_can_i get consoleplugins.console.openshift.io
fi
require_can_i get routes.route.openshift.io -n openshift-console

if [[ "${DEPLOY_BOOKINFO:-1}" == "1" ]]; then
  require_can_i create deployments.apps -n bookinfo
  require_can_i create services -n bookinfo
  require_can_i create serviceaccounts -n bookinfo
  require_can_i create roles.rbac.authorization.k8s.io -n bookinfo
  require_can_i create rolebindings.rbac.authorization.k8s.io -n bookinfo
  require_can_i create gateways.networking.istio.io -n bookinfo
  require_can_i create virtualservices.networking.istio.io -n bookinfo
  require_can_i create routes.route.openshift.io -n bookinfo
  api_resource_exists gateways.networking.istio.io || {
    echo "ERROR: Istio Gateway API resource gateways.networking.istio.io is not discoverable." >&2
    exit 1
  }
  api_resource_exists virtualservices.networking.istio.io || {
    echo "ERROR: Istio VirtualService API resource virtualservices.networking.istio.io is not discoverable." >&2
    exit 1
  }
fi

if [[ "${ENABLE_TRACING_UI:-1}" == "1" ]]; then
  require_can_i create uiplugins.observability.openshift.io
fi

if [[ "${APPLY_MESH_BASE:-0}" != "1" ]]; then
  oc_get istiocni default -n istio-cni >/dev/null
  oc_get istio default -n istio-system >/dev/null

  cni_version="$(oc_get istiocni default -n istio-cni -o jsonpath='{.spec.version}')"
  istio_version="$(oc_get istio default -n istio-system -o jsonpath='{.spec.version}')"

  is_supported_istio_130_version "${cni_version}" || {
    echo "ERROR: existing IstioCNI spec.version=${cni_version}; expected v1.30.3 or v1.30.4." >&2
    exit 1
  }
  is_supported_istio_130_version "${istio_version}" || {
    echo "ERROR: existing Istio spec.version=${istio_version}; expected v1.30.3 or v1.30.4." >&2
    exit 1
  }

  provider_service="$(
    oc_get istio default -n istio-system \
      -o jsonpath='{.spec.values.meshConfig.extensionProviders[?(@.name=="otel-tracing")].opentelemetry.service}'
  )"
  provider_port="$(
    oc_get istio default -n istio-system \
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
  oc_get telemetry -n istio-system \
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

deferred_server_validation=0

validate_manifest() {
  local f="$1"
  local namespace="${2:-}"
  local rel="${f#${ROOT}/}"
  local output
  local -a nsargs=()
  [[ -z "${namespace}" ]] || nsargs=(-n "${namespace}")

  echo "server dry-run ${rel}${namespace:+ namespace=${namespace}}"
  if output="$(oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-30s}" apply --dry-run=server "${nsargs[@]}" -f "${f}" 2>&1)"; then
    return 0
  fi

  # A server dry-run of a namespaced object still requires the Namespace to
  # exist. On a brand-new cluster, 00-namespaces.yaml itself can be validated
  # server-side, but that dry-run does not persist istio-system/istio-cni/tempo/bookinfo.
  # Fall back only for this specific bootstrap condition. apply.sh will create
  # the namespaces and rerun validate.sh before applying any other resources.
  case "${output}" in
    *'namespaces "'*'" not found'*)
      echo "strict client dry-run ${rel} (target namespace absent; server validation deferred)"
      oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-30s}" apply --dry-run=client --validate=strict "${nsargs[@]}" -f "${f}" >/dev/null
      deferred_server_validation=1
      return 0
      ;;
  esac

  printf '%s\n' "${output}" >&2
  return 1
}

for f in "${ROOT}"/manifests/*.yaml; do
  validate_manifest "${f}"
done

validate_manifest "${ROOT}/storage/odf/07-tempo-obc.yaml"

for f in "${ROOT}"/rendered/*.yaml; do
  validate_manifest "${f}"
done

if [[ "${DEPLOY_BOOKINFO:-1}" == "1" ]]; then
  for f in "${ROOT}"/bookinfo/*.yaml; do
    validate_manifest "${f}" bookinfo
  done
fi

if [[ "${ENABLE_MESH_CONSOLE:-1}" == "1" ]]; then
  oc_get crd ossmconsoles.kiali.io >/dev/null 2>&1 || {
    echo "ERROR: Service Mesh console is enabled by default but OSSMConsole CRD is unavailable." >&2
    exit 1
  }
  validate_manifest "${ROOT}/optional/15-ossm-console.yaml"
fi

if [[ "${ENABLE_TRACING_UI:-1}" == "1" ]]; then
  oc_get crd uiplugins.observability.openshift.io >/dev/null 2>&1 || {
    echo "ERROR: tracing UI is enabled by default but UIPlugin CRD is unavailable." >&2
    exit 1
  }
  validate_manifest "${ROOT}/optional/15-distributed-tracing-uiplugin.yaml"

  if [[ "${ENABLE_TRACING_UI_RBAC:-0}" == "1" ]]; then
    validate_manifest "${ROOT}/optional/15-tempo-console-reader-rbac.yaml"
  fi
fi

if [[ "${deferred_server_validation}" == "1" ]]; then
  echo "Validation passed with namespace-dependent server checks deferred."
  echo "apply.sh will create only the target namespaces, then rerun full server-side validation before continuing."
else
  echo "Validation passed."
fi
