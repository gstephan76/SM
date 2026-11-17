#!/usr/bin/env bash

# Shared helpers for the OSSM 3.5 observability scripts.
# shellcheck shell=bash

load_stack_env() {
  local root="$1"
  local env_file="${root}/.env"
  local name
  local -A was_set=()
  local -A saved=()
  local vars=(
    TEMPO_TENANT_ID
    MESH_NAMESPACES
    TEMPO_NAMESPACE
    TEMPO_OBC_NAME
    TEMPO_STORAGE_SECRET
    TEMPO_S3_ENDPOINT
    BOOTSTRAP_MCG
    CHECK_MCG_HEALTH
    MCG_TIMEOUT_SECONDS
    APPLY_MESH_BASE
    ALLOW_OSSM2_COEXISTENCE
    RELAX_VERSION_CHECKS
    ENABLE_MESH_CONSOLE
    ENABLE_TRACING_UI
    ENABLE_TRACING_UI_RBAC
    OPENSHIFT_CONSOLE_URL
    TRACE_TEST_URL
    DEPLOY_BOOKINFO
    RUN_E2E
    E2E_REQUESTS
    E2E_FORCED_TRACES
    E2E_TRACE_WAIT_SECONDS
    E2E_MAX_HTTP_FAILURES
    E2E_MIN_RANDOM_TRACES
    E2E_MIN_METRIC_DELTA
    TEMPO_LOCAL_PORT
    THANOS_LOCAL_PORT
    KUBE_API_REQUEST_TIMEOUT
  )

  [[ -f "${env_file}" ]] || return 0

  # Preserve variables explicitly supplied by the caller. This makes:
  #   APPLY_MESH_BASE=1 ./scripts/validate.sh
  # override the value stored in .env, which is normal CLI precedence.
  for name in "${vars[@]}"; do
    if [[ -v "${name}" ]]; then
      was_set["${name}"]=1
      saved["${name}"]="${!name}"
    fi
  done

  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a

  for name in "${vars[@]}"; do
    if [[ "${was_set[${name}]:-0}" == "1" ]]; then
      printf -v "${name}" '%s' "${saved[${name}]}"
      export "${name}"
    fi
  done
}

tempo_sar_allowed() {
  local user="$1"
  local verb="$2"
  local allowed

  allowed="$(
    cat <<EOF | oc create -f - -o jsonpath='{.status.allowed}'
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: ${user}
  resourceAttributes:
    group: tempo.grafana.com
    resource: mesh
    name: traces
    verb: ${verb}
EOF
  )"

  [[ "${allowed}" == "true" ]]
}

require_tempo_sar() {
  local label="$1"
  local user="$2"
  local verb="$3"

  if tempo_sar_allowed "${user}" "${verb}"; then
    echo "OK   ${label}: ${verb} tempo.grafana.com/mesh resourceName=traces"
  else
    echo "ERROR: ${label} is not authorized for ${verb} on Tempo tenant mesh/traces." >&2
    exit 1
  fi
}

# v3.5 targets the Istio 1.31 family; the Sail Operator resolves the
# v1.31-latest alias to a supported patch. Preserve non-1.31 installations
# only with an explicit opt-in and still require the live CRs to be healthy.
is_supported_istio_target_version() {
  local version="${1:-}"
  if [[ "${version}" =~ ^v1[.]31([.][0-9]+|-latest)$ ]]; then
    return 0
  fi
  if [[ "${RELAX_VERSION_CHECKS:-0}" == "1" && "${version}" =~ ^v1[.][0-9]+([.][0-9]+|-latest)$ ]]; then
    echo "WARN allowing non-target Istio version ${version} (--relax-version-checks)" >&2
    return 0
  fi
  return 1
}

# A single common script parameter used by apply.sh, validate.sh and
# check-prereqs.sh; exported so nested script calls inherit the opt-in.
parse_version_flags() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --relax-version-checks)
        RELAX_VERSION_CHECKS=1
        export RELAX_VERSION_CHECKS
        ;;
      --strict-version-checks)
        RELAX_VERSION_CHECKS=0
        export RELAX_VERSION_CHECKS
        ;;
      *)
        echo "ERROR: unknown argument: ${arg}; accepted: --relax-version-checks, --strict-version-checks" >&2
        return 2
        ;;
    esac
  done
  case "${RELAX_VERSION_CHECKS:-0}" in
    0|1) ;;
    *) echo "ERROR: RELAX_VERSION_CHECKS must be 0 or 1" >&2; return 2 ;;
  esac
}


