#!/usr/bin/env bash
# Install only missing OSSM 3.5 observability Operators. Never replaces an
# existing Subscription, OperatorGroup, or installed operator.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

[[ "${1:-}" == '--apply' && $# == 1 ]] || {
  echo "Usage: $0 --apply" >&2; exit 2;
}
for cmd in oc jq awk; do command -v "${cmd}" >/dev/null || { echo "ERROR: missing ${cmd}" >&2; exit 1; }; done
oc whoami >/dev/null
version="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
[[ "${version}" =~ ^5[.]0[.][0-9]+$ ]] || { echo "ERROR: expected OpenShift 5.0.x, got ${version}" >&2; exit 1; }
timeout="${OPERATOR_TIMEOUT_SECONDS:-1200}"
[[ "${timeout}" =~ ^[0-9]+$ && "${timeout}" -ge 120 ]] || { echo 'ERROR: OPERATOR_TIMEOUT_SECONDS must be >= 120.' >&2; exit 2; }

# Never create an operator in a namespace with a restricted or ambiguous scope.
check_global_group() {
  local ns="$1" groups
  groups="$(oc -n "${ns}" get operatorgroups.operators.coreos.com -o json)"
  jq -e '.items | length == 1 and ((.[0].spec.targetNamespaces // []) | length == 0) and (.[0].spec.selector == null)' <<<"${groups}" >/dev/null || {
    echo "ERROR: namespace ${ns} requires exactly one cluster-scoped OperatorGroup." >&2; return 1;
  }
}

csv_exists() {
  local regex="$1" csvs
  csvs="$(oc get csv -A --no-headers -o custom-columns=NAME:.metadata.name,PHASE:.status.phase)" || {
    echo 'ERROR: cannot list Operator CSVs; refusing to infer an absent operator.' >&2
    return 2
  }
  awk -v re="${regex}" '$1 ~ re {found=1} END {exit !found}' <<<"${csvs}"
}

subscription_ready() {
  local ns="$1" name="$2" regex="$3" sub csv phase
  sub="$(oc -n "${ns}" get subscription "${name}" -o json)" || return 2
  csv="$(jq -r '.status.installedCSV // empty' <<<"${sub}")"
  [[ -n "${csv}" ]] || return 1
  if ! awk -v re="${regex}" '$0 ~ re {found=1} END {exit !found}' <<<"${csv}"; then
    echo "ERROR: Subscription/${name} installed unsupported CSV ${csv}; inspect before proceeding." >&2
    return 2
  fi
  phase="$(oc -n "${ns}" get csv "${csv}" --ignore-not-found -o jsonpath='{.status.phase}')" || return 2
  [[ "${phase}" == 'Succeeded' ]]
}

# package;channel;required CSV regex. Keep these versions aligned with the
# strict gates in check-prereqs.sh. No unsupported catalog upgrade is assumed.
operators=(
  'servicemeshoperator3;stable-3.5;^servicemeshoperator3[.]v3[.]5[.];^servicemeshoperator3[.]v'
  'kiali-ossm;stable;^kiali-operator[.]v2[.]33[.];^kiali-operator[.]v'
  'opentelemetry-product;stable;^opentelemetry-operator[.]v0[.](152|158)[.];^opentelemetry-operator[.]v'
  'tempo-product;stable;^tempo-operator[.]v0[.]22[.];^tempo-operator[.]v'
)
if [[ "${ENABLE_TRACING_UI:-1}" == 1 ]]; then
  operators+=('cluster-observability-operator;stable;^cluster-observability-operator[.]v1[.];^cluster-observability-operator[.]v')
fi

for item in "${operators[@]}"; do
  IFS=';' read -r package channel strict_regex family_regex <<<"${item}"
  regex="${strict_regex}"
  [[ "${RELAX_VERSION_CHECKS:-0}" != 1 ]] || regex="${family_regex}"
  subscriptions="$(oc get subscriptions.operators.coreos.com -A -o json)"
  matching="$(jq --arg package "${package}" '[.items[] | select(.spec.name == $package)]' <<<"${subscriptions}")"
  count="$(jq 'length' <<<"${matching}")"
  (( count <= 1 )) || { echo "ERROR: multiple ${package} Subscriptions exist; inspect before proceeding." >&2; exit 1; }
  if (( count == 1 )); then
    ns="$(jq -r '.[0].metadata.namespace' <<<"${matching}")"
    subname="$(jq -r '.[0].metadata.name' <<<"${matching}")"
    check_global_group "${ns}"
    echo "OK   retaining existing Subscription/${package} in ${ns}"
  else
    result=0
    csv_exists "${family_regex}" || result=$?
    (( result != 2 )) || exit 1
    if (( result == 0 )); then
      echo "ERROR: ${package} CSV has no matching Subscription; inspect ownership before proceeding." >&2
      exit 1
    fi
    ns=openshift-operators
    subname="${package}"
    oc get namespace "${ns}" >/dev/null
    check_global_group "${ns}"
    catalog="$(oc -n openshift-marketplace get packagemanifests.packages.operators.coreos.com "${package}" -o json)"
    csv="$(jq -r --arg channel "${channel}" 'select(.status.catalogSource == "redhat-operators" and .status.catalogSourceNamespace == "openshift-marketplace") | .status.channels[]? | select(.name == $channel) | .currentCSV' <<<"${catalog}")"
    [[ -n "${csv}" ]] && awk -v re="${regex}" '$0 ~ re {found=1} END {exit !found}' <<<"${csv}" || {
      echo "ERROR: ${package}/${channel} has no expected compatible CSV in redhat-operators; refusing install." >&2; exit 1;
    }
    jq -n --arg name "${package}" --arg ns "${ns}" --arg channel "${channel}" '{apiVersion:"operators.coreos.com/v1alpha1",kind:"Subscription",metadata:{name:$name,namespace:$ns},spec:{channel:$channel,installPlanApproval:"Automatic",name:$name,source:"redhat-operators",sourceNamespace:"openshift-marketplace"}}' | oc create -f -
    echo "CREATED Subscription/${package} channel=${channel}"
  fi
  start=$SECONDS
  until subscription_ready "${ns}" "${subname}" "${regex}"; do
    result=$?
    (( result != 2 )) || exit 1
    if (( SECONDS - start >= timeout )); then
      echo "ERROR: timed out waiting for a compatible Succeeded CSV for ${package}; inspect OLM and retry." >&2
      exit 1
    fi
    sleep 5
  done
  echo "OK   ${package} CSV Succeeded"
done
