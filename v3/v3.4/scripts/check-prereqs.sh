#!/usr/bin/env bash
set -euo pipefail
missing=0
need(){ if oc get crd "$1" >/dev/null 2>&1; then echo "OK   $1"; else echo "MISS $1"; missing=1; fi; }
for c in istios.sailoperator.io istiocnis.sailoperator.io telemetries.telemetry.istio.io servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com opentelemetrycollectors.opentelemetry.io tempostacks.tempo.grafana.com kialis.kiali.io objectbucketclaims.objectbucket.io; do need "$c"; done
oc get storageclass openshift-storage.noobaa.io >/dev/null 2>&1 || { echo "MISS openshift-storage.noobaa.io"; missing=1; }
(( missing == 0 )) || { echo "ERROR: prerequisites incomplete" >&2; exit 1; }