resource_args() {
  local namespace="$1"
  if [[ -n "${namespace}" ]]; then
    printf '%s\n' -n "${namespace}"
  fi
}

api_resource_exists() {
  local resource="$1"
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" api-resources -o name 2>/dev/null |
    awk -v wanted="${resource}" '$0 == wanted { found=1 } END { exit(found ? 0 : 1) }'
}

# Canonical resource references are always TYPE/NAME. TYPE may be a fully
# qualified API resource such as gateways.networking.istio.io. Never pass a
# combined fully-qualified TYPE/NAME string directly to `oc get`: kubectl/oc
# parsing is not consistent for that form. Split it and pass TYPE and NAME as
# separate argv entries.
validate_resource_ref() {
  local ref="$1"
  local type name

  [[ "${ref}" == */* ]] || {
    echo "ERROR: invalid resource reference '${ref}'; expected TYPE/NAME." >&2
    return 2
  }

  type="${ref%%/*}"
  name="${ref#*/}"
  [[ -n "${type}" && -n "${name}" && "${name}" != */* ]] || {
    echo "ERROR: invalid resource reference '${ref}'; expected exactly TYPE/NAME." >&2
    return 2
  }
}

resource_ref_type() {
  validate_resource_ref "$1" || return
  printf '%s\n' "${1%%/*}"
}

resource_ref_name() {
  validate_resource_ref "$1" || return
  printf '%s\n' "${1#*/}"
}

oc_apply() {
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-30s}" apply "$@"
}

oc_get() {
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get "$@"
}

oc_get_resource_ref() {
  local ref="$1"
  local namespace="${2:-}"
  shift 2 || true
  local type name
  local -a nsargs=()

  validate_resource_ref "${ref}" || return
  type="${ref%%/*}"
  name="${ref#*/}"
  [[ -z "${namespace}" ]] || nsargs=(-n "${namespace}")

  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" \
    get "${type}" "${name}" "${nsargs[@]}" "$@"
}

# Count selected pods that satisfy the canonical Kubernetes pod readiness
# predicate. Deleting/non-Running pods are never considered ready even if an
# old Ready=True condition is still present transiently.
pod_ready_count_from_json() {
  local json="$1"
  json_count_or_zero "${json}" '[.items[]? | select(.metadata.deletionTimestamp == null and .status.phase == "Running" and any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length'
}

# Kubernetes native sidecars are restartable init containers and therefore
# appear under initContainerStatuses. Classic sidecars appear under
# containerStatuses. Treat either location as authoritative.
pod_container_ready_count_from_json() {
  local json="$1"
  local container="$2"
  local value

  if value="$(jq -er --arg c "${container}" '[.items[]? | select((any(.status.containerStatuses[]?; .name == $c and (.ready == true))) or (any(.status.initContainerStatuses[]?; .name == $c and (.ready == true))))] | length' <<<"${json}" 2>/dev/null)" && [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${value}"
  else
    printf '0\n'
  fi
}

endpointslice_ready_count_from_json() {
  local json="$1"
  json_count_or_zero "${json}" '[.items[]?.endpoints[]? | select((.conditions.ready != false) and (.conditions.terminating != true)) | .addresses[]?] | length'
}

endpoints_ready_count_from_json() {
  local json="$1"
  json_count_or_zero "${json}" '[.subsets[]?.addresses[]?] | length'
}

cr_observed_generation_from_json() {
  local json="$1"
  local condition="$2"
  local condition_observed status_observed observed

  condition_observed="$(jq -r --arg c "${condition}" '[.status.conditions[]? | select(.type == $c)] | last | .observedGeneration // 0' <<<"${json}" 2>/dev/null || printf '0')"
  status_observed="$(jq -r '.status.observedGeneration // 0' <<<"${json}" 2>/dev/null || printf '0')"
  [[ "${condition_observed}" =~ ^[0-9]+$ ]] || condition_observed=0
  [[ "${status_observed}" =~ ^[0-9]+$ ]] || status_observed=0
  observed="${condition_observed}"
  (( status_observed > observed )) && observed="${status_observed}"
  printf '%s\n' "${observed}"
}

# Fast local regression for compatibility primitives. This deliberately covers
# classic/native sidecars, EndpointSlice/Endpoints, observedGeneration variants,
# and fully-qualified TYPE/NAME parsing.
validate_readiness_compatibility_filters() {
  local classic native mixed slices endpoints cr_condition cr_status
  classic='{"items":[{"metadata":{"name":"classic"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[{"name":"app","ready":true},{"name":"istio-proxy","ready":true}],"initContainerStatuses":[]}}]}'
  native='{"items":[{"metadata":{"name":"native"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[{"name":"app","ready":true}],"initContainerStatuses":[{"name":"istio-validation","ready":true},{"name":"istio-proxy","ready":true}]}}]}'
  mixed='{"items":[{"metadata":{"name":"classic"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[{"name":"istio-proxy","ready":true}]}},{"metadata":{"name":"native"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[],"initContainerStatuses":[{"name":"istio-proxy","ready":true}]}}]}'
  slices='{"items":[{"endpoints":[{"addresses":["10.0.0.1"],"conditions":{"ready":true}},{"addresses":["10.0.0.2"],"conditions":{}},{"addresses":["10.0.0.3"],"conditions":{"ready":false}},{"addresses":["10.0.0.4"],"conditions":{"ready":true,"terminating":true}}]}]}'
  endpoints='{"subsets":[{"addresses":[{"ip":"10.0.0.1"},{"ip":"10.0.0.2"}]}]}'
  cr_condition='{"status":{"conditions":[{"type":"Ready","status":"True","observedGeneration":5}]}}'
  cr_status='{"status":{"observedGeneration":6,"conditions":[{"type":"Ready","status":"True"}]}}'

  [[ "$(pod_ready_count_from_json "${classic}")" == "1" ]] || return 1
  [[ "$(pod_container_ready_count_from_json "${classic}" istio-proxy)" == "1" ]] || return 1
  [[ "$(pod_container_ready_count_from_json "${native}" istio-proxy)" == "1" ]] || return 1
  [[ "$(pod_container_ready_count_from_json "${mixed}" istio-proxy)" == "2" ]] || return 1
  [[ "$(endpointslice_ready_count_from_json "${slices}")" == "2" ]] || return 1
  [[ "$(endpoints_ready_count_from_json "${endpoints}")" == "2" ]] || return 1
  [[ "$(cr_observed_generation_from_json "${cr_condition}" Ready)" == "5" ]] || return 1
  [[ "$(cr_observed_generation_from_json "${cr_status}" Ready)" == "6" ]] || return 1
  [[ "$(resource_ref_type 'gateways.networking.istio.io/bookinfo-gateway')" == "gateways.networking.istio.io" ]] || return 1
  [[ "$(resource_ref_name 'gateways.networking.istio.io/bookinfo-gateway')" == "bookinfo-gateway" ]] || return 1
  [[ "$(resource_ref_type 'services/productpage')" == "services" ]] || return 1
  [[ "$(resource_ref_name 'services/productpage')" == "productpage" ]] || return 1
  if validate_resource_ref 'gateways.networking.istio.io/bookinfo-gateway/extra' >/dev/null 2>&1; then
    return 1
  fi
  echo "OK   readiness compatibility filters: sidecars, EndpointSlice/Endpoints, observedGeneration, TYPE/NAME parsing"
}

# Guard against the exact API-collision class found on OpenShift 4.22: both
# gateway.networking.k8s.io and networking.istio.io expose Kind=Gateway. The
# bare word `gateway` can therefore resolve to the wrong API group. Canonical
# scripts must use API-qualified resource names for Istio Gateway/VirtualService.
validate_script_api_qualification() {
  local root="$1"
  local output
  local -a scripts=(
    "${root}/scripts/apply.sh"
    "${root}/scripts/postcheck.sh"
    "${root}/scripts/e2e-check.sh"
  )

  output="$({
    awk '
      /wait_resource_exists[[:space:]]+"gateway\// ||
      /wait_resource_exists[[:space:]]+"virtualservice\// ||
      /oc[[:space:]]+get[[:space:]]+gateway([[:space:]]|$)/ ||
      /oc[[:space:]]+get[[:space:]]+virtualservice([[:space:]]|$)/ {
        print FILENAME ":" FNR ":" $0
        bad=1
      }
      END { exit bad ? 1 : 0 }
    ' "${scripts[@]}"
  } 2>&1)" || {
    echo "ERROR: ambiguous Istio Gateway/VirtualService resource alias found:" >&2
    printf '%s\n' "${output}" >&2
    echo "Use gateways.networking.istio.io and virtualservices.networking.istio.io explicitly." >&2
    return 1
  }

  if api_resource_exists gateways.networking.istio.io && api_resource_exists gateways.gateway.networking.k8s.io; then
    echo "OK   Gateway API collision detected and canonical scripts use explicit API groups"
  else
    echo "OK   canonical scripts use explicit Istio Gateway/VirtualService API groups"
  fi
}

