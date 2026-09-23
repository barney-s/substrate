# Deploy — GCP (GKE cluster, snapshot bucket, counter demo)

*Drafted 2026-09-23 against `050a584c`. The steps come from `tools/setup-gcp`,
`hack/install-ate.sh` (a shim over `cmd/ate-setup`), `hack/run-e2e.sh`,
`hack/teardown.sh` and `demos/counter/README.md`.*

## What this needs

**This cannot run in the pod. It needs real infrastructure:** a GKE Standard
cluster, one zonal cluster with one node pool of two `c3-standard-4` nodes
(`setup-gcp create cluster`), plus a GCS bucket for snapshots.

Real nodes are required because of atelet, a privileged-path DaemonSet. It
hostPath-mounts `/var/lib/kubelet/plugins`, `/var/lib/kubelet/device-plugins`,
host `/dev`, and `/var/lib/ateom-gvisor`, which it shares with the ateom worker
pods that run `runsc`. The install also needs Kubernetes ≥ 1.36, because it
uses the beta `PodCertificateRequest` and `ClusterTrustBundle` APIs; GKE
enables them only at cluster creation. The in-cluster PostgreSQL is used
(`manifests/ate-install/postgres`, backed by a PVC/PD). Cloud SQL is not.

**Cost while up:** two c3-standard-4 VMs and their boot disks, the GKE
management fee (unless the billing account's free zonal cluster covers it),
one small PD, and the images under `gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}`.
**Teardown** takes about 10 minutes, mostly cluster deletion. It deletes the
bucket together with all its snapshots.

**Parameters** come from `params.env` (resolved at plan time, never hardcoded
here): `PROJECT_ID`, `GCE_REGION`, `CLUSTER_LOCATION` (a zone inside
`GCE_REGION`), and `RESOURCE_PREFIX`. Every resource this runbook creates is
named from `RESOURCE_PREFIX`.

Feasibility, probed 2026-09-23 read-only under the executing identity (a GKE
Workload Identity principal holding `roles/owner` and `roles/editor`), using
`projects.testIamPermissions`, `get-iam-policy`, and list/describe calls:

- ✓ `serviceusage.services.enable` — `setup-gcp enable apis`
- ✓ `container.clusters.create/get/update/delete/getCredentials`, `container.operations.get` — `create cluster`, `get-credentials`, node-pool update, teardown
- ✓ `iam.serviceAccounts.actAs` — nodes run as the default compute SA
- ✓ `compute.networks.get`, `compute.subnetworks.use` — VPC `default` exists
- ✓ `resourcemanager.projects.getIamPolicy/setIamPolicy` — `create iam` project bindings
- ✓ `storage.buckets.create/delete`. Bucket-level `getIamPolicy/setIamPolicy` and
  object access come through the `projectOwner:` legacy binding that a new bucket
  receives; `testIamPermissions` at project level reports them as not granted.
- ✓ `artifactregistry.repositories.uploadArtifacts/downloadArtifacts`. The `gcr.io`
  Artifact Registry repo exists (`us`), so ko can push to it.
- ✓ ADC is served by the GKE metadata server (`gcloud auth application-default print-access-token` works). `setup-gcp` and ko both use it.
- ✓ Quota in the region: C3_CPUS 0/300, CPUS 20/3000
- ✓ GKE 1.36 is offered (`gcloud container get-server-config`: `1.36.4-gke.*`, `1.36.3-gke.1767000`)
- ✓ Tools: `go`, `gcloud`, `kubectl`, `gke-gcloud-auth-plugin`, `jq`, `git`, `make`.
  ko is resolved by `hack/run-tool.sh`, so no Docker is needed.
- ⚠ **Shared project state.** The project already has the Substrate project-level bindings
  (`…/ns/ate-system/sa/atelet` → `storage.objectAdmin` and `artifactregistry.reader`; the compute SA
  → `storage.objectViewer` and `artifactregistry.reader`). They exist because
  the Workload Identity subject is keyed to the *project*, not the cluster, so
  every Substrate instance in the project shares it. `create iam` re-adds them
  idempotently, and Teardown deliberately leaves them alone.
- ⚠ **Another cluster is in the project** (`gcloud container clusters list`). This runbook never touches it.
- ⚠ **Disk:** `/workspaces` is 9.8 GB and the Go cache fills it. Step 0 moves the cache to `/tmp`.

No ✗ items: every step's permission was granted when this was drafted.

## Preconditions

- The repository checkout is the current directory, and `params.env` is at its root or has been sourced.
- `CLUSTER_LOCATION` is a zone in `GCE_REGION` that offers `c3-standard-4`.
- No `.ate-dev-env.sh` should override these values. Step 0 sets `NO_DEV_ENV=1`.

## Steps

```bash
# 0. Parameters and derived names.
source params.env   # PROJECT_ID GCE_REGION CLUSTER_LOCATION RESOURCE_PREFIX
export NO_DEV_ENV=1 GOCACHE=/tmp/gocache GOTMPDIR=/tmp/gotmp
mkdir -p "$GOCACHE" "$GOTMPDIR"
export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
export CLUSTER_NAME="${RESOURCE_PREFIX}"
export BUCKET_NAME="${RESOURCE_PREFIX}-snap-${PROJECT_NUMBER}"   # bucket names are global
export KO_DOCKER_REPO="gcr.io/${PROJECT_ID}/${RESOURCE_PREFIX}"
export KO_DEFAULTPLATFORMS=linux/amd64
export NETWORK=default SUBNETWORK=default NODE_MACHINE_TYPE=c3-standard-4
# Newest offered 1.36 patch (1.37+ also works); see hack/ate-dev-env.sh.example.
export CLUSTER_VERSION=$(gcloud container get-server-config --location "${CLUSTER_LOCATION}" \
  --format=json | jq -r '.validMasterVersions[]' | grep -m1 '^1\.36\.')
export KUBECTL_CONTEXT="gke_${PROJECT_ID}_${CLUSTER_LOCATION}_${CLUSTER_NAME}"

# 1. APIs, cluster, bucket, IAM. These are bootstrap's steps without the
#    dashboards: those are project-wide, share their names across instances,
#    and teardown deletes them by name.
go run ./tools/setup-gcp enable apis
go run ./tools/setup-gcp create cluster      # about 10 min; 2 nodes in substrate-node-pool
go run ./tools/setup-gcp create bucket
go run ./tools/setup-gcp create iam

# 2. Workers must not be drained by GKE (tools/setup-gcp/README.md, Create Cluster warning).
gcloud container node-pools update substrate-node-pool \
  --cluster "${CLUSTER_NAME}" --location "${CLUSTER_LOCATION}" --no-enable-autoupgrade

# 3. Credentials. The context name matches KUBECTL_CONTEXT.
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --location "${CLUSTER_LOCATION}" --project "${PROJECT_ID}"

# 4. Control plane: ko builds and pushes every image, then applies CRDs, RBAC,
#    postgres, ateapi, the controller, atenet and atelet, and labels the nodes
#    ate.dev/substrate-version.
hack/install-ate.sh --deploy-ate-system --rollout-timeout=300s

# 5. The counter demo (gVisor), and the CLI.
hack/install-ate.sh --deploy-demo-counter
go install ./cmd/kubectl-ate
```

## Verify

```bash
kubectl get pods -n ate-system            # everything Running/Ready, one atelet per node
kubectl get ds -n ate-system -l app=atelet -L ate.dev/substrate-version
kubectl get nodes -L ate.dev/substrate-version   # every node labeled, all with the same value
kubectl get clustertrustbundles           # served and non-empty (the beta APIs are on)
kubectl get workerpools -A                # counter: READY == DESIRED
kubectl ate get actor-templates -a ate-demo-counter

# Round trip through atenet: create, resume on request, suspend to GCS, resume again.
kubectl ate create actor rb-counter-1 -a ate-demo-counter --template counter
kubectl port-forward -n ate-system svc/atenet-router 8000:80 >/dev/null 2>&1 &
curl -X POST -H "ate-target-actor: ate-demo-counter/rb-counter-1" http://localhost:8000
kubectl ate get actor rb-counter-1 -a ate-demo-counter        # RUNNING, with a worker
kubectl ate suspend actor rb-counter-1 -a ate-demo-counter
gcloud storage ls "gs://${BUCKET_NAME}/" | head                # a snapshot landed
curl -X POST -H "ate-target-actor: ate-demo-counter/rb-counter-1" http://localhost:8000  # counts continue
kubectl ate delete actor rb-counter-1 -a ate-demo-counter
kill %1

# Optional: the CI demo lifecycle test against this cluster.
hack/run-e2e.sh ./internal/e2e/suites/demo -run '^TestActorLifecycle$' -v -args --no-color
```

Success means the second `curl` returns counters that continue from the first.
That proves the full snapshot went to GCS and came back.

## Teardown

```bash
source params.env; export NO_DEV_ENV=1   # then re-run the Step 0 exports
# Remove the control plane first: deleting postgres.yaml drops its PVC, and with it the PD.
hack/install-ate.sh --delete-all
# Only this instance's bucket bindings, bucket and cluster. The project-level
# bindings (--revoke-atelet-permissions, --revoke-gke-node-permissions) are
# shared with every other Substrate instance in the project, so leave them.
hack/teardown.sh --delete-iam-policy-bindings --delete-snapshot-bucket --delete-cluster
# This instance's images.
for img in $(gcloud artifacts docker images list "${KO_DOCKER_REPO}" --format='value(package)' | sort -u); do
  gcloud artifacts docker images delete "${img}" --delete-tags --quiet
done
gcloud container clusters list --filter="name=${CLUSTER_NAME}"   # empty
```
