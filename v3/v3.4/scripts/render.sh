#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TEMPO_TENANT_ID:?Set TEMPO_TENANT_ID to a stable UUID}"
MESH_NAMESPACES="${MESH_NAMESPACES:-istio-system bookinfo}"
mkdir -p "$ROOT/rendered"; rm -f "$ROOT/rendered"/*.yaml
sed "s/__TEMPO_TENANT_ID__/${TEMPO_TENANT_ID}/g" "$ROOT/templates/07-tempostack.yaml.in" > "$ROOT/rendered/07-tempostack.yaml"
for ns in $MESH_NAMESPACES; do sed "s/__NAMESPACE__/${ns}/g" "$ROOT/templates/05-istio-proxies-podmonitor.yaml.in" > "$ROOT/rendered/05-istio-proxies-podmonitor-${ns}.yaml"; done