dump_resource_diagnostics() {
  local resource="$1"
  local namespace="${2:-}"

  echo "--- diagnostics: ${resource}${namespace:+ namespace=${namespace}} ---" >&2
  oc_get_resource_ref "${resource}" "${namespace}" -o yaml >&2 2>/dev/null || true
  if [[ -n "${namespace}" ]]; then
    echo "--- recent events: ${namespace} ---" >&2
    oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get events -n "${namespace}" --sort-by='.lastTimestamp' 2>/dev/null | tail -80 >&2 || true
    echo "--- pods: ${namespace} ---" >&2
    oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get pods -n "${namespace}" -o wide >&2 2>/dev/null || true
  fi
}

wait_resource_exists() {
  local resource="$1"
  local namespace="${2:-}"
  local timeout_seconds="${3:-120}"
  local deadline=$((SECONDS + timeout_seconds))

  validate_resource_ref "${resource}" || return
  echo "Waiting for ${resource}${namespace:+ in ${namespace}} to exist..."
  while (( SECONDS < deadline )); do
    if oc_get_resource_ref "${resource}" "${namespace}" >/dev/null 2>&1; then
      echo "OK   ${resource}${namespace:+ in ${namespace}} exists"
      return 0
    fi
    sleep 2
  done

  echo "ERROR: timed out waiting for ${resource} to exist." >&2
  dump_resource_diagnostics "${resource}" "${namespace}"
  return 1
}

