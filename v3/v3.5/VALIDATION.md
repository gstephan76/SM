# Ambient validation

The fresh-cluster data path passed the live acceptance test described below.
Migration from an existing sidecar deployment remains untested, and the ODF
support question remains open. Kubernetes resource acceptance alone does not
establish that the mesh data path works.

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
spans. See [AMBIENT-MIGRATION.md](AMBIENT-MIGRATION.md) for the cutover
limitations and manual recovery path.

The prior sidecar acceptance contract is retained in
[SIDECAR-VALIDATION-HISTORY.md](SIDECAR-VALIDATION-HISTORY.md).

## OpenShift 5.0.1 test, 2026-11-17

The deployment reached the final end-to-end gate after server-side manifest
validation and comprehensive readiness checks passed. Bookinfo was sidecar-free,
all application pods were registered with HBONE, both Gateways were programmed,
and external and in-mesh requests succeeded. The load phase had zero HTTP
failures in 200 requests. The gate nevertheless failed: the first forced trace
contained the ingress and all four Bookinfo waypoint span names, but its span
attributes were redacted, so it did not satisfy the required attribute-based
full-chain proof. The remaining end-to-end gates did not run.

The waypoint's effective Envoy configuration contains the destination tags.
Tempo query RBAC receives those spans without `k8s.namespace.name` on their
resource and returns empty span attributes. Two synthetic spans without a
namespace, sent through the collector and directly through the Tempo gateway,
were both indexed but returned without their attributes. A third synthetic span
with resource namespace `bookinfo` returned its attribute to the same Kiali
service account, which has pod-read permission in that namespace. This confirms
the namespace association issue without disabling query RBAC. The selected remedy
associates the sender connection with a pod in the collector's Kubernetes
attributes processor, before batching, and extracts its namespace. The collector
has cluster-wide pod get/list/watch access. The operator warns that namespace
get/list/watch is missing; the collector started and synchronized its pod cache
without those additional permissions.

An independent metrics check used the actual `reporter="waypoint"` series:
40 successful Bookinfo requests increased the counter from 788 to 932. The
script's waypoint pod selector was corrected to match the deployed pod name.

The initial ZTunnel rollout also exposed a missing `istio-discovery=enabled`
namespace label. Applying the label caused Istiod to create the trust ConfigMap
and all ZTunnel pods became ready; the namespace manifest now includes it.
NooBaa used its PV-pool fallback after the cloud credential request failed, and
the backing store, bucket class, OBC and PVC reached their readiness gates. This
observation does not establish Red Hat support for ODF 4.22 on OCP 5.0.

After the collector configuration and pod-read binding were applied, the full
`scripts/e2e-check.sh` run passed, including its final readiness snapshot. All
200 external load requests succeeded. All 12 forced trace IDs had the required
ingress and productpage, details and reviews waypoint destinations; 10 also had
ratings. The unsampled negative control was not stored, and the random sampling
window contained 25 traces. The waypoint request counter increased from 932 to
1599, and the collector showed no export, authorization, TLS or drop errors in
the test window. These results apply to the fresh cluster, not the sidecar
migration and manual rollback paths.
