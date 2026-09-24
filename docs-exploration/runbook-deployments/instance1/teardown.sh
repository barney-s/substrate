#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${ROOT_DIR}"

# Source parameters
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

# 1. Remove the control plane and demos (drops postgres PVC and backing PD)
hack/install-ate.sh --delete-all

# 2. Delete bucket IAM policy bindings, snapshot bucket, and cluster
hack/teardown.sh --delete-iam-policy-bindings --delete-snapshot-bucket --delete-cluster

# 3. Clean up container images pushed for this instance
for img in $(gcloud artifacts docker images list "${KO_DOCKER_REPO}" --format='value(package)' 2>/dev/null | sort -u); do
  gcloud artifacts docker images delete "${img}" --delete-tags --quiet || true
done

# 4. Verify cluster is gone
gcloud container clusters list --filter="name=${CLUSTER_NAME}"