# Wait for an operator-managed CR condition and, where the condition reports an
# observedGeneration, require it to cover the current metadata.generation. This
# avoids accepting a stale Ready/Available condition after a spec update.
wait_cr_condition() {
  local resource="$1"
  local namespace="$2"
  local condition="$3"
  local timeout_seconds="${4:-300}"

  wait_resource_exists "${resource}" "${namespace}" "${timeout_seconds}"

  local deadline=$((SECONDS + timeout_seconds))
  local json generation status observed reason message
  echo "Waiting for ${resource} condition ${condition}=True${namespace:+ in ${namespace}}..."
  while (( SECONDS < deadline )); do
    json="$(oc_get_resource_ref "${resource}" "${namespace}" -o json 2>/dev/null || true)"
    if [[ -n "${json}" ]]; then
      generation="$(jq -r '.metadata.generation // 0' <<<"${json}")"
      status="$(jq -r --arg c "${condition}" '[.status.conditions[]? | select(.type == $c)] | last | .status // ""' <<<"${json}")"
      reason="$(jq -r --arg c "${condition}" '[.status.conditions[]? | select(.type == $c)] | last | .reason // ""' <<<"${json}")"
      message="$(jq -r --arg c "${condition}" '[.status.conditions[]? | select(.type == $c)] | last | .message // ""' <<<"${json}")"

      [[ "${generation}" =~ ^[0-9]+$ ]] || generation=0
      observed="$(cr_observed_generation_from_json "${json}" "${condition}")"

      if [[ "${status}" == "True" ]] && (( observed == 0 || observed >= generation )); then
        if (( observed > 0 )); then
          echo "OK   ${resource}: ${condition}=True generation=${generation} observedGeneration=${observed}"
        else
          echo "OK   ${resource}: ${condition}=True generation=${generation} (observedGeneration unavailable)"
        fi
        return 0
      fi
    fi
    sleep 2
  done

  echo "ERROR: ${resource} did not reach current ${condition}=True within ${timeout_seconds}s." >&2
  [[ -z "${reason:-}" ]] || echo "Last condition: reason=${reason} message=${message}" >&2
  dump_resource_diagnostics "${resource}" "${namespace}"
  return 1
}

