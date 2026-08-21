#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl is required for the E2E trace check." >&2
  exit 1
}

: "${TRACE_TEST_URL:?Set TRACE_TEST_URL to an HTTP(S) endpoint routed through the mesh}"
E2E_REQUESTS="${E2E_REQUESTS:-200}"
TEMPO_LOCAL_PORT="${TEMPO_LOCAL_PORT:-18080}"

[[ "${E2E_REQUESTS}" =~ ^[0-9]+$ && "${E2E_REQUESTS}" -ge 100 ]] || {
  echo "ERROR: E2E_REQUESTS must be an integer >= 100 for the 10% sampling test." >&2
  exit 1
}

require_tempo_sar \
  "otel-collector" \
  "system:serviceaccount:istio-system:otel-collector" \
  create
require_tempo_sar \
  "kiali-service-account" \
  "system:serviceaccount:istio-system:kiali-service-account" \
  get

start_ts="$(( $(date +%s) - 5 ))"

echo "Generating ${E2E_REQUESTS} mesh requests at 10% sampling..."
success=0
for _ in $(seq 1 "${E2E_REQUESTS}"); do
  if curl --fail --silent --show-error \
      --max-time 10 "${TRACE_TEST_URL}" >/dev/null
  then
    success=$((success + 1))
  fi
done

echo "Successful requests: ${success}/${E2E_REQUESTS}"
[[ "${success}" -ge 100 ]] || {
  echo "ERROR: fewer than 100 requests succeeded; trace-sampling proof is not statistically strong enough." >&2
  exit 1
}

echo "Checking OTel logs for export/auth/TLS failures..."
if oc logs -n istio-system deployment/otel-collector --since=10m 2>&1 |
    grep -Eqi 'error|failed|forbidden|permission|unauth|x509|connection refused|retrying|dropped spans'
then
  echo "ERROR: OTel logs contain an export/auth/TLS failure pattern." >&2
  oc logs -n istio-system deployment/otel-collector --since=10m 2>&1 |
    grep -Ei 'error|failed|forbidden|permission|unauth|x509|connection refused|retrying|dropped spans' |
    tail -50 >&2
  exit 1
fi

echo "Waiting for trace export and Tempo search visibility..."
sleep 30

token="$(
  oc create token kiali-service-account \
    -n istio-system \
    --duration=10m
)"

pf_log="$(mktemp)"
tempo_response="$(mktemp)"
pf_pid=""
cleanup() {
  if [[ -n "${pf_pid}" ]]; then
    kill "${pf_pid}" >/dev/null 2>&1 || true
    wait "${pf_pid}" 2>/dev/null || true
  fi
  rm -f "${pf_log}" "${tempo_response}"
}
trap cleanup EXIT

oc -n tempo port-forward \
  svc/tempo-mesh-gateway \
  "${TEMPO_LOCAL_PORT}:8080" \
  >"${pf_log}" 2>&1 &
pf_pid=$!

for _ in $(seq 1 30); do
  if grep -q 'Forwarding from' "${pf_log}"; then
    break
  fi
  if ! kill -0 "${pf_pid}" >/dev/null 2>&1; then
    cat "${pf_log}" >&2
    echo "ERROR: Tempo gateway port-forward exited early." >&2
    exit 1
  fi
  sleep 1
done

grep -q 'Forwarding from' "${pf_log}" || {
  cat "${pf_log}" >&2
  echo "ERROR: Tempo gateway port-forward did not become ready." >&2
  exit 1
}

end_ts="$(date +%s)"
query_url="https://127.0.0.1:${TEMPO_LOCAL_PORT}/api/traces/v1/mesh/tempo/api/search"

if ! http_code="$(
  curl -q --silent --show-error --insecure --get \
    -o "${tempo_response}" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    --data-urlencode 'q={}' \
    --data-urlencode 'limit=50' \
    --data-urlencode "start=${start_ts}" \
    --data-urlencode "end=${end_ts}" \
    "${query_url}"
)"
then
  echo "ERROR: Tempo search request failed at the transport layer." >&2
  [[ ! -s "${tempo_response}" ]] || cat "${tempo_response}" >&2
  exit 1
fi

if [[ "${http_code}" != "200" ]]; then
  echo "ERROR: Tempo search returned HTTP ${http_code}." >&2
  echo "Query window: start=${start_ts} end=${end_ts}" >&2
  cat "${tempo_response}" >&2
  exit 1
fi

response="$(cat "${tempo_response}")"

if ! printf '%s' "${response}" |
    grep -Eq '"traces"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{'
then
  echo "ERROR: Tempo query succeeded but returned no traces generated during this E2E window." >&2
  printf '%s\n' "${response}" >&2
  exit 1
fi

printf '%s\n' "${response}" |
  grep -Eo '"traceID"[[:space:]]*:[[:space:]]*"[0-9a-f]+"' |
  head -5

echo "E2E PASS: mesh traffic produced queryable traces through Envoy -> OTel -> Tempo."
