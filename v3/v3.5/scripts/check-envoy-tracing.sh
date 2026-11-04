#!/usr/bin/env bash
# Read actual OSSM ingress Envoy configuration; do not infer tracing from CRs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/scripts/lib-common.sh"
load_stack_env "${ROOT}"

for cmd in oc jq; do
  command -v "${cmd}" >/dev/null || { echo "ERROR: missing ${cmd}" >&2; exit 1; }
done
GW="$(oc -n bookinfo get pods -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${GW}" ]] || { echo 'ERROR: no bookinfo pod labeled istio=ingressgateway.' >&2; exit 1; }
echo "Gateway pod: ${GW}"
config="$(mktemp)"
trap 'rm -f "${config}"' EXIT
oc -n bookinfo exec "${GW}" -c istio-proxy -- \
  pilot-agent request GET config_dump >"${config}"

jq '[.. | objects | select(.tracing?.provider?.name == "envoy.tracers.opentelemetry")
       | {tracer: .tracing.provider.name,
          grpcCluster: .tracing.provider.typed_config.grpc_service.envoy_grpc.cluster_name,
          randomSamplingPercent: .tracing.random_sampling.value,
          clientSamplingPercent: .tracing.client_sampling.value,
          overallSamplingPercent: .tracing.overall_sampling.value}] | unique' "${config}"

jq -e '[.. | objects
       | select(.tracing?.provider?.name == "envoy.tracers.opentelemetry")
       | select(.tracing.random_sampling.value == 10
                and .tracing.client_sampling.value == 100)
       | select(.tracing.provider.typed_config.grpc_service.envoy_grpc.cluster_name
                | contains("otel-collector.istio-system.svc.cluster.local"))] | length > 0' \
  "${config}" >/dev/null || {
  echo 'ERROR: effective ingress Envoy tracing differs from verified OSSM 3.5 settings.' >&2
  exit 1
}
echo 'OK   ingress has OTLP tracer, random 10%, client-directed 100%.'
