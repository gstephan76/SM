#!/usr/bin/env bash
set -euo pipefail
NAMESPACE="${TEMPO_NAMESPACE:-tempo}"
OBC_NAME="${TEMPO_OBC_NAME:-tempo-odf}"
TEMPO_SECRET="${TEMPO_STORAGE_SECRET:-tempostack-odf}"
phase="$(oc get obc "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "${phase}" == "Bound" ]] || { echo "ERROR: OBC ${NAMESPACE}/${OBC_NAME} is not Bound (phase=${phase:-unknown})." >&2; exit 1; }
bucket="$(oc get cm "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.BUCKET_NAME}')"
bucket_host="$(oc get cm "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.BUCKET_HOST}')"
bucket_port="$(oc get cm "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.BUCKET_PORT}')"
access_key_id="$(oc get secret "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 --decode)"
access_key_secret="$(oc get secret "${OBC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 --decode)"
[[ -n "${bucket}" && -n "${bucket_host}" && -n "${bucket_port}" && -n "${access_key_id}" && -n "${access_key_secret}" ]] || { echo "ERROR: ODF returned incomplete bucket data." >&2; exit 1; }
if [[ -n "${TEMPO_S3_ENDPOINT:-}" ]]; then endpoint="${TEMPO_S3_ENDPOINT}"; else case "${bucket_port}" in 443) endpoint="https://${bucket_host}" ;; 80) endpoint="http://${bucket_host}" ;; *) endpoint="https://${bucket_host}:${bucket_port}" ;; esac; fi
echo "ODF bucket=${bucket} endpoint=${endpoint}"
oc create secret generic "${TEMPO_SECRET}" -n "${NAMESPACE}" --from-literal=bucket="${bucket}" --from-literal=endpoint="${endpoint}" --from-literal=access_key_id="${access_key_id}" --from-literal=access_key_secret="${access_key_secret}" --dry-run=client -o yaml | oc apply -f -
oc get secret "${TEMPO_SECRET}" -n "${NAMESPACE}" -o go-template='{{range $key, $_ := .data}}{{printf "%s\n" $key}}{{end}}' | sort
