#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

NAMESPACE="${TEMPO_NAMESPACE:-tempo}"
OBC_NAME="${TEMPO_OBC_NAME:-tempo-odf}"
TEMPO_SECRET="${TEMPO_STORAGE_SECRET:-tempostack-odf}"
TEMPO_S3_ENDPOINT="${TEMPO_S3_ENDPOINT:-https://s3.openshift-storage.svc}"

phase="$(
  oc get obc "${OBC_NAME}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true
)"
[[ "${phase}" == "Bound" ]] || {
  echo "ERROR: OBC ${NAMESPACE}/${OBC_NAME} is not Bound (phase=${phase:-unknown})." >&2
  exit 1
}

bucket="$(
  oc get configmap "${OBC_NAME}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.data.BUCKET_NAME}'
)"
bucket_host="$(
  oc get configmap "${OBC_NAME}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.data.BUCKET_HOST}'
)"
bucket_port="$(
  oc get configmap "${OBC_NAME}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.data.BUCKET_PORT}'
)"
access_key_id="$(
  oc get secret "${OBC_NAME}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' |
  base64 --decode
)"
access_key_secret="$(
  oc get secret "${OBC_NAME}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' |
  base64 --decode
)"

[[ -n "${bucket}" ]] || { echo "ERROR: ODF returned an empty BUCKET_NAME." >&2; exit 1; }
[[ -n "${bucket_host}" ]] || { echo "ERROR: ODF returned an empty BUCKET_HOST." >&2; exit 1; }
[[ -n "${bucket_port}" ]] || { echo "ERROR: ODF returned an empty BUCKET_PORT." >&2; exit 1; }
[[ -n "${access_key_id}" ]] || { echo "ERROR: ODF returned an empty AWS_ACCESS_KEY_ID." >&2; exit 1; }
[[ -n "${access_key_secret}" ]] || { echo "ERROR: ODF returned an empty AWS_SECRET_ACCESS_KEY." >&2; exit 1; }

echo "ODF bucket:"
echo "  name           = ${bucket}"
echo "  OBC host       = ${bucket_host}"
echo "  OBC port       = ${bucket_port}"
echo "  Tempo endpoint = ${TEMPO_S3_ENDPOINT}"

# Red Hat documents https://s3.openshift-storage.svc as the internal ODF
# endpoint for Tempo. The OBC supplies the bucket-specific account/key pair.
# Credentials are piped directly to oc and are never written to disk.
oc create secret generic "${TEMPO_SECRET}" \
  -n "${NAMESPACE}" \
  --from-literal=bucket="${bucket}" \
  --from-literal=endpoint="${TEMPO_S3_ENDPOINT}" \
  --from-literal=access_key_id="${access_key_id}" \
  --from-literal=access_key_secret="${access_key_secret}" \
  --dry-run=client \
  -o yaml |
oc apply -f -

echo "Tempo storage Secret ${NAMESPACE}/${TEMPO_SECRET} keys:"
oc get secret "${TEMPO_SECRET}" \
  -n "${NAMESPACE}" \
  -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}' |
sort
