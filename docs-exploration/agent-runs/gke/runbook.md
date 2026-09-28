# Runbook: Deploy Agent Substrate to GKE (Build from Source)

## What this needs

### Real Infrastructure Requirement
This run cannot be completed inside a lightweight container/pod or envtest environment. It requires **real Google Kubernetes Engine (GKE) infrastructure** and GCP cloud resources for the following concrete reasons:
- **Privileged DaemonSets & Host Mounts:** `atelet` is a node-level agent deployed as a DaemonSet requiring privileged execution, direct access to host cgroup hierarchies, host namespaces, and container runtime sockets to manage actor sandbox isolation.
- **Micro-VM Virtualization (`/dev/kvm`):** Running micro-VM-based actors (kata + cloud-hypervisor) requires GKE compute nodes with nested virtualization enabled (`--enable-nested-virtualization`) to expose `/dev/kvm`.
- **Kubernetes Beta Certificates APIs:** Agent Substrate's `podcertificate-controller` relies on Kubernetes beta APIs (`certificates.k8s.io/v1beta1/podcertificaterequests` and `certificates.k8s.io/v1beta1/clustertrustbundles`) enabled at cluster creation time.
- **Workload Identity Federation & GCS:** Snapshot state persistence requires a Google Cloud Storage (GCS) bucket and GKE Workload Identity Federation (`PROJECT_ID.svc.id.goog`) mapping Kubernetes ServiceAccounts (`atelet` and `ate-api-server`) to IAM roles (`roles/storage.objectAdmin`, `roles/storage.bucketViewer`).
- **Container Registry:** Building from source with `ko` publishes multi-architecture images to Container Registry / Artifact Registry (`gcr.io/$PROJECT_ID/...`) for node pulls.

### Feasibility & Tools Checklist
- [x] `gcloud` CLI (Google Cloud SDK 586.0.0 present)
- [x] `kubectl` CLI (v1.35.8-dispatcher present)
- [x] `go` compiler (Go 1.27.0 present)
- [x] `ko` builder (pinned in `hack/tools/ko`, invoked via `hack/run-tool.sh ko` or `cmd/ate-setup`)
- [x] GCP IAM permissions on project (`roles/owner` / `roles/editor` granted to active identity `cnrm-barni-1.svc.id.goog`)
- [x] GCP APIs enabled (`container.googleapis.com`, `storage.googleapis.com`, `artifactregistry.googleapis.com`, `iam.googleapis.com`, `monitoring.googleapis.com`, `cloudresourcemanager.googleapis.com`)

---

## Preconditions

1. Ensure the Google Cloud SDK (`gcloud`) is authenticated with credentials that have administrative access to the target GCP project.
2. Source the environment parameters file for this run:
```bash
source docs-exploration/agent-runs/gke/params.env
```
3. Set the active GCP project and default compute region:
```bash
gcloud config set project "${PROJECT_ID}"
gcloud config set compute/region "${GCE_REGION}"
```

---

## Steps

### Step 1: Enable Required Google Cloud APIs
Enable the necessary GCP services (Kubernetes Engine, Cloud Storage, Artifact Registry, IAM, Cloud Monitoring, Cloud Resource Manager).

```bash
go run ./tools/setup-gcp enable apis \
  --project-id="${PROJECT_ID}"
```
*Why:* Required cloud control planes must be active before provisioning GKE clusters, storage buckets, or Workload Identity bindings.

### Step 2: Create GKE Cluster with Required Beta APIs and Workload Identity
Create the GKE cluster with Workload Identity enabled, Kubernetes beta certificate APIs enabled (`certificates.k8s.io/v1beta1/podcertificaterequests`, `certificates.k8s.io/v1beta1/clustertrustbundles`), Managed OpenTelemetry enabled, and nested virtualization enabled on the node pool for micro-VM sandboxing.

