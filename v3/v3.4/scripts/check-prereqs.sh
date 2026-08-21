#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

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

need_csv() {
  local label="$1"
  local regex="$2"
  if oc get csv -A --no-headers \
      -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null |
      awk -v re="${regex}" '$1 ~ re && $2 == "Succeeded" { found=1 } END { exit !found }'
  then
    echo "OK   operator/${label}"
  else
    echo "MISS operator/${label}"
    missing=1
  fi
}

for cmd in oc sed base64; do
  need_cmd "${cmd}"
done
(( missing == 0 )) || {
  echo "ERROR: required local commands are missing." >&2
  exit 1
}

oc whoami >/dev/null

ocp_version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
case "${ocp_version}" in
  4.22.*)
    echo "OK   OpenShift ${ocp_version}"
    ;;
  *)
    echo "MISS expected OpenShift 4.22.x; cluster reports '${ocp_version:-unknown}'"
    missing=1
    ;;
esac

# Bracketed dots avoid awk's warning about the non-standard \.-escape inside
# a string passed with -v while preserving the intended literal-dot regex.
need_csv "OpenShift Service Mesh 3.4" '^servicemeshoperator3[.]v3[.]4[.]'
need_csv "Kiali 2.27" '^kiali-operator[.]v2[.]27[.]'
need_csv "Red Hat OpenTelemetry 0.152" '^opentelemetry-operator[.]v0[.]152[.]'
need_csv "Tempo 0.21" '^tempo-operator[.]v0[.]21[.]'

for crd in \
  istios.sailoperator.io \
  istiocnis.sailoperator.io \
  telemetries.telemetry.istio.io \
  servicemonitors.monitoring.coreos.com \
  podmonitors.monitoring.coreos.com \
  opentelemetrycollectors.opentelemetry.io \
  tempostacks.tempo.grafana.com \
  kialis.kiali.io \
  objectbucketclaims.objectbucket.io
do
  need_crd "${crd}"
done

if oc get storageclass openshift-storage.noobaa.io >/dev/null 2>&1; then
  echo "OK   storageclass/openshift-storage.noobaa.io"
else
  echo "MISS storageclass/openshift-storage.noobaa.io"
  missing=1
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

if [[ "${ENABLE_TRACING_UI:-1}" == "1" ]]; then
  need_crd uiplugins.observability.openshift.io
else
  if oc get crd uiplugins.observability.openshift.io >/dev/null 2>&1; then
    echo "OK   optional crd/uiplugins.observability.openshift.io"
  else
    echo "WARN distributed-tracing UIPlugin disabled and its CRD is unavailable"
  fi
fi

(( missing == 0 )) || {
  echo "ERROR: OSSM 3.4 observability prerequisites are incomplete." >&2
  exit 1
}