wait_deployment_available() {
  local namespace="$1"
  local name="$2"
  local timeout_seconds="${3:-300}"
  local deadline=$((SECONDS + timeout_seconds))
  local json generation observed desired updated available unavailable
  local ref="deployments.apps/${name}"

  wait_resource_exists "${ref}" "${namespace}" "${timeout_seconds}"
  echo "Waiting for deployment ${namespace}/${name} to converge..."
  while (( SECONDS < deadline )); do
    json="$(oc_get_resource_ref "${ref}" "${namespace}" -o json 2>/dev/null || true)"
    if [[ -n "${json}" ]]; then
      generation="$(jq -r '.metadata.generation // 0' <<<"${json}")"
      observed="$(jq -r '.status.observedGeneration // 0' <<<"${json}")"
      desired="$(jq -r '.spec.replicas // 1' <<<"${json}")"
      updated="$(jq -r '.status.updatedReplicas // 0' <<<"${json}")"
      available="$(jq -r '.status.availableReplicas // 0' <<<"${json}")"
      unavailable="$(jq -r '.status.unavailableReplicas // 0' <<<"${json}")"

      for value in generation observed desired updated available unavailable; do
        [[ "${!value}" =~ ^[0-9]+$ ]] || printf -v "${value}" '%s' 0
      done

      if (( observed >= generation && updated == desired && available == desired && unavailable == 0 )); then
        echo "OK   deployment ${namespace}/${name}: generation=${generation} observedGeneration=${observed} updated=${updated}/${desired} available=${available}/${desired}"
        return 0
      fi
    fi
    sleep 2
  done

  echo "ERROR: deployment ${namespace}/${name} did not converge within ${timeout_seconds}s." >&2
  dump_resource_diagnostics "${ref}" "${namespace}"
  return 1
}

wait_namespace_active() {
  local namespace="$1"
  local timeout_seconds="${2:-120}"
  local deadline=$((SECONDS + timeout_seconds))
  local json phase deleting
  local ref="namespaces/${namespace}"

  echo "Waiting for namespace/${namespace} Active..."
  while (( SECONDS < deadline )); do
    json="$(oc_get_resource_ref "${ref}" "" -o json 2>/dev/null || true)"
    if [[ -n "${json}" ]]; then
      phase="$(jq -r '.status.phase // ""' <<<"${json}")"
      deleting="$(jq -r '(.metadata.deletionTimestamp != null) | tostring' <<<"${json}")"
      if [[ "${phase}" == "Active" && "${deleting}" == "false" ]]; then
        echo "OK   namespace/${namespace}: Active"
        return 0
      fi
    fi
    sleep 2
  done

  echo "ERROR: namespace/${namespace} did not become Active within ${timeout_seconds}s." >&2
  dump_resource_diagnostics "${ref}" ""
  return 1
}

wait_obc_bound() {
  local namespace="$1"
  local name="$2"
  local timeout_seconds="${3:-600}"
  local deadline=$((SECONDS + timeout_seconds))
  local phase=""
  local ref="objectbucketclaims.objectbucket.io/${name}"

  wait_resource_exists "${ref}" "${namespace}" "${timeout_seconds}"
  echo "Waiting for ObjectBucketClaim ${namespace}/${name} phase=Bound..."
  while (( SECONDS < deadline )); do
    phase="$(oc_get_resource_ref "${ref}" "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Bound" ]]; then
      echo "OK   ObjectBucketClaim ${namespace}/${name}: Bound"
      return 0
    fi
    sleep 3
  done
  echo "ERROR: ObjectBucketClaim ${namespace}/${name} did not become Bound; last phase=${phase:-unknown}." >&2
  dump_resource_diagnostics "${ref}" "${namespace}"
  return 1
}

