#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${ROOT_DIR}"

# 0. Source parameters and export required environment variables
source "${SCRIPT_DIR}/params.env"

export PROJECT_ID
export PROJECT_NUMBER
export GCE_REGION
export CLUSTER_LOCATION
export RESOURCE_PREFIX
export CLUSTER_NAME
export BUCKET_NAME
export KO_DOCKER_REPO
export KO_DEFAULTPLATFORMS
export NETWORK
export SUBNETWORK
export NODE_MACHINE_TYPE
export NODE_POOL_NAME
export CLUSTER_VERSION
export KUBECTL_CONTEXT
export NO_DEV_ENV

export GOCACHE=/tmp/gocache
export GOTMPDIR=/tmp/gotmp
mkdir -p "${GOCACHE}" "${GOTMPDIR}"

# 1. APIs, cluster, bucket, IAM (setup-gcp)
go run ./tools/setup-gcp enable apis
go run ./tools/setup-gcp create cluster
go run ./tools/setup-gcp create bucket
go run ./tools/setup-gcp create iam

# Label resources with repo-agent-instance where supported
gcloud container clusters update "${CLUSTER_NAME}" --location="${CLUSTER_LOCATION}" --update-labels="repo-agent-instance=${RESOURCE_PREFIX}" || true
gcloud storage buckets update "gs://${BUCKET_NAME}" --update-labels="repo-agent-instance=${RESOURCE_PREFIX}" || true

# 2. Disable autoupgrade on the worker node pool
gcloud container node-pools update "${NODE_POOL_NAME}" \
  --cluster "${CLUSTER_NAME}" --location "${CLUSTER_LOCATION}" --no-enable-autoupgrade

# 3. Fetch cluster credentials
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --location "${CLUSTER_LOCATION}" --project "${PROJECT_ID}"

# 4. Deploy Substrate control plane
hack/install-ate.sh --deploy-ate-system --rollout-timeout=300s

# 5. Deploy counter demo and install kubectl-ate CLI
hack/install-ate.sh --deploy-demo-counter
go install ./cmd/kubectl-ate
