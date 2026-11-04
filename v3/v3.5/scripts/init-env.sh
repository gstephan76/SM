#!/usr/bin/env bash
# Create a v3.5 .env on a new cluster without resetting an existing tenant ID.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -e "${ROOT}/.env" ]]; then
  cp "${ROOT}/env.example" "${ROOT}/.env"
  chmod 0600 "${ROOT}/.env"
  echo 'Created .env from env.example'
fi
id="$(sed -n 's/^TEMPO_TENANT_ID=//p' "${ROOT}/.env" | head -1)"
if [[ -n "${id}" ]]; then
  echo "Existing TEMPO_TENANT_ID=${id} retained (not regenerated)"
  exit 0
fi
if command -v uuidgen >/dev/null 2>&1; then
  new_id="$(uuidgen)"
elif [[ -r /proc/sys/kernel/random/uuid ]]; then
  new_id="$(cat /proc/sys/kernel/random/uuid)"
else
  echo 'ERROR: neither uuidgen nor /proc/sys/kernel/random/uuid is available.' >&2
  exit 1
fi
if grep -q '^TEMPO_TENANT_ID=$' "${ROOT}/.env"; then
  sed -i "s/^TEMPO_TENANT_ID=$/TEMPO_TENANT_ID=${new_id}/" "${ROOT}/.env"
  echo "Generated stable TEMPO_TENANT_ID=${new_id}"
else
  echo 'ERROR: .env has no empty TEMPO_TENANT_ID= entry; refusing rewrite.' >&2
  exit 1
fi
