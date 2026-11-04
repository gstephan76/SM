#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="openshift-monitoring"
CM="cluster-monitoring-config"
MANIFEST="${ROOT}/manifests/01-user-workload-monitoring.yaml"

if ! oc get configmap "${CM}" -n "${NS}" >/dev/null 2>&1; then
  echo "Enabling user workload monitoring from manifests/01-user-workload-monitoring.yaml"
  oc apply -f "${MANIFEST}"
else
  cfg="$(
    oc get configmap "${CM}" \
      -n "${NS}" \
      -o jsonpath='{.data.config\.yaml}'
  )"

  if printf '%s\n' "${cfg}" |
      grep -Eq '^[[:space:]]*enableUserWorkload:[[:space:]]*true[[:space:]]*$'
  then
    echo "User workload monitoring is already enabled."
  else
    echo "ERROR: ${NS}/${CM} already exists but does not contain enableUserWorkload: true." >&2
    echo "Refusing to replace existing cluster-monitoring configuration because it may contain unrelated settings." >&2
    echo "Merge 'enableUserWorkload: true' into data.config.yaml, then rerun this script." >&2
    exit 1
  fi
fi

cfg="$(
  oc get configmap "${CM}" \
    -n "${NS}" \
    -o jsonpath='{.data.config\.yaml}'
)"
printf '%s\n' "${cfg}" |
  grep -Eq '^[[:space:]]*enableUserWorkload:[[:space:]]*true[[:space:]]*$' || {
    echo "ERROR: user workload monitoring did not remain enabled after reconciliation." >&2
    exit 1
  }

echo "OK   User workload monitoring enabled."
