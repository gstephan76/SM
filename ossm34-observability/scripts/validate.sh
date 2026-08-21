#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${1:-"$ROOT/.env"}
MODE=${2:---client}

case "$MODE" in
  --client) DRYRUN=client ;;
  --server) DRYRUN=server ;;
  *) echo "usage: $0 [env-file] [--client|--server]" >&2; exit 2 ;;
esac

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found" >&2; exit 1; }
"$ROOT/scripts/render.sh" "$ENV_FILE"

M="$ROOT/manifests"
R="$ROOT/rendered"

files=(
  "$M/00-namespaces.yaml"
  "$M/01-istio-cni.yaml"
  "$M/02-istio.yaml"
  "$M/03-mesh-telemetry.yaml"
  "$M/04-istiod-servicemonitor.yaml"
  "$M/08-otel-tempo-write-rbac.yaml"
  "$R/06-tempo-s3-secret.yaml"
  "$R/07-tempostack.yaml"
  "$M/09-otel-collector.yaml"
  "$M/10-kiali-monitoring-rbac.yaml"
  "$M/11-kiali-tempo-read-rbac.yaml"
  "$M/12-kiali.yaml"
)

for f in "${files[@]}"; do
  echo "VALIDATE $f"
  oc apply --dry-run="$DRYRUN" -f "$f" >/dev/null
done

echo "VALIDATE $M/05-istio-proxies-podmonitor.yaml (namespace=istio-system)"
oc -n istio-system apply --dry-run="$DRYRUN" -f "$M/05-istio-proxies-podmonitor.yaml" >/dev/null

echo "PASS: $DRYRUN dry-run validation"
