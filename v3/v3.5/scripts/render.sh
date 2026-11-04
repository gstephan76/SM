#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

: "${TEMPO_TENANT_ID:?Set TEMPO_TENANT_ID to one stable UUID in .env}"
MESH_NAMESPACES="${MESH_NAMESPACES:-istio-system bookinfo}"

if [[ ! "${TEMPO_TENANT_ID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
  echo "ERROR: TEMPO_TENANT_ID is not a valid RFC 4122 UUID: ${TEMPO_TENANT_ID}" >&2
  exit 1
fi

if [[ -z "${OPENSHIFT_CONSOLE_URL:-}" ]]; then
  console_host="$(
    oc get route console -n openshift-console \
      -o jsonpath='{.spec.host}' 2>/dev/null || true
  )"
  [[ -n "${console_host}" ]] || {
    echo "ERROR: could not discover openshift-console/console Route." >&2
    exit 1
  }
  OPENSHIFT_CONSOLE_URL="https://${console_host}"
fi

case "${OPENSHIFT_CONSOLE_URL}" in
  https://*) ;;
  *)
    echo "ERROR: OPENSHIFT_CONSOLE_URL must be an https:// URL: ${OPENSHIFT_CONSOLE_URL}" >&2
    exit 1
    ;;
esac

mkdir -p "${ROOT}/rendered"
rm -f "${ROOT}/rendered"/*.yaml

sed \
  "s/__TEMPO_TENANT_ID__/${TEMPO_TENANT_ID}/g" \
  "${ROOT}/templates/10-tempostack.yaml.in" \
  > "${ROOT}/rendered/10-tempostack.yaml"

sed \
  "s|__OPENSHIFT_CONSOLE_URL__|${OPENSHIFT_CONSOLE_URL}|g" \
  "${ROOT}/templates/14-kiali.yaml.in" \
  > "${ROOT}/rendered/14-kiali.yaml"

for ns in ${MESH_NAMESPACES}; do
  if [[ ! "${ns}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "ERROR: invalid Kubernetes namespace in MESH_NAMESPACES: ${ns}" >&2
    exit 1
  fi

  sed \
    "s/__NAMESPACE__/${ns}/g" \
    "${ROOT}/templates/06-istio-proxies-podmonitor.yaml.in" \
    > "${ROOT}/rendered/06-istio-proxies-podmonitor-${ns}.yaml"
done

echo "Rendered:"
find "${ROOT}/rendered" -maxdepth 1 -type f -name '*.yaml' -printf '  %f\n' | sort
