# OpenShift Service Mesh 3.4 observability reference

This directory is an additive, reconciled reference configuration for:

- OpenShift Container Platform 4.22
- Red Hat OpenShift Service Mesh 3.4.1 / Istio 1.30.3
- OpenShift user workload monitoring (Prometheus/Thanos)
- Red Hat build of OpenTelemetry
- Red Hat OpenShift distributed tracing platform (Tempo)
- Kiali Operator provided by Red Hat

It intentionally chooses the secured multitenant Tempo path:

    Envoy --OTLP/gRPC:4317--> OTel Collector
          --OTLP/gRPC:8090 + bearer + X-Scope-OrgID + service CA--> Tempo Gateway
          --> TempoStack --> S3

Kiali reads metrics from the OpenShift Thanos Querier and traces from the Tempo Gateway
HTTP API on port 8080.

## Design decisions

1. Exactly one selectorless root `Telemetry` CR is used in `istio-system`.
2. The Istio `Telemetry` API is `telemetry.istio.io/v1`.
3. Tempo multitenancy uses `tenants.mode: openshift`.
4. Tempo Gateway RBAC is enabled.
5. The OTel service account gets `create` on `tempo.grafana.com/<tenant>/traces`.
6. The Kiali service account gets `get` on the same tenant and `cluster-monitoring-view`.
7. OTel exports through the authenticated Tempo Gateway on port 8090, not directly to the distributor.
8. Kiali uses the internal Tempo Gateway service and validates the OpenShift service CA.
9. Proxy `PodMonitor` is applied separately in every mesh namespace; no `namespaceSelector.any` shortcut is used.
10. The trace-only collector has no Target Allocator and no Prometheus receiver.

## Prerequisites

Install the supported Red Hat Operators before applying this directory:

- Red Hat OpenShift Service Mesh 3 Operator, 3.4 channel/version
- Red Hat build of OpenTelemetry Operator
- Tempo Operator / Red Hat OpenShift distributed tracing platform
- Kiali Operator provided by Red Hat

OpenShift user workload monitoring must already be enabled. The scripts deliberately do not overwrite
`openshift-monitoring/cluster-monitoring-config`, because that ConfigMap may contain unrelated cluster settings.

Check prerequisites:

    ./scripts/check-prereqs.sh

## Configuration

Copy the environment template and edit it:

    cp env.example .env
    ${EDITOR:-vi} .env

`TEMPO_TENANT_UUID` must remain stable for the lifetime of this TempoStack. Generate it once with:

    uuidgen

Render the two manifests that contain installation-specific values:

    ./scripts/render.sh .env

The renderer creates:

- `rendered/06-tempo-s3-secret.yaml`
- `rendered/07-tempostack.yaml`

Do not commit the rendered S3 secret.

## Mesh namespaces

Set `MESH_NAMESPACES` in `.env` to a space-separated list, for example:

    MESH_NAMESPACES="bookinfo payments orders"

The apply script labels these namespaces for discovery and sidecar injection and installs the proxy
`PodMonitor` in each namespace.

## Apply

    ./scripts/apply.sh .env

The script does not install the optional NetworkPolicy or UI plugin manifests automatically.

## Validate

Before changing the cluster:

    ./scripts/validate.sh .env --client

When connected to the target cluster, validate CR schemas using server-side dry-run:

    ./scripts/validate.sh .env --server

After deployment:

    ./scripts/postcheck.sh .env

## Optional resources

`optional/allow-uwm-to-proxies.yaml` is useful only when a mesh namespace has restrictive/default-deny
ingress NetworkPolicies. Apply it separately in each affected application namespace.

`optional/distributed-tracing-uiplugin.yaml` enables the OpenShift distributed-tracing console plugin only
when the Cluster Observability Operator and its `UIPlugin` CRD are installed. It is not required for Kiali.
Users of that console plugin also need Tempo tenant read RBAC according to your access policy; the core
configuration intentionally grants trace read access only to Kiali and does not grant cluster-wide user access.

`optional/ossm-console.yaml` installs the Service Mesh console plugin through the Kiali Operator. It is also
not required for the core metrics/traces pipeline.

## Application trace-context propagation

Mesh proxies can create spans, but applications must propagate tracing headers between calls so spans join
one distributed trace. For W3C propagation, preserve at least `traceparent` and `tracestate`; preserve
`x-request-id` as well for Istio request correlation.