```bash
go run ./tools/setup-gcp create cluster \
  --project-id="${PROJECT_ID}" \
  --cluster-name="${CLUSTER_NAME}" \
  --location="${CLUSTER_LOCATION}" \
  --version="${CLUSTER_VERSION}" \
  --network="${NETWORK}" \
  --subnetwork="${SUBNETWORK}" \
  --machine-type="${NODE_MACHINE_TYPE}" \
  --enable-nested-virtualization="${ENABLE_NESTED_VIRTUALIZATION}"
```
*Why:* Agent Substrate's `podcertificate-controller` requires `ClusterTrustBundle` and `PodCertificateRequest` beta APIs which on GKE 1.36 must be explicitly enabled at cluster creation time. Nested virtualization exposes `/dev/kvm` on worker nodes.

### Step 3: Create GCS Bucket for Actor Snapshots
Create the dedicated GCS bucket with Uniform Bucket-Level Access for storing actor disk and memory snapshots.

```bash
go run ./tools/setup-gcp create bucket \
  --project-id="${PROJECT_ID}" \
  --region="${GCE_REGION}" \
  --name="${BUCKET_NAME}"
```
*Why:* State persistence and actor migrations in Substrate stream chunked snapshots directly to Google Cloud Storage.

### Step 4: Configure IAM Policy Bindings and Workload Identity
Grant GKE nodes permission to pull container images, and bind the Kubernetes ServiceAccounts (`ate-system/atelet` and `ate-system/ate-api-server`) to the snapshot bucket and project storage roles via GKE Workload Identity.

```bash
go run ./tools/setup-gcp create iam \
  --project-id="${PROJECT_ID}" \
  --project-number="${PROJECT_NUMBER}" \
  --bucket="${BUCKET_NAME}" \
  --gke-nodes=true \
  --atelet=true \
  --bucket-bindings=true
```
*Why:* Substrate uses keyless GKE Workload Identity Federation so the in-cluster pods authenticate directly with GCP APIs without storing long-lived service account keys in the cluster.

### Step 5: Provision Cloud Monitoring Dashboards
Create Google Cloud Monitoring dashboards for Substrate gRPC server latency/QPS, snapshot performance, and routing telemetry.

```bash
go run ./tools/setup-gcp create dashboards \
  --project-id="${PROJECT_ID}" \
  --dashboard-dir="tools/setup-gcp/dashboards"
```
*Why:* Deploys the repository's native telemetry dashboards into Cloud Monitoring for observability.

### Step 6: Configure kubectl Credentials
Retrieve the cluster credentials into the local kubeconfig and set the context.

```bash
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --location="${CLUSTER_LOCATION}" \
  --project="${PROJECT_ID}"
```
*Why:* Configures `kubectl` and Go Kubernetes client packages to communicate with the newly created GKE cluster.

### Step 7: Build Images from Source and Deploy Substrate Control Plane
Build all Substrate container images (`cmd/ateapi`, `cmd/atecontroller`, `cmd/atelet`, `cmd/atenet`, `cmd/credential-provider/kubernetes-secrets`, `cmd/podcertcontroller`, `cmd/ateom-gvisor`) from source using `ko`, publish them to `$KO_DOCKER_REPO`, and deploy the core system (CRDs, RBAC, PostgreSQL store, apiserver, controller, atenet dataplane, and atelet DaemonSet).

```bash
PROJECT_ID="${PROJECT_ID}" \
CLUSTER_NAME="${CLUSTER_NAME}" \
CLUSTER_LOCATION="${CLUSTER_LOCATION}" \
BUCKET_NAME="${BUCKET_NAME}" \
KO_DOCKER_REPO="${KO_DOCKER_REPO}" \
./hack/install-ate.sh --deploy-ate-system
```
*Why:* Fulfills the instruction to build directly from source using the repository's native `ko` workflow and deploys the entire Substrate control plane.

### Step 8: Label GKE Nodes with Substrate Build Version
Stamp the GKE worker nodes with the Substrate build version label so that the `atelet` DaemonSet schedules and activates on them.

