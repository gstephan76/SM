#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

for cmd in curl jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "ERROR: ${cmd} is required for the final E2E check." >&2
    exit 1
  }
done

E2E_REQUESTS="${E2E_REQUESTS:-200}"
E2E_FORCED_TRACES="${E2E_FORCED_TRACES:-12}"
E2E_TRACE_WAIT_SECONDS="${E2E_TRACE_WAIT_SECONDS:-180}"
E2E_MAX_HTTP_FAILURES="${E2E_MAX_HTTP_FAILURES:-0}"
TEMPO_LOCAL_PORT="${TEMPO_LOCAL_PORT:-18080}"
THANOS_LOCAL_PORT="${THANOS_LOCAL_PORT:-19091}"
E2E_MIN_RANDOM_TRACES="${E2E_MIN_RANDOM_TRACES:-5}"
E2E_MIN_METRIC_DELTA="${E2E_MIN_METRIC_DELTA:-100}"

for pair in \
  "E2E_REQUESTS:${E2E_REQUESTS}:100" \
  "E2E_FORCED_TRACES:${E2E_FORCED_TRACES}:3" \
  "E2E_TRACE_WAIT_SECONDS:${E2E_TRACE_WAIT_SECONDS}:30" \
  "E2E_MAX_HTTP_FAILURES:${E2E_MAX_HTTP_FAILURES}:0" \
  "E2E_MIN_RANDOM_TRACES:${E2E_MIN_RANDOM_TRACES}:1" \
  "E2E_MIN_METRIC_DELTA:${E2E_MIN_METRIC_DELTA}:1"; do
  IFS=: read -r name value minimum <<<"${pair}"
  [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge "${minimum}" ]] || {
    echo "ERROR: ${name} must be an integer >= ${minimum}." >&2
    exit 1
  }
done

if [[ -z "${TRACE_TEST_URL:-}" ]]; then
  route_host="$(oc get route istio-ingressgateway -n bookinfo -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -n "${route_host}" ]] || {
    echo "ERROR: TRACE_TEST_URL is unset and bookinfo/istio-ingressgateway Route has no host." >&2
    exit 1
  }
  TRACE_TEST_URL="http://${route_host}/productpage"
fi

case "${TRACE_TEST_URL}" in
  http://*|https://*) ;;
  *) echo "ERROR: TRACE_TEST_URL must be an http:// or https:// URL." >&2; exit 1 ;;
esac

echo "============================================================"
echo " Final OSSM 3.4 observability + Bookinfo E2E"
echo "============================================================"
echo "Bookinfo URL: ${TRACE_TEST_URL}"

# Fail early on incomplete installation/readiness. This also verifies every
# operator-managed CR and all Bookinfo workloads before generating traffic.
"${ROOT}/scripts/postcheck.sh"

require_tempo_sar \
  "otel-collector" \
  "system:serviceaccount:istio-system:otel-collector" \
  create
require_tempo_sar \
  "kiali-service-account" \
  "system:serviceaccount:istio-system:kiali-service-account" \
  get

e2e_start_rfc3339="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

work="$(mktemp -d)"
tempo_pf_pid=""
thanos_pf_pid=""
cleanup() {
  for pid in "${tempo_pf_pid}" "${thanos_pf_pid}"; do
    if [[ -n "${pid}" ]]; then
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  rm -rf "${work}"
}
trap cleanup EXIT

curl_bookinfo() {
  local output="$1"
  shift
  curl -q --silent --show-error --location \
    --connect-timeout 5 --max-time 20 \
    -o "${output}" -w '%{http_code}' \
    "$@" "${TRACE_TEST_URL}"
}

validate_bookinfo_body() {
  local body="$1"
  grep -Eq '<title>[^<]+</title>' "${body}" &&
    grep -Eqi 'ISBN|Book Details' "${body}" &&
    grep -Eqi 'Reviews|Book Reviews' "${body}"
}

start_port_forward() {
  local namespace="$1"
  local resource="$2"
  local mapping="$3"
  local log="$4"
  local __pidvar="$5"
  local pid

  oc -n "${namespace}" port-forward "${resource}" "${mapping}" >"${log}" 2>&1 &
  pid=$!
  printf -v "${__pidvar}" '%s' "${pid}"

  for _ in $(seq 1 30); do
    grep -q 'Forwarding from' "${log}" && return 0
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      cat "${log}" >&2
      echo "ERROR: port-forward ${namespace}/${resource} exited early." >&2
      return 1
    fi
    sleep 1
  done
  cat "${log}" >&2
  echo "ERROR: port-forward ${namespace}/${resource} did not become ready." >&2
  return 1
}

