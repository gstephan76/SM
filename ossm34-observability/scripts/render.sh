#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${1:-"$ROOT/.env"}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  echo "Copy $ROOT/env.example to $ROOT/.env and edit it." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(TEMPO_TENANT_UUID S3_BUCKET S3_ENDPOINT S3_ACCESS_KEY_ID S3_ACCESS_KEY_SECRET)
for key in "${required[@]}"; do
  if [[ -z "${!key:-}" || "${!key}" == "CHANGE_ME" || "${!key}" == "00000000-0000-0000-0000-000000000000" ]]; then
    echo "ERROR: $key is not configured in $ENV_FILE" >&2
    exit 1
  fi
done

if [[ ! "$TEMPO_TENANT_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "ERROR: TEMPO_TENANT_UUID is not a UUID: $TEMPO_TENANT_UUID" >&2
  exit 1
fi

OUT="$ROOT/rendered"
mkdir -p "$OUT"
chmod 700 "$OUT"

python3 - "$ROOT" "$OUT" <<'PY'
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
out = Path(sys.argv[2])
keys = ["TEMPO_TENANT_UUID", "S3_BUCKET", "S3_ENDPOINT", "S3_ACCESS_KEY_ID", "S3_ACCESS_KEY_SECRET"]
values = {k: os.environ[k] for k in keys}

for src_name, dst_name in [
    ("06-tempo-s3-secret.yaml.in", "06-tempo-s3-secret.yaml"),
    ("07-tempostack.yaml.in", "07-tempostack.yaml"),
]:
    text = (root / "templates" / src_name).read_text()
    for key, value in values.items():
        text = text.replace("${" + key + "}", value.replace("\\", "\\\\").replace('"', '\\"'))
    (out / dst_name).write_text(text)

os.chmod(out / "06-tempo-s3-secret.yaml", 0o600)
os.chmod(out / "07-tempostack.yaml", 0o600)
PY

echo "Rendered manifests in $OUT"