```bash
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | while read -r node; do
  if [ -n "${node}" ]; then
    kubectl label node "${node}" "ate.dev/substrate-version=${VERSION}" --overwrite
  fi
done
```
*Why:* The `atelet` DaemonSet targets nodes labeled with `ate.dev/substrate-version=<version>` to ensure version consistency between node daemons and the control plane.

---

## Verify

### Verification 1: Check Control Plane Pod Rollout
Verify that all Substrate control plane pods in the `ate-system` namespace are running and ready.

```bash
kubectl rollout status deployment/ate-controller -n ate-system --timeout=120s
kubectl rollout status deployment/ate-api-server -n ate-system --timeout=120s
kubectl rollout status daemonset/atelet -n ate-system --timeout=120s
kubectl get pods -n ate-system -o wide
```

### Verification 2: Verify Beta APIs and CRD Installation
Verify that the `podcertificaterequests` and `clustertrustbundles` beta APIs are active and all Substrate CRDs are registered.

```bash
kubectl get clustertrustbundles
kubectl get crd | grep ate.dev
```

### Verification 3: Build and Deploy Verification Demo (Counter)
Build and deploy the stateful counter demo application from source to test WorkerPool provisioning, snapshot storage in GCS, and the ate API.

```bash
PROJECT_ID="${PROJECT_ID}" \
BUCKET_NAME="${BUCKET_NAME}" \
KO_DOCKER_REPO="${KO_DOCKER_REPO}" \
./hack/install-ate.sh --deploy-demo-counter
```

### Verification 4: Build kubectl-ate CLI and Test Actor Lifecycle
Build the `kubectl-ate` CLI plugin and create an actor instance from the deployed counter template to confirm end-to-end functionality.

```bash
make build-atectl
./bin/kubectl-ate get actor-templates -a ate-demo-counter
./bin/kubectl-ate create actor "test-counter-1" -a ate-demo-counter --template counter
./bin/kubectl-ate get actors -a ate-demo-counter
```

---

## Teardown

### Teardown 1: Delete Demos and In-Cluster Substrate Resources
Remove all running demo actors, WorkerPools, and Substrate control plane components from the GKE cluster.

```bash
./hack/install-ate.sh --delete-all
```

### Teardown 2: Clean and Delete GCS Snapshot Bucket
Empty all stored actor snapshots and delete the snapshot bucket.

```bash
gcloud storage rm --recursive "gs://${BUCKET_NAME}/**" --project="${PROJECT_ID}" --quiet || true
gcloud storage buckets delete "gs://${BUCKET_NAME}" --project="${PROJECT_ID}" --quiet || true
```

### Teardown 3: Revoke IAM and Workload Identity Bindings
Remove the Workload Identity and node IAM bindings created for the project.

```bash
WI="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/ate-system/sa"

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="${WI}/atelet" \
  --role="roles/storage.objectAdmin" \
  --condition=None --quiet || true

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="${WI}/atelet" \
  --role="roles/artifactregistry.reader" \
  --condition=None --quiet || true

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/storage.objectViewer" \
  --condition=None --quiet || true

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader" \
  --condition=None --quiet || true
```

### Teardown 4: Delete Monitoring Dashboards
Delete the Cloud Monitoring dashboards created for Substrate.

```bash
DASHBOARDS=(
  "Substrate Snapshot Size & QPS"
  "Substrate Routing & E2E Latency"
  "Substrate gRPC Server — latency / QPS / errors"
)
for name in "${DASHBOARDS[@]}"; do
  for id in $(gcloud monitoring dashboards list --project="${PROJECT_ID}" --filter="displayName=\"${name}\"" --format="value(name)" 2>/dev/null); do
    gcloud monitoring dashboards delete "${id}" --project="${PROJECT_ID}" --quiet || true
  done
done
```

### Teardown 5: Delete GKE Cluster
Delete the GKE cluster.

```bash
gcloud container clusters delete "${CLUSTER_NAME}" \
  --location="${CLUSTER_LOCATION}" \
  --project="${PROJECT_ID}" \
  --quiet
```