query_thanos_bookinfo_metric() {
  local token="$1"
  local response="$2"
  local query='sum(istio_requests_total{destination_service_namespace="bookinfo"})'
  local code value

  code="$(curl -q --silent --show-error --insecure --get \
    -o "${response}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    --data-urlencode "query=${query}" \
    "https://127.0.0.1:${THANOS_LOCAL_PORT}/api/v1/query" || true)"
  [[ "${code}" == "200" ]] || return 1
  value="$(jq -r '.data.result[0].value[1] // "0"' "${response}" 2>/dev/null || true)"
  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || value=0
  printf '%s\n' "${value}"
}

new_trace_id() {
  tr -d '-' </proc/sys/kernel/random/uuid
}

new_span_id() {
  local id
  id="$(tr -d '-' </proc/sys/kernel/random/uuid)"
  printf '%s' "${id:0:16}"
}

trace_service_names() {
  jq -r '.. | objects | select(.key? == "service.name") | .value.stringValue? // empty' "$1" | sort -u
}

has_service() {
  local services="$1"
  local prefix="$2"
  grep -Eq "^${prefix}([.]bookinfo)?$" <<<"${services}"
}

echo "== E2E 1/8: external Bookinfo application response =="
body="${work}/productpage.html"
code="$(curl_bookinfo "${body}" || true)"
[[ "${code}" == "200" ]] || {
  echo "ERROR: Bookinfo external productpage returned HTTP ${code}." >&2
  head -80 "${body}" >&2 || true
  exit 1
}
validate_bookinfo_body "${body}" || {
  echo "ERROR: productpage returned HTTP 200 but did not contain expected Bookinfo content." >&2
  head -80 "${body}" >&2
  exit 1
}
echo "OK   external productpage HTTP 200 with Bookinfo content"

echo "== E2E 2/8: in-mesh Bookinfo service call =="
ratings_pod="$(oc get pod -n bookinfo -l app=ratings -o jsonpath='{.items[0].metadata.name}')"
internal_body="${work}/internal-productpage.html"
oc exec -n bookinfo "${ratings_pod}" -c ratings -- \
  curl -sS --max-time 20 http://productpage:9080/productpage >"${internal_body}"
validate_bookinfo_body "${internal_body}" || {
  echo "ERROR: in-mesh ratings -> productpage request did not return expected Bookinfo content." >&2
  head -80 "${internal_body}" >&2
  exit 1
}
echo "OK   in-mesh ratings -> productpage service request"

echo "== E2E 3/8: normal 10% sampling traffic =="
# Take a metric baseline before the generated load. Requiring only a positive
# historical counter could otherwise let stale traffic satisfy the metrics gate.
start_port_forward openshift-monitoring svc/thanos-querier "${THANOS_LOCAL_PORT}:9091" "${work}/thanos-pf.log" thanos_pf_pid
metric_token="$(oc create token kiali-service-account -n istio-system --duration=10m)"
metric_before_file="${work}/thanos-before.json"
metric_before="$(query_thanos_bookinfo_metric "${metric_token}" "${metric_before_file}" || echo 0)"
[[ "${metric_before}" =~ ^[0-9]+([.][0-9]+)?$ ]] || metric_before=0
echo "Bookinfo istio_requests_total baseline: ${metric_before}"

normal_start="$(( $(date +%s) - 2 ))"
http_failures=0
for i in $(seq 1 "${E2E_REQUESTS}"); do
  request_body="${work}/normal-${i}.html"
  code="$(curl_bookinfo "${request_body}" || true)"
  if [[ "${code}" != "200" ]]; then
    http_failures=$((http_failures + 1))
  fi
done
normal_end="$(date +%s)"
echo "HTTP failures: ${http_failures}/${E2E_REQUESTS}"
(( http_failures <= E2E_MAX_HTTP_FAILURES )) || {
  echo "ERROR: Bookinfo exceeded E2E_MAX_HTTP_FAILURES=${E2E_MAX_HTTP_FAILURES}." >&2
  exit 1
}
# Separate the random-sampling window from the forced-sampling control window.
sleep 2

echo "== E2E 4/8: forced-sampling positive controls and no-sample negative control =="
unsampled_trace_id="$(new_trace_id)"
unsampled_span_id="$(new_span_id)"
control_body="${work}/unsampled.html"
code="$(curl_bookinfo "${control_body}" \
  -H "x-b3-traceid: ${unsampled_trace_id}" \
  -H "x-b3-spanid: ${unsampled_span_id}" \
  -H 'x-b3-sampled: 0' || true)"
[[ "${code}" == "200" ]] || {
  echo "ERROR: unsampled control request returned HTTP ${code}." >&2
  exit 1
}

