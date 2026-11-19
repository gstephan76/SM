#!/usr/bin/env bash
# ODF 4.22 standalone MCG bootstrap for the v3.5 Tempo OBC path.
# Never deletes ODF resources, PVCs, buckets, or AWS credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

if [[ $# -gt 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi
for cmd in oc jq sed; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "ERROR: missing ${cmd}" >&2; exit 1; }
done

ns=openshift-storage
timeout="${MCG_TIMEOUT_SECONDS:-1200}"
[[ "${timeout}" =~ ^[0-9]+$ && "${timeout}" -ge 120 ]] || {
  echo 'ERROR: MCG_TIMEOUT_SECONDS must be an integer >= 120.' >&2; exit 2;
}

echo '== ODF 4.22 / standalone MCG bootstrap =='
oc whoami >/dev/null
ocp_version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
[[ "${ocp_version}" =~ ^5[.]0[.][0-9]+$ ]] || {
  echo "ERROR: ODF bootstrap targets OCP 5.0, got ${ocp_version:-unknown}" >&2; exit 1;
}
echo 'NOTE: ODF 4.22 on OCP 5.0 requires support qualification for this environment.'

# Preserve an already initialized gateway and its bound objects.
if "${ROOT}/storage/odf/check-mcg.sh" --quick >/dev/null 2>&1; then
  echo 'OK   existing NooBaa storage is healthy; nothing to install.'
  exit 0
fi

# Check all existing storage owners before considering the AWS-only bootstrap.
# An unhealthy external ODF installation must never be replaced or modified.
existing=""
for crd in storageclusters.ocs.openshift.io noobaas.noobaa.io; do
  crd_name="$(oc get crd "${crd}" --ignore-not-found -o name)" || {
    echo "ERROR: cannot inspect ${crd}; refusing storage bootstrap." >&2; exit 1;
  }
  [[ -n "${crd_name}" ]] || continue
  objects="$(oc -n "${ns}" get "${crd}" -o json)" || {
    echo "ERROR: cannot inspect existing ${crd}; refusing storage bootstrap." >&2; exit 1;
  }
  if [[ "${crd}" == storageclusters.ocs.openshift.io ]]; then
    if ! jq -e '(.items | length) <= 1 and all(.items[];
        .metadata.name == "ocs-storagecluster" and
        .spec.multiCloudGateway.reconcileStrategy == "standalone" and
        .spec.multiCloudGateway.dbStorageClassName == "gp3-csi")' <<<"${objects}" >/dev/null; then
      echo 'ERROR: existing storage is not the AWS standalone MCG installation; refusing changes.' >&2; exit 1
    fi
    existing="$(jq -c '.items[0] // empty' <<<"${objects}")"
  elif [[ -z "${existing}" ]] && ! jq -e '.items | length == 0' <<<"${objects}" >/dev/null; then
    echo 'ERROR: an existing NooBaa has no matching standalone StorageCluster; refusing changes.' >&2; exit 1
  fi
done
# The bootstrap manifest is explicitly AWS-specific. Existing healthy ODF on
# any platform was already accepted above and never reaches this step.
if ! oc get storageclass gp3-csi >/dev/null 2>&1; then
  echo 'ERROR: standalone MCG bootstrap requires AWS StorageClass gp3-csi; configure ODF/NooBaa for this platform first.' >&2
  exit 1
fi

oc create namespace "${ns}" --dry-run=client -o yaml | oc apply -f -

# An OperatorGroup is immutable in intent: do not rewrite one that targets a
# different namespace scope or allow conflicting operator groups.
og_json="$(oc -n "${ns}" get operatorgroup -o json)"
og_count="$(jq '.items | length' <<<"${og_json}")"
if [[ "${og_count}" == '0' ]]; then
  oc apply -f "${ROOT}/storage/odf/00-operatorgroup.yaml"
