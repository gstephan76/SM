#!/usr/bin/env bash
set -euo pipefail

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}
need oc

if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: oc is not logged in" >&2
  exit 1
fi

required_crds=(
  istios.sailoperator.io
  istiocnis.sailoperator.io
  telemetries.telemetry.istio.io
  servicemonitors.monitoring.coreos.com
  podmonitors.monitoring.coreos.com
  opentelemetrycollectors.opentelemetry.io
  tempostacks.tempo.grafana.com
  kialis.kiali.io
)

failed=0
for crd in "${required_crds[@]}"; do
  if oc get crd "$crd" >/dev/null 2>&1; then
    printf 'OK   %s\n' "$crd"
  else
    printf 'MISS %s\n' "$crd" >&2
    failed=1
  fi
done

if oc get namespace openshift-user-workload-monitoring >/dev/null 2>&1; then
  echo "OK   openshift-user-workload-monitoring namespace exists"
else
  echo "MISS user workload monitoring does not appear to be enabled" >&2
  failed=1
fi

if (( failed != 0 )); then
  echo "ERROR: prerequisites are incomplete; install/enable them before applying this stack." >&2
  exit 1
fi
