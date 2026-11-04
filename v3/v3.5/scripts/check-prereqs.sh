#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"
parse_version_flags "$@"

missing=0

need_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "OK   command/$1"
  else
    echo "MISS command/$1"
    missing=1
  fi
}

need_crd() {
  if oc get crd "$1" >/dev/null 2>&1; then
    echo "OK   crd/$1"
  else
    echo "MISS crd/$1"
    missing=1
  fi
}

# An explicit compatibility override relaxes *version matching only*.
# An absent/non-Succeeded operator still fails, as do missing CRDs and storage.
need_csv() {
  local label="$1"
  local required_regex="$2"
  local family_regex="${3:-$2}"
  local csvs
  csvs="$(oc get csv -A --no-headers \
    -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null)" || {
    echo "MISS operator/${label} (could not list CSVs)"
    missing=1
    return
  }
  if awk -v re="${required_regex}" '$1 ~ re && $2 == "Succeeded" { found=1 } END { exit !found }' <<<"${csvs}"; then
    echo "OK   operator/${label}"
  elif [[ "${RELAX_VERSION_CHECKS:-0}" == "1" ]] &&
       awk -v re="${family_regex}" '$1 ~ re && $2 == "Succeeded" { found=1 } END { exit !found }' <<<"${csvs}"; then
    echo "WARN operator/${label}: compatible API/schema NOT verified; using other Succeeded family (--relax-version-checks)"
  else
    echo "MISS operator/${label}"
    missing=1
  fi
}

for cmd in oc sed base64 curl jq awk; do
  need_cmd "${cmd}"
done
((missing == 0)) || {
  echo "ERROR: required local commands are missing." >&2
  exit 1
}

oc whoami >/dev/null

ocp_version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
if [[ "${ocp_version}" =~ ^4[.]22[.][0-9]+$ ]]; then
  echo "OK   OpenShift ${ocp_version}"
else
  echo "MISS expected OpenShift 4.22.x; cluster reports '${ocp_version:-unknown}'"
  missing=1
fi

# Bracketed dots avoid awk's warning about the non-standard \.-escape inside
# a string passed with -v while preserving the intended literal-dot regex.
need_csv "OpenShift Service Mesh 3.5" '^servicemeshoperator3[.]v3[.]5[.]' '^servicemeshoperator3[.]v'
need_csv "Kiali 2.33" '^kiali-operator[.]v2[.]33[.]' '^kiali-operator[.]v'
need_csv "Red Hat OpenTelemetry 0.152.x or 0.158.x" '^opentelemetry-operator[.]v0[.](152|158)[.]' '^opentelemetry-operator[.]v'
need_csv "Tempo 0.22.x" '^tempo-operator[.]v0[.]22[.]' '^tempo-operator[.]v'

if api_resource_exists endpointslices.discovery.k8s.io; then
  echo "OK   api/endpointslices.discovery.k8s.io (preferred Service readiness source)"
else
  echo "WARN api/endpointslices.discovery.k8s.io unavailable; Service readiness will fall back to core/v1 Endpoints"
fi

for crd in \
  istios.sailoperator.io \
  istiocnis.sailoperator.io \
  telemetries.telemetry.istio.io \
  servicemonitors.monitoring.coreos.com \
  podmonitors.monitoring.coreos.com \
  opentelemetrycollectors.opentelemetry.io \
  tempostacks.tempo.grafana.com \
  kialis.kiali.io \
  gateways.networking.istio.io \
  virtualservices.networking.istio.io \
  objectbucketclaims.objectbucket.io; do
  need_crd "${crd}"
done

if oc get storageclass openshift-storage.noobaa.io >/dev/null 2>&1; then
  echo "OK   storageclass/openshift-storage.noobaa.io"
else
  echo "MISS storageclass/openshift-storage.noobaa.io"
  missing=1
fi

# OBC API existence alone cannot prove that a new NooBaa gateway can allocate
# Tempo buckets. This check also catches incomplete PV-pool provisioning.
if [[ "${CHECK_MCG_HEALTH:-1}" == "1" ]]; then
  if ! "${ROOT}/storage/odf/check-mcg.sh" --quick; then
    missing=1
  fi
fi

smcp="$(
  oc get servicemeshcontrolplane.maistra.io -A --no-headers 2>/dev/null || true
)"
if [[ -n "${smcp}" && "${ALLOW_OSSM2_COEXISTENCE:-0}" != "1" ]]; then
  echo "ERROR: active ServiceMeshControlPlane (OSSM 2) resources were found:" >&2
  printf '%s\n' "${smcp}" >&2
  echo "Set ALLOW_OSSM2_COEXISTENCE=1 only after intentionally reviewing coexistence." >&2
  exit 1
fi

if [[ "${ENABLE_MESH_CONSOLE:-1}" == "1" ]]; then
  need_crd ossmconsoles.kiali.io
else
  if oc get crd ossmconsoles.kiali.io >/dev/null 2>&1; then
    echo "OK   optional crd/ossmconsoles.kiali.io"
  else
    echo "WARN Service Mesh console disabled and OSSMConsole CRD is unavailable"
  fi
fi

if [[ "${ENABLE_TRACING_UI:-1}" == "1" ]]; then
  need_csv "Cluster Observability 1.x" '^cluster-observability-operator[.]v1[.]' '^cluster-observability-operator[.]v'
  need_crd uiplugins.observability.openshift.io
else
  if oc get crd uiplugins.observability.openshift.io >/dev/null 2>&1; then
    echo "OK   optional crd/uiplugins.observability.openshift.io"
  else
    echo "WARN distributed-tracing UIPlugin disabled and its CRD is unavailable"
  fi
fi

((missing == 0)) || {
  echo "ERROR: OSSM 3.5 observability prerequisites are incomplete." >&2
  exit 1
}