elif [[ "${og_count}" == '1' ]] && jq -e '
  .items[0].metadata.name == "openshift-storage" and
  .items[0].spec.targetNamespaces == ["openshift-storage"]' <<<"${og_json}" >/dev/null; then
  echo 'OK   existing ODF OperatorGroup matches expected namespace scope'
else
  echo 'ERROR: existing OperatorGroup configuration conflicts with ODF namespace contract.' >&2
  echo 'Refusing to change an existing OperatorGroup automatically.' >&2
  exit 1
fi

subscription="$(oc -n "${ns}" get subscription odf-operator -o json 2>/dev/null || true)"
if [[ -n "${subscription}" ]]; then
  if ! jq -e '.spec.channel == "stable-4.22" and .spec.name == "odf-operator" and
              .spec.source == "redhat-operators"' <<<"${subscription}" >/dev/null; then
    echo 'ERROR: existing odf-operator Subscription differs from the expected channel/source.' >&2
    exit 1
  fi
  echo 'OK   existing ODF 4.22 Subscription'
else
  channels="$(oc get packagemanifest odf-operator -n openshift-marketplace -o json |
    jq -r '.status.channels[]?.name')"
  grep -qx 'stable-4.22' <<<"${channels}" || {
    echo 'ERROR: the marketplace does not advertise ODF stable-4.22.' >&2; exit 1;
  }
  oc apply -f "${ROOT}/storage/odf/01-odf-subscription.yaml"
fi

start=$SECONDS
operator_ready() {
  oc -n "${ns}" get csv -o json 2>/dev/null | jq -e '
    . as $doc
    | ["odf-operator.v4.22.", "ocs-operator.v4.22.", "mcg-operator.v4.22."]
    | all(.[]; . as $prefix
      | any($doc.items[]; (.metadata.name | startswith($prefix)) and (.status.phase == "Succeeded")))
  ' >/dev/null 2>&1
}

while ! operator_ready; do
  if (( SECONDS - start >= timeout )); then
    echo 'ERROR: timed out waiting for ODF, OCS and MCG operators to Succeed.' >&2
    oc -n "${ns}" get csv >&2 || true
    exit 1
  fi
  sleep 5
done
echo 'OK   ODF, OCS and MCG CSVs Succeeded'

for crd in storageclusters.ocs.openshift.io noobaas.noobaa.io \
           objectbucketclaims.objectbucket.io backingstores.noobaa.io \
           bucketclasses.noobaa.io; do
  while ! oc get crd "${crd}" >/dev/null 2>&1; do
    if (( SECONDS - start >= timeout )); then
      echo "ERROR: CRD ${crd} did not become available." >&2; exit 1;
    fi
    sleep 5
  done
  oc wait --for=condition=Established "crd/${crd}" --timeout=120s >/dev/null
  echo "OK   CRD ${crd}"
done

if [[ -z "${existing}" ]]; then
  oc apply --dry-run=server -f "${ROOT}/storage/odf/02-mcg-storagecluster.yaml"
  oc apply -f "${ROOT}/storage/odf/02-mcg-storagecluster.yaml"
else
  echo 'OK   existing standalone StorageCluster retained without reconciliation changes'
fi

# Completion is defined by the actual data path: a Ready NooBaa gateway,
# healthy PV-backed backing store, bucket class, and OBC StorageClass.
# In this AWS cluster, a separate credentials request may fail because the
# cluster has no root aws-creds Secret; it must not block a healthy PV-pool.
while ! "${ROOT}/storage/odf/check-mcg.sh" --quick >/dev/null 2>&1; do
  if (( SECONDS - start >= timeout )); then
    echo 'ERROR: standalone MCG data path did not become healthy.' >&2
    "${ROOT}/storage/odf/check-mcg.sh" --quick >&2 || true
    oc -n "${ns}" get storagecluster,noobaa,backingstore,bucketclass,pvc,pods >&2 || true
    oc -n "${ns}" get events --sort-by=.lastTimestamp | tail -35 >&2 || true
    exit 1
  fi
  sleep 5
done
"${ROOT}/storage/odf/check-mcg.sh" --quick
