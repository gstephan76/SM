# Ambient validation

The ambient port is not yet qualified on the target cluster. A resource being
accepted by Kubernetes does not establish that the mesh data path works.

The intended validation layers are:

1. **Local checks:** shell syntax, YAML parsing, and
   `scripts/test-ambient-trace.sh`. The fixture rejects missing service hops,
   non-waypoint attributes, sidecar-injected application pods and an ingress
   without explicit HBONE configuration. These are synthetic checks.
2. **Prerequisites and API validation:** the operator versions and CRDs,
   OpenShift 5.0, ODF/NooBaa health, permissions, supported mesh configuration,
   policy inventory and server-side dry runs. Bootstrap namespace checks can
   be deferred until namespaces exist; full server validation is then required.
3. **Readiness:** ambient Istio and CNI with native nftables, ready ZTunnel,
   sidecar-free Bookinfo pods registered with HBONE, programmed Gateway API
   resources, accepted HTTPRoute, ready endpoints, correct namespace and
   ingress-waypoint labels, Route admission, metrics monitors, Kiali access to
   ztunnel, and the existing Tempo and OTel health and authorization checks.
4. **Traffic and telemetry:** external and internal Bookinfo requests, exact
   W3C trace-ID retrieval, ingress and waypoint trace resources, waypoint span
   destination attributes for productpage, details and reviews, and ratings on
   at least one trace. The test also uses an unsampled negative control,
   checks the collector for export errors, and requires the waypoint's
   `istio_requests_total` counter to increase after generated traffic.

The Istio 1.31 source defines `istio.destination_canonical_service` for waypoint
spans. Actual tag values, the gateway and waypoint resource names, monitoring
labels, tracing sampling behavior and full-chain correlation remain unverified
on this OpenShift 5.0 stack. No end-to-end acceptance claim can be made until
those checks pass on a qualified deployment. See [AMBIENT-MIGRATION.md](AMBIENT-MIGRATION.md)
for the cutover limitations and manual recovery path.

The prior sidecar acceptance contract is retained in
[SIDECAR-VALIDATION-HISTORY.md](SIDECAR-VALIDATION-HISTORY.md).