declare -a forced_trace_ids=()
for i in $(seq 1 "${E2E_FORCED_TRACES}"); do
  trace_id="$(new_trace_id)"
  span_id="$(new_span_id)"
  forced_trace_ids+=("${trace_id}")
  forced_body="${work}/forced-${trace_id}.html"
  code="$(curl_bookinfo "${forced_body}" \
    -H "x-b3-traceid: ${trace_id}" \
    -H "x-b3-spanid: ${span_id}" \
    -H 'x-b3-sampled: 1' || true)"
  [[ "${code}" == "200" ]] || {
    echo "ERROR: forced trace ${trace_id} returned HTTP ${code}." >&2
    exit 1
  }
  validate_bookinfo_body "${forced_body}" || {
    echo "ERROR: forced trace ${trace_id} did not return valid Bookinfo content." >&2
    exit 1
  }
done
echo "OK   ${#forced_trace_ids[@]} exact trace IDs injected with x-b3-sampled=1"

echo "== E2E 5/8: exact Tempo trace retrieval and distributed service-chain validation =="
token="$(oc create token kiali-service-account -n istio-system --duration=15m)"
start_port_forward tempo svc/tempo-mesh-gateway "${TEMPO_LOCAL_PORT}:8080" "${work}/tempo-pf.log" tempo_pf_pid

trace_base="https://127.0.0.1:${TEMPO_LOCAL_PORT}/api/traces/v1/mesh/tempo/api/traces"
search_url="https://127.0.0.1:${TEMPO_LOCAL_PORT}/api/traces/v1/mesh/tempo/api/search"
full_chain_count=0
found_count=0

for trace_id in "${forced_trace_ids[@]}"; do
  trace_file="${work}/trace-${trace_id}.json"
  deadline=$((SECONDS + E2E_TRACE_WAIT_SECONDS))
  complete=0
  last_code=""
  services=""

  while (( SECONDS < deadline )); do
    last_code="$(curl -q --silent --show-error --insecure \
      -o "${trace_file}" -w '%{http_code}' \
      -H "Authorization: Bearer ${token}" \
      "${trace_base}/${trace_id}" || true)"

    if [[ "${last_code}" == "200" ]] && jq -e '.batches? | length > 0' "${trace_file}" >/dev/null 2>&1; then
      services="$(trace_service_names "${trace_file}")"
      if has_service "${services}" istio-ingressgateway &&
         has_service "${services}" productpage &&
         has_service "${services}" details &&
         has_service "${services}" reviews; then
        complete=1
        break
      fi
    elif [[ "${last_code}" != "404" && "${last_code}" != "200" && -n "${last_code}" ]]; then
      echo "ERROR: Tempo trace lookup ${trace_id} returned HTTP ${last_code}." >&2
      cat "${trace_file}" >&2 2>/dev/null || true
      exit 1
    fi
    sleep 3
  done

  if [[ "${complete}" != "1" ]]; then
    echo "ERROR: exact trace ${trace_id} did not become a complete ingress->productpage->details/reviews distributed trace." >&2
    echo "Last HTTP code: ${last_code:-none}" >&2
    echo "Observed services:" >&2
    printf '%s\n' "${services:-<none>}" >&2
    [[ ! -s "${trace_file}" ]] || head -100 "${trace_file}" >&2
    exit 1
  fi

  found_count=$((found_count + 1))
  if has_service "${services}" ratings; then
    full_chain_count=$((full_chain_count + 1))
  fi
  echo "OK   trace ${trace_id}: $(tr '\n' ',' <<<"${services}" | sed 's/,$//')"
done

[[ "${found_count}" -eq "${E2E_FORCED_TRACES}" ]] || {
  echo "ERROR: only ${found_count}/${E2E_FORCED_TRACES} forced exact traces were validated." >&2
  exit 1
}
(( full_chain_count >= 1 )) || {
  echo "ERROR: no exact forced trace included ratings; the full productpage -> reviews -> ratings path was not proven." >&2
  exit 1
}
echo "OK   ${found_count}/${E2E_FORCED_TRACES} exact forced traces found; ${full_chain_count} included ratings"

# x-b3-sampled=0 is a negative control: a prior no-sample decision should be
# respected by Istio. Check after positive traces have had time to appear.
negative_file="${work}/negative-trace.json"
negative_code="$(curl -q --silent --show-error --insecure \
  -o "${negative_file}" -w '%{http_code}' \
  -H "Authorization: Bearer ${token}" \
  "${trace_base}/${unsampled_trace_id}" || true)"
