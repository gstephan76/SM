#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"
parse_version_flags "$@"

CURRENT_APPLY_STEP="startup"
AMBIENT_MIGRATION_STARTED=0
apply_error_trap() {
  local rc=$?
  trap - ERR
  echo "ERROR: apply.sh failed during '${CURRENT_APPLY_STEP}' (rc=${rc}, line=${BASH_LINENO[0]:-unknown})." >&2
  exit "${rc}"
}
apply_exit_trap() {
  local rc=$?
  if (( rc != 0 )) && [[ "${AMBIENT_MIGRATION_STARTED}" == "1" ]]; then
    echo "Bookinfo migration may be partial. See ${ROOT}/AMBIENT-MIGRATION.md for manual recovery." >&2
  fi
}
begin_apply_step() {
  CURRENT_APPLY_STEP="$1"
  echo "== ${CURRENT_APPLY_STEP} =="
}
trap apply_error_trap ERR
trap apply_exit_trap EXIT

namespace_bootstrap_required=0
for ns in istio-system istio-cni ztunnel tempo bookinfo; do
  if ! oc_get namespace "${ns}" >/dev/null 2>&1; then
    namespace_bootstrap_required=1
    break
  fi
done

# ODF is intentionally opt-in: the ordinary deploy path must not mutate
# existing ODF operator subscriptions, persistent volumes, or StorageClusters.
if [[ "${BOOTSTRAP_MCG:-0}" == "1" ]]; then
  begin_apply_step "0. ODF 4.22 standalone MCG bootstrap"
  "${ROOT}/storage/odf/bootstrap-mcg.sh"
fi

"${ROOT}/scripts/validate.sh"

begin_apply_step "2. Namespaces"
oc_apply -f "${ROOT}/manifests/00-namespaces.yaml"
if ! oc_get namespace bookinfo >/dev/null 2>&1; then
  oc create namespace bookinfo
  oc label namespace bookinfo istio-discovery=enabled
fi
for ns in istio-system istio-cni ztunnel tempo bookinfo; do
  wait_namespace_active "${ns}" 120
done

if [[ "${namespace_bootstrap_required}" == "1" ]]; then
  begin_apply_step "2b. Full server-side validation after namespace bootstrap"
  "${ROOT}/scripts/validate.sh"
fi

begin_apply_step "3. User workload monitoring"
"${ROOT}/scripts/enable-uwm.sh"

begin_apply_step "4. IstioCNI + Istio"
if [[ "${APPLY_MESH_BASE:-0}" == "1" ]]; then
  oc_apply -f "${ROOT}/manifests/02-istio-cni.yaml"
  wait_cr_condition "istiocnis.sailoperator.io/default" istio-cni Ready 600

  oc_apply -f "${ROOT}/manifests/03-istio.yaml"
  wait_cr_condition "istios.sailoperator.io/default" istio-system Ready 600
  oc_apply -f "${ROOT}/manifests/03-ztunnel.yaml"
  wait_cr_condition "ztunnels.sailoperator.io/default" ztunnel Ready 600
else
  oc_get istiocni default -n istio-cni >/dev/null
  oc_get istio default -n istio-system >/dev/null

  cni_version="$(oc_get istiocni default -n istio-cni -o jsonpath='{.spec.version}')"
  istio_version="$(oc_get istio default -n istio-system -o jsonpath='{.spec.version}')"

  is_supported_istio_target_version "${cni_version}" || {
    echo "ERROR: existing IstioCNI spec.version=${cni_version}; expected Istio v1.31.x or v1.31-latest (override: --relax-version-checks)." >&2
    exit 1
  }
  is_supported_istio_target_version "${istio_version}" || {
    echo "ERROR: existing Istio spec.version=${istio_version}; expected Istio v1.31.x or v1.31-latest (override: --relax-version-checks)." >&2
    exit 1
  }

  wait_cr_condition "istiocnis.sailoperator.io/default" istio-cni Ready 180
  wait_cr_condition "istios.sailoperator.io/default" istio-system Ready 180
  wait_cr_condition "ztunnels.sailoperator.io/default" ztunnel Ready 180

  provider_service="$(
    oc_get istio default -n istio-system \
      -o jsonpath='{.spec.values.meshConfig.extensionProviders[?(@.name=="otel-tracing")].opentelemetry.service}'
  )"
  provider_port="$(
    oc_get istio default -n istio-system \
      -o jsonpath='{.spec.values.meshConfig.extensionProviders[?(@.name=="otel-tracing")].opentelemetry.port}'
  )"

  [[ "${provider_service}" == "otel-collector.istio-system.svc.cluster.local" && "${provider_port}" == "4317" ]] || {
    echo "ERROR: existing Istio does not define otel-tracing at the required endpoint." >&2
    echo "Set APPLY_MESH_BASE=1 to reconcile manifests/03-istio.yaml." >&2
    exit 1
  }

  echo "Preserving existing healthy ${istio_version} mesh base with validated otel-tracing provider."
