# OSSM 3.5 ambient observability

This directory targets OpenShift 5.0 and OpenShift Service Mesh 3.5
with ambient Bookinfo workloads. The previous OpenShift 4.22 sidecar runbook is
retained as [SIDECAR-HISTORY.md](SIDECAR-HISTORY.md); it does not describe this
deployment.

**The ambient deployment is not yet qualified on the target cluster.** No mesh,
operator, storage, or application resources have been deployed by this port.

The intended data path is:

```text
Client -> existing OpenShift Route -> Gateway API ingress -> Bookinfo waypoint
       -> ambient Bookinfo workloads, intercepted by per-node ztunnel

ztunnel + waypoint + ingress metrics -> user workload monitoring -> Thanos -> Kiali
waypoint + ingress traces -> OTel Collector -> Tempo Gateway -> Tempo -> NooBaa
```

The control plane and CNI use the ambient profile and native nftables for
RHCOS 10. The ingress is opted into the service waypoint; without that opt-in,
ingress traffic can bypass waypoint telemetry and L7 policy. Kiali is configured
to query traces by waypoint name.

The target cluster currently offers OSSM 3.5.0, Kiali 2.33.1, OpenTelemetry
0.158, Tempo 0.22 and ODF 4.22.7 in its operator catalog. Red Hat lists OSSM
3.5 for OpenShift 5.0. Its general ODF lifecycle table lists ODF 4.22 for
OpenShift 4.22, while an OKD 5 telco reference includes ODF 4.22. Confirm
support for this exact OCP 5.0 and standalone NooBaa combination before relying
on it. The AWS-specific MCG bootstrap uses the `gp3-csi` StorageClass.

## Migration and validation

[AMBIENT-MIGRATION.md](AMBIENT-MIGRATION.md) describes the selected cutover,
limitations, and manual recovery for the original v3.5 sidecar deployment.
The script refuses to migrate security and traffic policies that require
separate review. It preserves the old ingress resources for rollback and
switches the existing Route only after the new ingress and workloads are ready.

The required final acceptance test correlates forced W3C trace IDs with Tempo,
requires gateway and waypoint spans, and checks the waypoint destination tags
for productpage, details, reviews, and at least one ratings hop. It also checks
an unsampled negative control and a before/after waypoint request metric in
Thanos. These checks are implemented but have not been run against the target
stack; source definitions and synthetic fixtures do not establish live behavior.

Local checks that do not contact or modify the cluster:

```bash
bash scripts/test-ambient-trace.sh
bash -n scripts/*.sh storage/odf/*.sh
```

The deployment requires the OSSM, Kiali, OpenTelemetry, Tempo and Cluster
Observability Operators, their CRDs, working user workload monitoring, and a
healthy NooBaa OBC provisioner. `scripts/check-prereqs.sh` checks those
requirements, and `scripts/validate.sh` performs server-side dry runs when the
target namespaces exist. `APPLY_MESH_BASE=0` preserves a qualifying ambient
mesh; `APPLY_MESH_BASE=1` intentionally reconciles the mesh base. An existing
sidecar control plane requires intentional reconciliation before migration.
After reviewing the ODF compatibility caveat and installing the required
operators, initialize or preserve the tenant configuration with
`./scripts/init-env.sh`. For a healthy existing NooBaa installation, run
`./scripts/check-prereqs.sh`, then `APPLY_MESH_BASE=1 ./scripts/validate.sh`
and `APPLY_MESH_BASE=1 ./scripts/apply.sh` for a fresh mesh or an intentionally
reconciled sidecar mesh. Set `BOOTSTRAP_MCG=1` only if the AWS-specific ODF
bootstrap is explicitly intended. Existing healthy ambient meshes can instead
use the default `APPLY_MESH_BASE=0`.

Keep `.env`, bucket credentials, rendered secrets and service-account tokens
out of version control. Preserve the Tempo tenant UUID across reruns.

References: [Red Hat OSSM 3.5 support](https://www.redhat.com/en/blog/introducing-red-hat-openshift-service-mesh-35), [Red Hat operator lifecycle](https://access.redhat.com/support/policy/updates/openshift_operators), [Istio sidecar-to-ambient migration](https://istio.io/latest/docs/ambient/migrate/).
