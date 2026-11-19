#!/usr/bin/env bash
# Verify the NooBaa storage path used by Tempo without changing it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --quick ) ]] || { echo "Usage: $0 [--quick]" >&2; exit 2; }
ns=openshift-storage
sc=openshift-storage.noobaa.io
fail=0
get_json() {
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" "$@" -o json
}
check_phase() {
  local resource="$1" name="$2" json
  if json="$(get_json -n "${ns}" get "${resource}" "${name}")" && jq -e '.status.phase == "Ready"' <<<"${json}" >/dev/null; then
    echo "OK   ${resource}/${name} phase=Ready"
  else
    echo "MISS ${resource}/${name}: not Ready or not accessible" >&2
    fail=1
  fi
}
if ! oc get crd objectbucketclaims.objectbucket.io >/dev/null; then
  echo 'MISS objectbucketclaims.objectbucket.io CRD' >&2; fail=1
else
  echo 'OK   objectbucketclaims.objectbucket.io CRD'
fi
if sc_json="$(get_json get storageclass "${sc}")" && jq -e '
  .provisioner == "openshift-storage.noobaa.io/obc" and
  .parameters.bucketclass == "noobaa-default-bucket-class"' <<<"${sc_json}" >/dev/null; then
  echo "OK   storageclass/${sc} points to the default NooBaa bucket class"
else
  echo "MISS storageclass/${sc}: incorrect provisioner or bucket class, or inaccessible" >&2; fail=1
fi
check_phase noobaas.noobaa.io noobaa
check_phase backingstores.noobaa.io noobaa-default-backing-store
check_phase bucketclasses.noobaa.io noobaa-default-bucket-class
if bucket_json="$(get_json -n "${ns}" get bucketclasses.noobaa.io noobaa-default-bucket-class)" && jq -e '
  [.spec.placementPolicy.tiers[]?.backingStores[]?] as $stores |
  ($stores | length) > 0 and all($stores[]; . == "noobaa-default-backing-store")' <<<"${bucket_json}" >/dev/null; then
  echo 'OK   default bucket class uses the verified backing store'
else
  echo 'MISS default bucket class does not exclusively use the verified backing store' >&2; fail=1
fi
if bs_json="$(get_json -n "${ns}" get backingstores.noobaa.io noobaa-default-backing-store)" && jq -e '
  .spec.type == "pv-pool" and (.spec.pvPool.storageClass | type == "string" and length > 0) and
  (.spec.pvPool.numVolumes | type == "number" and . >= 1 and floor == .)' <<<"${bs_json}" >/dev/null; then
  bs_sc="$(jq -r '.spec.pvPool.storageClass' <<<"${bs_json}")"
  count="$(jq -r '.spec.pvPool.numVolumes' <<<"${bs_json}")"
  if oc get storageclass "${bs_sc}" >/dev/null && pvc_json="$(get_json -n "${ns}" get pvc)" && jq -e --arg sc "${bs_sc}" --argjson count "${count}" '
    [.items[] | select(.metadata.name | startswith("noobaa-default-backing-store-"))] as $pvcs |
    ($pvcs | length) == $count and all($pvcs[];
      .status.phase == "Bound" and .spec.storageClassName == $sc and (.spec.volumeName | type == "string" and length > 0))' <<<"${pvc_json}" >/dev/null; then
    echo "OK   backing store pv-pool class=${bs_sc}; ${count} data PVCs Bound"
  else
    echo "MISS backing store class or data PVCs are inaccessible, incomplete, or not Bound to ${bs_sc}" >&2; fail=1
  fi
else
  echo 'MISS default backing store is not a configured PV pool or is inaccessible' >&2; fail=1
fi
if (( fail != 0 )); then
  echo 'ERROR: NooBaa object storage prerequisites are not fully Ready.' >&2; exit 1
fi
echo 'OK   existing NooBaa PV-backed object storage is Ready.'
echo 'NOTE Tempo bucket provisioning is verified when apply waits for its ObjectBucketClaim to become Bound.'
