TORN-DOWN

## Teardown Summary

- **Instance Name:** `instance1`
- **Resource Prefix:** `substrat-instance1`
- **GCP Project:** `barni-cnrm-20260529` (Project Number: `77658989016`)
- **Execution Date:** 2026-09-27 16:26 UTC

---

## Removed Resources & Verification Evidence

1. **GKE Cluster & Node Pool:**
   - Cluster `substrat-instance1` (`us-central1-a`, 2x `c3-standard-4` VMs) deleted cleanly via GKE deletion operation `operation-1790525935472-a880a90a-7b7f-424c-b133-5f4726a3b141` (`status: DONE`).
   - Verification: `gcloud container clusters list --project=barni-cnrm-20260529 --filter="name=substrat-instance1"` returned 0 matching clusters.

2. **GCS Snapshot Bucket & IAM Policy Bindings:**
   - Bucket `gs://substrat-instance1-snap-77658989016` and all contained snapshot objects deleted.
   - Bucket IAM policy bindings for `atelet` and `ate-api-server` removed.
   - Verification: `gcloud storage buckets list --project=barni-cnrm-20260529 --filter="name ~ substrat-instance1"` returned 0 items.

3. **Compute Engine Disks & Instances:**
   - Node boot disks (`gke-substrat-instanc-substrate-node-p-47554b72-*`, 2x 100GB) and PostgreSQL persistent disk (`pvc-ea7bea9c-105f-4a5c-9069-cdb134592e0b`, 500GB) deleted.
   - Compute instances deleted.
   - Verification: `gcloud compute disks list --project=barni-cnrm-20260529 --filter="name ~ substrat-instance1 OR labels.repo-agent-instance=substrat-instance1"` returned 0 items.
   - Verification: `gcloud compute instances list --project=barni-cnrm-20260529 --filter="name ~ substrat-instance1 OR labels.repo-agent-instance=substrat-instance1"` returned 0 items.

4. **Container Images:**
   - All container images and manifests published for this instance under `us-docker.pkg.dev/barni-cnrm-20260529/gcr.io/substrat-instance1` (`ateapi`, `atecontroller`, `atelet`, `atenet`, `ateom-gvisor`, `counter`, `podcertcontroller`) deleted.
   - Verification: `gcloud artifacts docker images list us-docker.pkg.dev/barni-cnrm-20260529/gcr.io/substrat-instance1` and `gcloud container images list --repository=gcr.io/barni-cnrm-20260529/substrat-instance1` both returned 0 items.

5. **Networking & Firewall Rules:**
   - Verification: `gcloud compute forwarding-rules list`, `gcloud compute backend-services list`, `gcloud compute target-pools list`, and `gcloud compute firewall-rules list` confirmed no residual resources matching `substrat-instance1`.

---

## Remaining Resources

None belonging to `substrat-instance1`. Shared project-level Workload Identity IAM bindings for `atelet` and compute service accounts were deliberately left intact per the teardown contract as they are shared with other Substrate instances in the project.

---

## Procedure amended

Amended `docs-exploration/runbooks/deploy-gcp.md` (and `teardown.sh`):
1. **Cluster accessibility check in control plane removal:** Added a check verifying cluster presence before executing `hack/install-ate.sh --delete-all` so teardown reruns or runs following partial cluster drops do not fail on connection timeouts.
2. **Artifact Registry image listing format:** Updated image cleanup to query the Artifact Registry repository location `us-docker.pkg.dev/${PROJECT_ID}/gcr.io/${RESOURCE_PREFIX}` instead of passing `KO_DOCKER_REPO` (`gcr.io/...`) directly to `gcloud artifacts docker images list`, which gcloud rejected due to invalid repository format.
