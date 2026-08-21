#!/usr/bin/env bash
set -euo pipefail
oc get istio -A
oc get istiocni -A
oc get telemetry -A
oc get servicemonitor,podmonitor -A | egrep -i 'istio|mesh|proxy' || true
oc get obc tempo-odf -n tempo
oc get tempostack -A
oc get opentelemetrycollector -A
oc get kiali -A
oc auth can-i create traces.mesh.tempo.grafana.com --as=system:serviceaccount:istio-system:otel-collector || true
oc auth can-i get traces.mesh.tempo.grafana.com --as=system:serviceaccount:istio-system:kiali-service-account || true
oc get pods -n openshift-user-workload-monitoring
