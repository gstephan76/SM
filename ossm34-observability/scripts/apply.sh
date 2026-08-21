#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${1:-"$ROOT/.env"}

"$ROOT/scripts/check-prereqs.sh"
"$ROOT/scripts/render.sh" "$ENV_FILE"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

M="$ROOT/manifests"
R="$ROOT/rendered"

oc apply -f "$M/00-namespaces.yaml"
oc apply -f "$M/01-istio-cni.yaml"
oc apply -f "$M/02-istio.yaml"

# Monitoring objects can exist before workloads are ready.
oc apply -f "$M/04-istiod-servicemonitor.yaml"
oc -n istio-system apply -f "$M/05-istio-proxies-podmonitor.yaml"

for ns in ${MESH_NAMESPACES:-}; do
  if ! oc get namespace "$ns" >/dev/null 2>&1; then
    echo "ERROR: mesh namespace does not exist: $ns" >&2
    exit 1
  fi
  oc label namespace "$ns" istio-discovery=enabled istio-injection=enabled --overwrite
  oc -n "$ns" apply -f "$M/05-istio-proxies-podmonitor.yaml"
done

# Tempo storage, tenancy and authorization.
oc apply -f "$R/06-tempo-s3-secret.yaml"
oc apply -f "$M/08-otel-tempo-write-rbac.yaml"
oc apply -f "$R/07-tempostack.yaml"

# Trace transport.
oc apply -f "$M/09-otel-collector.yaml"

# Enable the mesh providers only after their receiver configuration exists.
oc apply -f "$M/03-mesh-telemetry.yaml"

# Kiali backend permissions and instance.
oc apply -f "$M/10-kiali-monitoring-rbac.yaml"
oc apply -f "$M/11-kiali-tempo-read-rbac.yaml"
oc apply -f "$M/12-kiali.yaml"

echo
echo "Applied OSSM 3.4 observability resources. Run:"
echo "  $ROOT/scripts/postcheck.sh $ENV_FILE"
