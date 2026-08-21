#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/check-prereqs.sh"
"$ROOT/scripts/render.sh"
oc apply -f "$ROOT/manifests/00-namespaces.yaml"
"$ROOT/scripts/enable-uwm.sh"
if [[ "${APPLY_MESH_BASE:-0}" == 1 ]]; then oc apply -f "$ROOT/manifests/01-istio-cni.yaml"; oc apply -f "$ROOT/manifests/02-istio.yaml"; else oc get istiocni default -n istio-cni >/dev/null; oc get istio default -n istio-system >/dev/null; echo "Preserving existing mesh base"; fi
existing="$(oc get telemetry -n istio-system -o jsonpath='{range .items[?(!@.spec.selector)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [[ -n "$existing" ]] && ! printf '%s\n' "$existing" | grep -qx mesh-observability; then echo "ERROR: another selectorless Telemetry exists in istio-system: $existing" >&2; exit 1; fi
oc apply -f "$ROOT/manifests/03-mesh-telemetry.yaml"
oc apply -f "$ROOT/manifests/04-istiod-servicemonitor.yaml"
for f in "$ROOT"/rendered/05-istio-proxies-podmonitor-*.yaml; do oc apply -f "$f"; done
oc apply -f "$ROOT/storage/odf/00-tempo-obc.yaml"
for _ in $(seq 1 60); do [[ "$(oc get obc tempo-odf -n tempo -o jsonpath='{.status.phase}' 2>/dev/null || true)" == Bound ]] && break; sleep 5; done
[[ "$(oc get obc tempo-odf -n tempo -o jsonpath='{.status.phase}')" == Bound ]] || { echo "ERROR: OBC not Bound" >&2; exit 1; }
"$ROOT/storage/odf/create-tempo-secret.sh"
oc apply -f "$ROOT/manifests/08-otel-tempo-write-rbac.yaml"
oc apply -f "$ROOT/rendered/07-tempostack.yaml"
oc apply -f "$ROOT/manifests/09-otel-collector.yaml"
oc apply -f "$ROOT/manifests/12-kiali.yaml"
for _ in $(seq 1 60); do oc get sa kiali-service-account -n istio-system >/dev/null 2>&1 && break; sleep 2; done
oc get sa kiali-service-account -n istio-system >/dev/null
oc apply -f "$ROOT/manifests/10-kiali-monitoring-rbac.yaml"
oc apply -f "$ROOT/manifests/11-kiali-tempo-read-rbac.yaml"
