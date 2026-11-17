#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/scripts/lib-common.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cat >"${work}/trace.json" <<'JSON'
{"batches":[
  {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"waypoint.bookinfo"}}]},"scopeSpans":[{"spans":[{"attributes":[{"key":"istio.destination_canonical_service","value":{"stringValue":"productpage"}}]},{"attributes":[{"key":"istio.destination_canonical_service","value":{"stringValue":"details"}}]},{"attributes":[{"key":"istio.destination_canonical_service","value":{"stringValue":"reviews"}}]}]}]},
  {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"bookinfo-ambient-istio.bookinfo"}}]}},
  {"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"other.bookinfo"}}]},"scopeSpans":[{"spans":[{"attributes":[{"key":"istio.destination_canonical_service","value":{"stringValue":"ratings"}}]}]}]}
]}
JSON
destinations="$(trace_waypoint_destinations "${work}/trace.json")"
has_service "${destinations}" productpage
if has_service "${destinations}" ratings; then
  echo 'ERROR: a non-waypoint span satisfied the waypoint destination check.' >&2
  exit 1
fi
trace_has_bookinfo_chain "${work}/trace.json"
jq 'del(.batches[0].scopeSpans[0].spans[1])' "${work}/trace.json" >"${work}/missing-hop.json"
if trace_has_bookinfo_chain "${work}/missing-hop.json"; then
  echo 'ERROR: a trace missing the details hop satisfied the full-chain check.' >&2
  exit 1
fi
ambient='{"items":[{"spec":{"containers":[{"name":"app"}]},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}'
sidecar='{"items":[{"spec":{"containers":[{"name":"app"},{"name":"istio-proxy"}]},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}'
native='{"items":[{"spec":{"containers":[{"name":"app"}],"initContainers":[{"name":"istio-proxy"}]},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}'
ambient_pods_ready_from_json "${ambient}"
if ambient_pods_ready_from_json "${sidecar}" || ambient_pods_ready_from_json "${native}" || ambient_pods_ready_from_json '{"items":[]}'; then
  echo 'ERROR: sidecar or empty pod set satisfied ambient readiness.' >&2
  exit 1
fi
gateway='{"items":[{"spec":{"containers":[{"name":"istio-proxy","env":[{"name":"ISTIO_META_ENABLE_HBONE","value":"true"}]}]}}]}'
gateway_hbone_enabled_from_json "${gateway}"
if gateway_hbone_enabled_from_json "${sidecar}" || gateway_hbone_enabled_from_json '{"items":[]}'; then
  echo 'ERROR: an ingress without explicit HBONE readiness satisfied the gateway check.' >&2
  exit 1
fi
echo 'OK   waypoint trace attribution, missing-hop rejection, and ambient pod checks'