wait_route_admitted() {
  local namespace="$1"
  local name="$2"
  local timeout_seconds="${3:-180}"
  local deadline=$((SECONDS + timeout_seconds))
  local json admitted host
  local ref="routes.route.openshift.io/${name}"

  wait_resource_exists "${ref}" "${namespace}" "${timeout_seconds}"
  echo "Waiting for Route ${namespace}/${name} admission..."
  while (( SECONDS < deadline )); do
    json="$(oc_get_resource_ref "${ref}" "${namespace}" -o json 2>/dev/null || true)"
    admitted="$(json_count_or_zero "${json}" '[.status.ingress[]?.conditions[]? | select(.type == "Admitted" and .status == "True")] | length')"
    host="$(jq -r '.spec.host // .status.ingress[0].host // ""' <<<"${json}" 2>/dev/null || true)"
    if [[ "${admitted}" != "0" && -n "${host}" ]]; then
      echo "OK   Route ${namespace}/${name}: admitted host=${host}"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: Route ${namespace}/${name} was not admitted." >&2
  dump_resource_diagnostics "${ref}" "${namespace}"
  return 1
}

json_count_or_zero() {
  local json="$1"
  local filter="$2"
  local value

  if value="$(jq -er "${filter}" <<<"${json}" 2>/dev/null)" && [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${value}"
  else
    printf '0\n'
  fi
}

require_console_plugin_backend() {
  local name="$1"
  local timeout_seconds="${2:-300}"
  local json service namespace
  local ref="consoleplugins.console.openshift.io/${name}"

  wait_resource_exists "${ref}" "" "${timeout_seconds}"
  json="$(oc_get_resource_ref "${ref}" "" -o json)"
  service="$(jq -r '.spec.backend.service.name // ""' <<<"${json}")"
  namespace="$(jq -r '.spec.backend.service.namespace // ""' <<<"${json}")"

  [[ -n "${service}" && -n "${namespace}" ]] || {
    echo "ERROR: ConsolePlugin/${name} does not reference a backend Service." >&2
    oc_get_resource_ref "${ref}" "" -o yaml >&2 || true
    return 1
  }

  require_service_endpoints "${namespace}" "${service}" "${timeout_seconds}"
  echo "OK   ConsolePlugin/${name}: backend=${namespace}/${service} has ready endpoints"
}

require_service_endpoints() {
  local namespace="$1"
  local service="$2"
  local timeout_seconds="${3:-180}"
  local deadline=$((SECONDS + timeout_seconds))
  local json addresses=0

  wait_resource_exists "services/${service}" "${namespace}" "${timeout_seconds}"
  echo "Waiting for Service ${namespace}/${service} ready backends..."
  while (( SECONDS < deadline )); do
    addresses=0

    if api_resource_exists endpointslices.discovery.k8s.io; then
      json="$(oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get endpointslices.discovery.k8s.io -n "${namespace}" -l "kubernetes.io/service-name=${service}" -o json 2>/dev/null || true)"
      addresses="$(endpointslice_ready_count_from_json "${json}")"
    fi

    if (( addresses == 0 )); then
      json="$(oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get endpoints "${service}" -n "${namespace}" -o json 2>/dev/null || true)"
      addresses="$(endpoints_ready_count_from_json "${json}")"
    fi

    if (( addresses > 0 )); then
      echo "OK   Service ${namespace}/${service}: ${addresses} ready backend address(es)"
      return 0
    fi
    sleep 2
  done

  echo "ERROR: Service ${namespace}/${service} has no ready backends." >&2
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get service "${service}" -n "${namespace}" -o yaml >&2 2>/dev/null || true
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get endpointslices.discovery.k8s.io -n "${namespace}" -l "kubernetes.io/service-name=${service}" -o yaml >&2 2>/dev/null || true
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get endpoints "${service}" -n "${namespace}" -o yaml >&2 2>/dev/null || true
  return 1
}

require_selector_pods_container() {
  local namespace="$1"
  local selector="$2"
  local container="$3"
  local timeout_seconds="${4:-180}"
  local deadline=$((SECONDS + timeout_seconds))
  local json total ready container_ready

  echo "Waiting for pods ${namespace} selector=${selector} to be Ready with container=${container}..."
  while (( SECONDS < deadline )); do
    json="$(oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get pods -n "${namespace}" -l "${selector}" -o json 2>/dev/null || true)"
    total="$(json_count_or_zero "${json}" '.items | length')"
    ready="$(pod_ready_count_from_json "${json}")"
    container_ready="$(pod_container_ready_count_from_json "${json}" "${container}")"

    if (( total > 0 && ready == total && container_ready == total )); then
      echo "OK   ${namespace} selector=${selector}: ${ready}/${total} pods Ready; ${container} Ready in regular or native-sidecar status"
      return 0
    fi
    sleep 2
  done

  echo "ERROR: pods ${namespace} selector=${selector} were not all Ready with container ${container}." >&2
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get pods -n "${namespace}" -l "${selector}" -o wide >&2 2>/dev/null || true
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get pods -n "${namespace}" -l "${selector}" -o json 2>/dev/null |
    jq -r --arg c "${container}" '.items[] | [.metadata.name, ("podReady=" + (([.status.conditions[]? | select(.type == "Ready") | .status] | last) // "missing")), ("containers=" + ([.status.containerStatuses[]? | (.name+":"+((.ready//false)|tostring))] | join(","))), ("initContainers=" + ([.status.initContainerStatuses[]? | (.name+":"+((.ready//false)|tostring))] | join(","))), ("requiredReady=" + (((any(.status.containerStatuses[]?; .name == $c and (.ready == true))) or (any(.status.initContainerStatuses[]?; .name == $c and (.ready == true)))) | tostring))] | @tsv' >&2 || true
  return 1
}

require_selector_pods_ready() {
  local namespace="$1"
  local selector="$2"
  local timeout_seconds="${3:-180}"
  local deadline=$((SECONDS + timeout_seconds))
  local json total ready

  echo "Waiting for pods ${namespace} selector=${selector} to be Ready..."
  while (( SECONDS < deadline )); do
    json="$(oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get pods -n "${namespace}" -l "${selector}" -o json 2>/dev/null || true)"
    total="$(json_count_or_zero "${json}" '.items | length')"
    ready="$(pod_ready_count_from_json "${json}")"
    if (( total > 0 && ready == total )); then
      echo "OK   ${namespace} selector=${selector}: ${ready}/${total} pods Ready"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: not all pods ${namespace} selector=${selector} became Ready." >&2
  oc --request-timeout="${KUBE_API_REQUEST_TIMEOUT:-15s}" get pods -n "${namespace}" -l "${selector}" -o wide >&2 2>/dev/null || true
  return 1
}

trace_service_names() {
  jq -r '.batches[]?.resource.attributes[]? | select(.key == "service.name") | .value.stringValue? // empty' "$1" | sort -u
}

trace_waypoint_destinations() {
  jq -r '.batches[]? |
    select(any(.resource.attributes[]?; .key == "service.name" and
      (.value.stringValue == "waypoint" or .value.stringValue == "waypoint.bookinfo"))) |
    .. | objects | select(.key? == "istio.destination_canonical_service") |
    .value.stringValue? // empty' "$1" | sort -u
}

has_service() {
  local services="$1" prefix="$2"
  grep -Eq "^${prefix}([.]bookinfo)?$" <<<"${services}"
}

trace_has_bookinfo_chain() {
  local file="$1" services destinations
  services="$(trace_service_names "${file}")"
  destinations="$(trace_waypoint_destinations "${file}")"
  has_service "${services}" bookinfo-ambient-istio &&
    has_service "${services}" waypoint &&
    has_service "${destinations}" productpage &&
    has_service "${destinations}" details &&
    has_service "${destinations}" reviews
}

require_ambient_bookinfo_routing() {
  local namespace="${1:-bookinfo}" timeout_seconds="${2:-180}"
  local deadline=$((SECONDS + timeout_seconds)) json
  wait_cr_condition "gateways.gateway.networking.k8s.io/waypoint" "${namespace}" Programmed "${timeout_seconds}"
  wait_cr_condition "gateways.gateway.networking.k8s.io/bookinfo-ambient" "${namespace}" Programmed "${timeout_seconds}"
  while (( SECONDS < deadline )); do
    json="$(oc_get httproutes.gateway.networking.k8s.io bookinfo-ambient -n "${namespace}" -o json 2>/dev/null || true)"
    if [[ -n "${json}" ]] && jq -e '
      .metadata.generation as $generation |
      any(.spec.parentRefs[]?; .name == "bookinfo-ambient") and
      any(.spec.rules[]?.backendRefs[]?; .name == "productpage" and .port == 9080) and
      any(.status.parents[]?;
        .parentRef.name == "bookinfo-ambient" and
        any(.conditions[]?; .type == "Accepted" and .status == "True" and .observedGeneration == $generation) and
        any(.conditions[]?; .type == "ResolvedRefs" and .status == "True" and .observedGeneration == $generation))
    ' <<<"${json}" >/dev/null 2>&1; then
      require_service_endpoints "${namespace}" bookinfo-ambient-istio "${timeout_seconds}"
      echo "OK   ambient Gateway and HTTPRoute are programmed with resolved references"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: Bookinfo HTTPRoute was not accepted with resolved references for its current generation." >&2
  return 1
}

gateway_hbone_enabled_from_json() {
  jq -e '(.items | length) > 0 and all(.items[];
    any(.spec.containers[]?; .name == "istio-proxy" and
      any(.env[]?; .name == "ISTIO_META_ENABLE_HBONE" and .value == "true")))' <<<"$1" >/dev/null 2>&1
}

