# OSSM 3.5 ambient observability

This directory targets OpenShift 5.0 and OpenShift Service Mesh 3.5
with ambient Bookinfo workloads. The previous OpenShift 4.22 sidecar runbook is
retained as [SIDECAR-HISTORY.md](SIDECAR-HISTORY.md); it does not describe this
deployment.

**The fresh-cluster data path passed live acceptance; sidecar migration and ODF
support remain unverified.** See [VALIDATION.md](VALIDATION.md) for the results.

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
The collector associates incoming trace connections with pods and adds the
pod namespace for Tempo query authorization. Its service account can read pod
objects, including their specifications and metadata, across the cluster.

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
Thanos. See [VALIDATION.md](VALIDATION.md) for the results on the target stack;
source definitions and synthetic fixtures alone do not establish live behavior.

Local checks that do not contact or modify the cluster:

```bash
bash scripts/test-ambient-trace.sh
python3 tests/test_fresh_prereqs.py
bash -n scripts/*.sh storage/odf/*.sh
```

The deployment requires the OSSM, Kiali, OpenTelemetry, Tempo and Cluster
Observability Operators, their CRDs, working user workload monitoring, and a
healthy NooBaa OBC provisioner. Initialize or preserve the tenant configuration
with `./scripts/init-env.sh` and review the ODF compatibility caveat above.

On a fresh cluster with healthy ODF/NooBaa already installed (including ODF
running on OpenShift Virtualization), install the missing Operators and deploy:

```bash
./scripts/bootstrap-operators.sh --apply
APPLY_MESH_BASE=1 ./scripts/validate.sh
APPLY_MESH_BASE=1 ./scripts/apply.sh
```

Alternatively, `apply.sh` runs the Operator bootstrap automatically before
validation. `validate.sh` and `check-prereqs.sh` are read-only: they report
missing Operators until the bootstrap has completed. Set
`BOOTSTRAP_OPERATORS=0` to disable automatic Operator installation; an existing
Subscription is retained, and an unsupported version, conflicting scope or
ambiguous ownership causes the bootstrap to stop. The Red Hat catalog must
provide the expected OSSM 3.5, Kiali 2.33, OpenTelemetry 0.152 or 0.158, Tempo
0.22 and Cluster Observability 1.x versions. Operator installation waits up to
`OPERATOR_TIMEOUT_SECONDS` per Operator (default 1200 seconds).

The storage preflight checks the existing NooBaa OBC StorageClass, bucket class,
Ready gateway and PV-backed store, and all configured data PVCs using the actual
backing StorageClass. It does not require `gp3-csi` or a particular
StorageCluster name. `apply.sh` provisions the Tempo ObjectBucketClaim and
waits for it to become Bound; readiness checks alone do not establish that a
bucket can be provisioned. Existing storage is never reconfigured. Set
`BOOTSTRAP_MCG=1` only to opt into the AWS-specific standalone MCG bootstrap;
it uses `gp3-csi`, reuses healthy existing storage on either platform and
refuses to replace an incompatible existing installation.

`APPLY_MESH_BASE=0` preserves a qualifying ambient mesh;
`APPLY_MESH_BASE=1` intentionally reconciles the mesh base. An existing
sidecar control plane requires intentional reconciliation before migration.

Keep `.env`, bucket credentials, rendered secrets and service-account tokens
out of version control. Preserve the Tempo tenant UUID across reruns.

References: [Red Hat OSSM 3.5 support](https://www.redhat.com/en/blog/introducing-red-hat-openshift-service-mesh-35), [Red Hat operator lifecycle](https://access.redhat.com/support/policy/updates/openshift_operators), [Istio sidecar-to-ambient migration](https://istio.io/latest/docs/ambient/migrate/).
