# OpenShift Service Mesh 3.4 observability

Canonical observability configuration for OpenShift Container Platform 4.22 and Red Hat OpenShift Service Mesh 3.4.1 / Istio 1.30.3.

## Architecture

- Envoy metrics -> OpenShift user-workload monitoring -> Prometheus/Thanos -> Kiali
- Envoy traces -> OTLP/gRPC -> Red Hat OpenTelemetry Collector -> secured Tempo gateway -> TempoStack
- Tempo object storage -> OpenShift Data Foundation ObjectBucketClaim (NooBaa S3)
- Kiali -> Thanos Querier and Tempo gateway using its service account token

The historical `v3/` directory remains untouched. This directory is the canonical 3.4 deployment.

## Invariants

- One selectorless `Telemetry` resource in `istio-system`.
- Root `Telemetry` owns Prometheus metrics and tracing provider selection.
- Istio sends traces to `otel-collector.istio-system.svc.cluster.local:4317`.
- OTel sends authenticated OTLP/gRPC to `tempo-mesh-gateway.tempo.svc.cluster.local:8090`.
- ODF-generated credentials are never committed.
- `otel-collector` gets only CREATE on `tempo.grafana.com/mesh/traces`.
- `kiali-service-account` gets GET on `tempo.grafana.com/mesh/traces` and `cluster-monitoring-view`.
- Grafana is not part of the supported baseline.

## Configure

```bash
cp env.example .env
vi .env
set -a
. ./.env
set +a
```

Generate `TEMPO_TENANT_ID` once with `uuidgen` and keep it stable.

## Verify prerequisites

```bash
./scripts/check-prereqs.sh
```

## Existing Istio control plane

Inspect first:

```bash
oc get istio default -n istio-system -o yaml
oc get istiocni default -n istio-cni -o yaml
```

By default `scripts/apply.sh` preserves existing mesh base resources. Set `APPLY_MESH_BASE=1` only when intentionally reconciling `01-istio-cni.yaml` and `02-istio.yaml`.

## Deploy

```bash
./scripts/render.sh
./scripts/validate.sh
./scripts/apply.sh
./scripts/postcheck.sh
```

## ODF storage

The baseline uses `openshift-storage.noobaa.io`. `ObjectBucketClaim/tempo-odf` generates the bucket ConfigMap/Secret. `storage/odf/create-tempo-secret.sh` transforms those values into the Tempo storage Secret without printing credentials.

## Secrets

Never commit `.env`, rendered Secrets, ODF access keys, service-account tokens, or S3 credentials.
