#!/usr/bin/env bash
set -euo pipefail
NS=openshift-monitoring; CM=cluster-monitoring-config
if ! oc get cm "$CM" -n "$NS" >/dev/null 2>&1; then
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
exit 0
fi
cfg="$(oc get cm "$CM" -n "$NS" -o jsonpath='{.data.config\.yaml}')"
printf '%s\n' "$cfg" | grep -Eq '^[[:space:]]*enableUserWorkload:[[:space:]]*true[[:space:]]*$' && { echo "UWM already enabled"; exit 0; }
echo "ERROR: existing cluster-monitoring-config lacks enableUserWorkload: true; refusing to overwrite unrelated settings." >&2
exit 1
