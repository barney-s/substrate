#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${ROOT_DIR}"

source "${SCRIPT_DIR}/params.env"

# Teardown 1: Delete Demos and In-Cluster Substrate Resources
./hack/install-ate.sh --delete-all || true

# Teardown 2: Clean and Delete GCS Snapshot Bucket
gcloud storage rm --recursive "gs://${BUCKET_NAME}/**" --project="${PROJECT_ID}" --quiet || true
gcloud storage buckets delete "gs://${BUCKET_NAME}" --project="${PROJECT_ID}" --quiet || true

# Teardown 3: Revoke IAM and Workload Identity Bindings
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

# Teardown 4: Delete Monitoring Dashboards
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

# Teardown 5: Delete GKE Cluster
gcloud container clusters delete "${CLUSTER_NAME}" \
  --location="${CLUSTER_LOCATION}" \
  --project="${PROJECT_ID}" \
  --quiet
