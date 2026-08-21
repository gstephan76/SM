#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/check-prereqs.sh"
"$ROOT/scripts/render.sh"
for f in "$ROOT"/manifests/*.yaml "$ROOT"/storage/odf/00-tempo-obc.yaml "$ROOT"/rendered/*.yaml; do echo "dry-run ${f#${ROOT}/}"; oc apply --dry-run=server -f "$f" >/dev/null; done
echo "Validation passed."