fi

begin_apply_step "5. Mesh Telemetry"
oc_apply -f "${ROOT}/manifests/04-mesh-telemetry.yaml"
wait_resource_exists "telemetries.telemetry.istio.io/mesh-observability" istio-system 120

begin_apply_step "6. Istio monitoring"
oc_apply -f "${ROOT}/manifests/05-istiod-servicemonitor.yaml"
oc_apply -f "${ROOT}/manifests/06-ztunnel-podmonitor.yaml"
wait_resource_exists "podmonitors.monitoring.coreos.com/istio-ztunnel-monitor" ztunnel 120
wait_resource_exists "servicemonitors.monitoring.coreos.com/istiod-monitor" istio-system 120
for f in "${ROOT}"/rendered/06-istio-proxies-podmonitor-*.yaml; do
  oc_apply -f "${f}"
  ns="$(basename "${f}" .yaml | sed 's/^06-istio-proxies-podmonitor-//')"
  wait_resource_exists "podmonitors.monitoring.coreos.com/istio-proxies-monitor" "${ns}" 120
done

begin_apply_step "7. ODF object bucket"
oc_apply -f "${ROOT}/storage/odf/07-tempo-obc.yaml"
wait_obc_bound tempo tempo-odf 600

begin_apply_step "8. Tempo storage Secret"
"${ROOT}/storage/odf/create-tempo-secret.sh"

begin_apply_step "9. Tempo tenant roles"
oc_apply -f "${ROOT}/manifests/09-tempo-tenant-rbac.yaml"
wait_resource_exists "clusterroles.rbac.authorization.k8s.io/tempo-mesh-traces-writer" "" 120
wait_resource_exists "clusterroles.rbac.authorization.k8s.io/tempo-mesh-traces-reader" "" 120

begin_apply_step "10. TempoStack"
oc_apply -f "${ROOT}/rendered/10-tempostack.yaml"
wait_cr_condition "tempostacks.tempo.grafana.com/mesh" tempo Ready 900
require_selector_pods_ready tempo 'app.kubernetes.io/instance=mesh' 300
# Require the gateway Service separately because it is used by both OTel export
# and all trace queries.
require_service_endpoints tempo tempo-mesh-gateway 180

begin_apply_step "11. OTel ServiceAccount + Tempo writer binding"
oc_apply -f "${ROOT}/manifests/11-otel-rbac.yaml"
wait_resource_exists "serviceaccounts/otel-collector" istio-system 120
wait_resource_exists "clusterrolebindings.rbac.authorization.k8s.io/tempo-mesh-traces-writer-otel" "" 120

begin_apply_step "12. OTel Collector"
oc_apply -f "${ROOT}/manifests/12-otel-collector.yaml"
wait_cr_condition "opentelemetrycollectors.opentelemetry.io/otel" istio-system Ready 600
wait_deployment_available istio-system otel-collector 300
require_service_endpoints istio-system otel-collector 180

begin_apply_step "13. Kiali monitoring + Tempo reader bindings"
oc_apply -f "${ROOT}/manifests/13-kiali-rbac.yaml"
wait_resource_exists "clusterrolebindings.rbac.authorization.k8s.io/kiali-monitoring-rbac-v34" "" 120
wait_resource_exists "clusterrolebindings.rbac.authorization.k8s.io/tempo-mesh-traces-reader-kiali" "" 120

begin_apply_step "14. Kiali"
oc_apply -f "${ROOT}/rendered/14-kiali.yaml"
wait_cr_condition "kialis.kiali.io/kiali" istio-system Successful 600
wait_deployment_available istio-system kiali 300
require_service_endpoints istio-system kiali 180

begin_apply_step "15. OpenShift Service Mesh console plugin"
if [[ "${ENABLE_MESH_CONSOLE:-1}" == "1" ]]; then
  oc_apply -f "${ROOT}/optional/15-ossm-console.yaml"
  wait_cr_condition "ossmconsoles.kiali.io/ossmconsole" openshift-operators Successful 600
  require_console_plugin_backend ossmconsole 300
else
  echo "Skipped explicitly (ENABLE_MESH_CONSOLE=0)."
fi

begin_apply_step "16. OpenShift distributed tracing UI"
if [[ "${ENABLE_TRACING_UI:-1}" == "1" ]]; then
  oc_apply -f "${ROOT}/optional/15-distributed-tracing-uiplugin.yaml"
  wait_cr_condition "uiplugins.observability.openshift.io/distributed-tracing" "" Available 300

  if [[ "${ENABLE_TRACING_UI_RBAC:-0}" == "1" ]]; then
    oc_apply -f "${ROOT}/optional/15-tempo-console-reader-rbac.yaml"
    wait_resource_exists "clusterrolebindings.rbac.authorization.k8s.io/tempo-mesh-traces-reader-console" "" 120
  else
    echo "Tracing UI enabled without broad system:authenticated reader RBAC."
    echo "Users need GET permission on tempo.grafana.com/mesh resourceName=traces."
  fi