ambient_pods_ready_from_json() {
  jq -e '
      (.items | length) > 0 and
      all(.items[]; .status.phase == "Running" and
        any(.status.conditions[]?; .type == "Ready" and .status == "True") and
        all((.spec.containers // [])[]; .name != "istio-proxy") and
        all((.spec.initContainers // [])[]; .name != "istio-proxy"))
    ' <<<"$1" >/dev/null 2>&1
}

require_ambient_pods() {
  local namespace="$1" selector="$2" timeout_seconds="${3:-180}"
  local deadline=$((SECONDS + timeout_seconds)) json
  while (( SECONDS < deadline )); do
    json="$(oc_get pods -n "${namespace}" -l "${selector}" -o json 2>/dev/null || true)"
    if [[ -n "${json}" ]] && ambient_pods_ready_from_json "${json}"; then
      echo "OK   ${namespace} selector=${selector}: ready application pods have no Istio sidecar"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: ${namespace} selector=${selector} does not have ready sidecar-free pods." >&2
  return 1
}

require_bookinfo_hbone() {
  local timeout_seconds="${1:-180}" deadline=$((SECONDS + ${1:-180}))
  local pods output pod missing
  command -v istioctl >/dev/null || { echo 'ERROR: istioctl is required to verify ambient workload registration.' >&2; return 1; }
  while (( SECONDS < deadline )); do
    pods="$(oc_get pods -n bookinfo -l 'app in (details,ratings,reviews,productpage)' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    output="$(istioctl ztunnel-config workloads --namespace ztunnel --workload-namespace bookinfo 2>/dev/null || true)"
    missing=0
    [[ -n "${pods}" && -n "${output}" ]] || missing=1
    while IFS= read -r pod; do
      [[ -z "${pod}" ]] && continue
      awk -v pod="${pod}" '$1 == "bookinfo" && $2 == pod && $NF == "HBONE" { found=1 } END { exit !found }' <<<"${output}" || missing=1
    done <<<"${pods}"
    if (( missing == 0 )); then
      echo 'OK   all Bookinfo application pods are registered with HBONE'
      return 0
    fi
    sleep 2
  done
  echo "ERROR: Bookinfo workloads did not all register with HBONE within ${timeout_seconds}s." >&2
  return 1
}

require_all_pods_ready() {
  local namespace="$1"
  local timeout_seconds="${2:-180}"
  local deadline=$((SECONDS + timeout_seconds))
  local json total ready

  echo "Waiting for all pods in ${namespace} to be Ready..."
  while (( SECONDS < deadline )); do
    json="$(oc_get pods -n "${namespace}" -o json 2>/dev/null || true)"
    total="$(json_count_or_zero "${json}" '.items | length')"
    ready="$(pod_ready_count_from_json "${json}")"
    if (( total > 0 && ready == total )); then
      echo "OK   ${namespace}: ${ready}/${total} pods Ready"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: not all pods in ${namespace} became Ready." >&2
  oc_get pods -n "${namespace}" -o wide >&2 2>/dev/null || true
  return 1
}
