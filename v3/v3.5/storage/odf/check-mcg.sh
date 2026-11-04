#!/usr/bin/env bash
# Check the actual MCG object storage path used by Tempo, not just operator CSVs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

[[ "${1:-}" == "" || "${1:-}" == "--quick" ]] || {
  echo "Usage: $0 [--quick]" >&2; exit 2;
}

ns=openshift-storage
sc=openshift-storage.noobaa.io
expected_sc="$(sed -n 's/^[[:space:]]*dbStorageClassName:[[:space:]]*//p' "${ROOT}/storage/odf/02-mcg-storagecluster.yaml" | head -1)"

phase() {
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" -n "${ns}" \
    get "$1" "$2" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

fail=0
check_phase() {
  local type="$1" name="$2" expected="$3" got
  got="$(phase "$type" "$name")"
  if [[ "${got}" == "${expected}" ]]; then
    echo "OK   ${type}/${name} phase=${got}"
  else
    echo "MISS ${type}/${name}: phase=${got:-absent}; expected ${expected}" >&2
    fail=1
  fi
}

if oc get storageclass "${sc}" >/dev/null 2>&1; then
  echo "OK   storageclass/${sc}"
else
  echo "MISS storageclass/${sc}" >&2
  fail=1
fi

if oc get crd objectbucketclaims.objectbucket.io >/dev/null 2>&1; then
  echo 'OK   objectbucketclaims.objectbucket.io CRD'
else
  echo 'MISS objectbucketclaims.objectbucket.io CRD' >&2
  fail=1
fi

sc_phase="$(phase storageclusters.ocs.openshift.io ocs-storagecluster)"
case "${sc_phase}" in
  Ready)
    echo 'OK   StorageCluster/ocs-storagecluster phase=Ready'
    ;;
  Progressing)
    echo 'WARN StorageCluster/ocs-storagecluster still Progressing; checking actual NooBaa data path' >&2
    ;;
  *)
    echo "MISS StorageCluster/ocs-storagecluster phase=${sc_phase:-absent}" >&2
    fail=1
    ;;
esac
check_phase noobaas.noobaa.io noobaa Ready
check_phase backingstores.noobaa.io noobaa-default-backing-store Ready
check_phase bucketclasses.noobaa.io noobaa-default-bucket-class Ready

# A healthy NooBaa service alone is insufficient: ensure data goes to the
# PV-backed store that was actually tested on the fresh AWS cluster.
bs_type="$(oc -n "${ns}" get backingstores.noobaa.io noobaa-default-backing-store -o jsonpath='{.spec.type}' 2>/dev/null || true)"
bs_sc="$(oc -n "${ns}" get backingstores.noobaa.io noobaa-default-backing-store -o jsonpath='{.spec.pvPool.storageClass}' 2>/dev/null || true)"
if [[ "${bs_type}" == 'pv-pool' && "${bs_sc}" == "${expected_sc}" ]]; then
  echo "OK   backingstore pv-pool class=${bs_sc}"
else
  echo "MISS backingstore expected pv-pool/${expected_sc}; got type=${bs_type:-absent} class=${bs_sc:-absent}" >&2
  fail=1
fi

# Only backing-store data PVCs count; the PostgreSQL PVCs are unrelated.
pvc_count="$(oc -n "${ns}" get pvc -o json 2>/dev/null | jq -r '
  [.items[] | select(.metadata.name | startswith("noobaa-default-backing-store-"))
   | select(.status.phase == "Bound")] | length' 2>/dev/null || echo 0)"
if [[ "${pvc_count}" =~ ^[0-9]+$ && "${pvc_count}" -ge 1 ]]; then
  echo "OK   default backing-store Bound PVCs=${pvc_count}"
else
  echo 'MISS no Bound PVCs for default backing-store' >&2
  fail=1
fi

# An AWS CredentialsRequest can remain failed on the verified local PV-pool
# path. Report but do not fabricate aws-creds or require irrelevant S3 IAM.
if oc -n "${ns}" get credentialsrequests.cloudcredential.openshift.io noobaa-aws-cloud-creds >/dev/null 2>&1; then
  cred_failure="$(oc -n "${ns}" get credentialsrequests.cloudcredential.openshift.io noobaa-aws-cloud-creds -o json |
    jq -r '.status.conditions[]? | select(.type == "CredentialsProvisionFailure" and .status == "True") | .reason' || true)"
  if [[ -n "${cred_failure}" ]]; then
    echo "WARN NooBaa AWS CredentialsRequest: ${cred_failure} (not required for healthy PV-pool backing-store)" >&2
  fi
fi

if (( fail != 0 )); then
  echo 'ERROR: standalone MCG storage is not fully Ready.' >&2
  exit 1
fi

echo 'OK   standalone MCG is Ready with healthy PV-backed object storage.'
