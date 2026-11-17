# Ambient migration and recovery

The migration sequence and recovery instructions have not yet been qualified
on the target cluster. Review them and the operator prerequisites before use.

The target is OpenShift 5.0, OSSM 3.5 and Istio 1.31. The CNI and control plane
use the ambient profile and native nftables for the target's RHCOS 10 nodes.
Ztunnel supplies the L4 data plane, and the Bookinfo service waypoint supplies
HTTP metrics and tracing. A Gateway API ingress serves the existing OpenShift
Route. Tempo continues to use an ODF/NooBaa object bucket. ODF 4.22.7 is in the
cluster catalog; the general Red Hat lifecycle table and the OKD 5 telco
reference provide different compatibility signals, so support for this exact
deployment must be confirmed separately.

For an existing baseline, the intended cutover provisions the new ingress and
waypoint, enrolls Bookinfo, restarts injected application workloads, verifies
HBONE registration and the new ingress, and only then retargets the existing
Route. The old ingress Deployment, Service, Istio Gateway and VirtualService
are retained. During a mixed-mode migration, sidecar-originated traffic can
bypass the destination waypoint; L7 policy enforcement is therefore not
continuous. Inventory custom policies and plan a maintenance window before
running a migration. The preflight rejects existing security policies,
DestinationRules, Sidecars, EnvoyFilters, WasmPlugins and non-baseline
VirtualServices in `bookinfo` or `istio-system`, and a revision label on the
Bookinfo namespace, for separate review. No automated rollback is provided.

The intended acceptance gate keeps the full Bookinfo trace requirement. It
looks up each exact trace ID in Tempo, requires ingress and waypoint resources,
and checks `istio.destination_canonical_service` on waypoint spans for
productpage, details and reviews, with ratings present in at least one trace.
The tag is defined by Istio 1.31, but its values and end-to-end availability on
this OpenShift cluster have not yet been established. The metrics gate checks
that the waypoint's Bookinfo request counter advances during the test.

## Manual recovery for the original v3.5 sidecar Bookinfo baseline

These commands apply only if the original Bookinfo sidecar ingress resources
still exist and have not been independently modified. Record the current
namespace labels, Route and deployment specifications first, and inspect the
state after any failure. A fresh install has no old ingress to restore.

1. Re-enable sidecar injection and remove ambient enrollment:

   ```bash
   oc label namespace bookinfo istio.io/dataplane-mode- istio.io/use-waypoint- istio-injection=enabled --overwrite
   oc label service productpage -n bookinfo istio.io/ingress-use-waypoint-
   ```

2. Restart the six Bookinfo application Deployments and the retained ingress
   Deployment, then wait for each rollout and verify that the application pods
   have ready `istio-proxy` containers and that the old ingress Service has ready
   endpoints. The retained ingress must be restarted after enabling the ambient
   control-plane profile to acquire the required HBONE settings.

   ```bash
   for deployment in details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3 productpage-v1 istio-ingressgateway; do
     oc rollout restart deployment "$deployment" -n bookinfo
     oc rollout status deployment "$deployment" -n bookinfo --timeout=420s
   done
   ```

3. Restore the existing Route's target and port without changing its host:

   ```bash
   oc patch route istio-ingressgateway -n bookinfo --type=merge -p '{"spec":{"to":{"kind":"Service","name":"istio-ingressgateway","weight":100},"port":{"targetPort":"http2"}}}'
   ```

4. Verify Route admission, external and in-mesh Bookinfo requests, and the
   original tracing and metrics acceptance gates. Leave the ambient resources in
   place until their ownership and cleanup have been reviewed.

References: [Red Hat sidecar and ambient coexistence](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.4/html/installing/ossm-ambient-sidecar-coexistence), [Red Hat operator lifecycle](https://access.redhat.com/support/policy/updates/openshift_operators), [OpenShift 5 telco reference](https://docs.okd.io/5.0/scalability_and_performance/telco-core-rds.html).