else
  echo "Skipped explicitly (ENABLE_TRACING_UI=0)."
fi

begin_apply_step "17. Bookinfo application and ingress gateway"
if [[ "${DEPLOY_BOOKINFO:-1}" == "1" ]]; then
  old_route_host="$(oc_get route istio-ingressgateway -n bookinfo -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  oc label namespace bookinfo istio-discovery=enabled --overwrite
  oc_apply -n bookinfo -f "${ROOT}/bookinfo/00-bookinfo.yaml"
  for deployment in details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3 productpage-v1; do
    wait_deployment_available bookinfo "${deployment}" 420
  done
  for service in details ratings reviews productpage; do
    require_service_endpoints bookinfo "${service}" 180
  done
  oc_apply -n bookinfo -f "${ROOT}/bookinfo/04-ambient-waypoint.yaml"
  oc_apply -n bookinfo -f "${ROOT}/bookinfo/05-ambient-ingress.yaml"
  require_ambient_bookinfo_routing bookinfo 420

  # A retained gateway injected before ambient was enabled must be re-injected
  # with HBONE before its backends are converted.
  if oc_get deployment istio-ingressgateway -n bookinfo >/dev/null 2>&1; then
    ingress_pods="$(oc_get pods -n bookinfo -l app.kubernetes.io/component=bookinfo-ingressgateway -o json)"
    if ! gateway_hbone_enabled_from_json "${ingress_pods}"; then
      oc rollout restart deployment istio-ingressgateway -n bookinfo
      wait_deployment_available bookinfo istio-ingressgateway 420
    fi
    ingress_pods="$(oc_get pods -n bookinfo -l app.kubernetes.io/component=bookinfo-ingressgateway -o json)"
    gateway_hbone_enabled_from_json "${ingress_pods}" || {
      echo 'ERROR: retained ingress does not have HBONE enabled after reinjection.' >&2
      exit 1
    }
    require_service_endpoints bookinfo istio-ingressgateway 180
  fi

  # Retain the old ingress resources. The old public Route remains in place
  # until the new Gateway and ambient application path have been checked.
  AMBIENT_MIGRATION_STARTED=1
  oc label service productpage -n bookinfo istio.io/ingress-use-waypoint=true --overwrite
  oc label namespace bookinfo istio-injection- --overwrite
  oc label namespace bookinfo istio.io/dataplane-mode=ambient istio.io/use-waypoint=waypoint --overwrite

  for app in details ratings reviews productpage; do
    pods="$(oc_get pods -n bookinfo -l "app=${app}" -o json)"
    if jq -e 'any(.items[]?; any((.spec.containers // [])[]; .name == "istio-proxy") or any((.spec.initContainers // [])[]; .name == "istio-proxy"))' <<<"${pods}" >/dev/null; then
      for deployment in $(oc_get deployments.apps -n bookinfo -l "app=${app}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
        oc rollout restart deployment "${deployment}" -n bookinfo
        wait_deployment_available bookinfo "${deployment}" 420
      done
    fi
    require_ambient_pods bookinfo "app=${app}" 240
  done
  require_bookinfo_hbone 180

  ratings_pod="$(oc_get pods -n bookinfo -l app=ratings -o jsonpath='{.items[0].metadata.name}')"
  gateway_body="$(oc exec -n bookinfo "${ratings_pod}" -c ratings -- \
    curl -fsS --max-time 20 http://bookinfo-ambient-istio.bookinfo.svc.cluster.local/productpage)"
  grep -Eq '<title>[^<]+</title>' <<<"${gateway_body}"
  grep -Eqi 'ISBN|Book Details' <<<"${gateway_body}"
  grep -Eqi 'Reviews|Book Reviews' <<<"${gateway_body}"
  oc_apply -n bookinfo -f "${ROOT}/bookinfo/03-route.yaml"
  wait_route_admitted bookinfo istio-ingressgateway 240
  new_route_host="$(oc_get route istio-ingressgateway -n bookinfo -o jsonpath='{.spec.host}')"
  if [[ -n "${old_route_host}" && "${new_route_host}" != "${old_route_host}" ]]; then
    echo 'ERROR: Bookinfo Route hostname changed during cutover.' >&2
    exit 1
  fi
else
  echo "Skipped explicitly (DEPLOY_BOOKINFO=0)."
fi

begin_apply_step "18. Post-deployment readiness validation"
"${ROOT}/scripts/postcheck.sh"

begin_apply_step "19. Final end-to-end validation"
if [[ "${RUN_E2E:-1}" == "1" ]]; then
  "${ROOT}/scripts/e2e-check.sh"
else
  echo "Skipped explicitly (RUN_E2E=0)."
fi