case "${negative_code}" in
  404)
    ;;
  200)
    if jq -e '.batches? | length > 0' "${negative_file}" >/dev/null 2>&1; then
      echo "ERROR: x-b3-sampled=0 negative-control trace ${unsampled_trace_id} was stored unexpectedly." >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: negative-control Tempo lookup returned unexpected HTTP ${negative_code:-transport-failure}." >&2
    cat "${negative_file}" >&2 2>/dev/null || true
    exit 1
    ;;
esac
echo "OK   x-b3-sampled=0 negative control was not stored"

echo "== E2E 6/8: random-sampling search window =="
random_response="${work}/random-search.json"
deadline=$((SECONDS + E2E_TRACE_WAIT_SECONDS))
random_count=0
while (( SECONDS < deadline )); do
  search_code="$(curl -q --silent --show-error --insecure --get \
    -o "${random_response}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    --data-urlencode 'q={ resource.service.name = "istio-ingressgateway.bookinfo" }' \
    --data-urlencode 'limit=100' \
    --data-urlencode "start=${normal_start}" \
    --data-urlencode "end=${normal_end}" \
    "${search_url}" || true)"
  if [[ "${search_code}" == "200" ]]; then
    random_count="$(jq -r '.traces // [] | length' "${random_response}")"
    (( random_count >= E2E_MIN_RANDOM_TRACES )) && break
  elif [[ -n "${search_code}" ]]; then
    echo "ERROR: Tempo random-window search returned HTTP ${search_code}." >&2
    cat "${random_response}" >&2 2>/dev/null || true
    exit 1
  fi
  sleep 3
done
(( random_count >= E2E_MIN_RANDOM_TRACES )) || {
  echo "ERROR: only ${random_count} trace(s) indexed from ${E2E_REQUESTS} no-prior-decision requests; required >= ${E2E_MIN_RANDOM_TRACES}." >&2
  cat "${random_response}" >&2 2>/dev/null || true
  exit 1
}
echo "OK   random 10% sampling window contains ${random_count} trace(s)"

echo "== E2E 7/8: OTel export health and UWM/Thanos metrics path =="
if oc logs -n istio-system deployment/otel-collector --since-time="${e2e_start_rfc3339}" 2>&1 |
    grep -Eqi 'export(ing)? failed|failed to export|permanent error|permission.?denied|unauthenticated|forbidden|x509|connection refused|queue is full|dropped spans'
then
  echo "ERROR: OTel logs contain an export/auth/TLS/drop failure during this E2E window." >&2
  oc logs -n istio-system deployment/otel-collector --since-time="${e2e_start_rfc3339}" 2>&1 |
    grep -Ei 'export(ing)? failed|failed to export|permanent error|permission.?denied|unauthenticated|forbidden|x509|connection refused|queue is full|dropped spans' |
    tail -80 >&2
  exit 1
fi
echo "OK   no OTel export/auth/TLS/drop failure patterns in this E2E window"

metrics_response="${work}/thanos-after.json"
deadline=$((SECONDS + 180))
metric_after="${metric_before}"
metric_delta="0"
while (( SECONDS < deadline )); do
  metric_token="$(oc create token kiali-service-account -n istio-system --duration=10m)"
  metric_after="$(query_thanos_bookinfo_metric "${metric_token}" "${metrics_response}" || echo 0)"
  [[ "${metric_after}" =~ ^[0-9]+([.][0-9]+)?$ ]] || metric_after=0
  metric_delta="$(awk -v a="${metric_after}" -v b="${metric_before}" 'BEGIN { printf "%.0f", a-b }')"
  if awk -v d="${metric_delta}" -v minimum="${E2E_MIN_METRIC_DELTA}" 'BEGIN { exit !(d >= minimum) }'; then
    break
  fi
  sleep 5
done
awk -v d="${metric_delta}" -v minimum="${E2E_MIN_METRIC_DELTA}" 'BEGIN { exit !(d >= minimum) }' || {
  echo "ERROR: UWM/Thanos Bookinfo istio_requests_total increased by only ${metric_delta}; required >= ${E2E_MIN_METRIC_DELTA}." >&2
  echo "before=${metric_before} after=${metric_after}" >&2
  cat "${metrics_response}" >&2 2>/dev/null || true
  exit 1
}
echo "OK   UWM/Thanos Bookinfo metrics advanced: before=${metric_before} after=${metric_after} delta=${metric_delta}"

echo "== E2E 8/8: final resource health snapshot =="
"${ROOT}/scripts/postcheck.sh"

echo
echo "E2E PASS: Bookinfo application, ingress routing, sidecar propagation, forced and random tracing, OTel -> Tempo, secured Tempo query, and UWM/Thanos metrics are all validated."
