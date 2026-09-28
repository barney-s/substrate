#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${ROOT_DIR}"

source "${SCRIPT_DIR}/params.env"

# Step 1: Enable required GCP APIs
go run ./tools/setup-gcp enable apis \
  --project-id="${PROJECT_ID}"

# Step 2: Create GKE Cluster with required beta APIs & Workload Identity
go run ./tools/setup-gcp create cluster \
  --project-id="${PROJECT_ID}" \
  --cluster-name="${CLUSTER_NAME}" \
  --location="${CLUSTER_LOCATION}" \
  --version="${CLUSTER_VERSION}" \
  --network="${NETWORK}" \
  --subnetwork="${SUBNETWORK}" \
  --machine-type="${NODE_MACHINE_TYPE}" \
  --enable-nested-virtualization="${ENABLE_NESTED_VIRTUALIZATION}"

# Step 3: Create GCS Snapshot Bucket
go run ./tools/setup-gcp create bucket \
  --project-id="${PROJECT_ID}" \
  --region="${GCE_REGION}" \
  --name="${BUCKET_NAME}"

# Step 4: Configure IAM & Workload Identity Bindings
go run ./tools/setup-gcp create iam \
  --project-id="${PROJECT_ID}" \
  --project-number="${PROJECT_NUMBER}" \
  --bucket="${BUCKET_NAME}" \
  --gke-nodes=true \
  --atelet=true \
  --bucket-bindings=true

# Step 5: Provision Cloud Monitoring Dashboards
go run ./tools/setup-gcp create dashboards \
  --project-id="${PROJECT_ID}" \
  --dashboard-dir="tools/setup-gcp/dashboards"

# Step 6: Configure kubectl Credentials
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --location="${CLUSTER_LOCATION}" \
  --project="${PROJECT_ID}"

# Step 7: Build Images from Source and Deploy Substrate Control Plane
PROJECT_ID="${PROJECT_ID}" \
CLUSTER_NAME="${CLUSTER_NAME}" \
CLUSTER_LOCATION="${CLUSTER_LOCATION}" \
BUCKET_NAME="${BUCKET_NAME}" \
KO_DOCKER_REPO="${KO_DOCKER_REPO}" \
./hack/install-ate.sh --deploy-ate-system

# Step 8: Label GKE Nodes with Substrate Build Version
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | while read -r node; do
  if [ -n "${node}" ]; then
    kubectl label node "${node}" "ate.dev/substrate-version=${VERSION}" --overwrite
  fi
done

# Verification 1: Check Control Plane Pod Rollout
kubectl rollout status deployment/ate-controller -n ate-system --timeout=120s
kubectl rollout status deployment/ate-api-server -n ate-system --timeout=120s
kubectl rollout status daemonset/atelet -n ate-system --timeout=120s
kubectl get pods -n ate-system -o wide

# Verification 2: Verify Beta APIs and CRD Installation
kubectl get clustertrustbundles
kubectl get crd | grep ate.dev

# Verification 3: Build and Deploy Verification Demo (Counter)
PROJECT_ID="${PROJECT_ID}" \
BUCKET_NAME="${BUCKET_NAME}" \
KO_DOCKER_REPO="${KO_DOCKER_REPO}" \
./hack/install-ate.sh --deploy-demo-counter

# Verification 4: Build kubectl-ate CLI and Test Actor Lifecycle
make build-atectl
./bin/kubectl-ate get actor-templates -a ate-demo-counter
./bin/kubectl-ate create actor "test-counter-1" -a ate-demo-counter --template counter
./bin/kubectl-ate get actors -a ate-demo-counter
