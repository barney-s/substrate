# Code map

*Derived from code at `985c2002` (2026-09-23). The repo has about 127k lines of non-test Go outside `vendor/`.*

## Top level

| Path | What lives there |
|---|---|
| `cmd/` | One directory per binary. Code used by only one binary lives in its `internal/` |
| `internal/` | Packages shared across binaries: auth, networking, image cache, paths, e2e framework |
| `pkg/` | Public: `api/v1alpha1` (CRDs), `client` (generated client-go), `proto/ateapipb` (the gRPC API) |
| `manifests/ate-install/` | Raw YAML, `generated/` CRDs and RBAC, kustomize `base/`, overlays (`kind`, `agentgateway*`), `components/` |
| `hack/` | Install and e2e scripts, `verify/` and `update/` generators, `boilerplate/`, pinned `tools/` |
| `tools/` | `setup-gcp` (GKE/GCS/IAM/Cloud SQL provisioning), `apitool`, `validate-image-cache` (each has its own go.mod) |
| `demos/`, `benchmarking/` | Example actors (counter, sandbox, egress) and load tests (locust, boomer, glutton) |
| `docs/` | Design docs. `docs/metrics/registry/` is the Weaver metric registry and is checked by `make verify` |
| `vendor/` | Vendored dependencies; never edit by hand |

## Binaries (entry point: `cmd/<name>/main.go`)

| Binary | Look here first |
|---|---|
| `ateapi` | `main.go` wiring → `internal/controlapi` (the API and workflows), `internal/store/atepg`, `internal/scheduling`, `internal/workercache`, `internal/workerservice` |
| `atelet` | A large `main.go` (~2k lines, holds the AteomHerder RPCs), `oci.go`, `sandbox_assets.go`, `local_checkpoints.go`, `internal/ategcs` (GCS/S3 + sparse zstd) |
| `ateom-gvisor` | `main.go` (Run/Checkpoint/Restore), `runsc.go`, `sandboxnet.go` |
| `ateom-microvm` | `run.go`, `checkpoint.go`, `restore.go`, `internal/ch` (cloud-hypervisor API), `internal/kata` |
| `atenet` | `internal/root.go` → `internal/router/{ingress,extproc,…}`, `internal/sdsmint` |
| `atecontroller` | `internal/controllers` (WorkerPool → Deployment/NetworkPolicy, MITM trust), `internal/workersync` |
| `podcertcontroller`, `credential-provider` | Small; PodCertificate signers, and `ate-secret://` resolution |
| `kubectl-ate`, `ate-setup` | `internal/cmd`; `ate-setup/internal/steps` is the install logic that `hack/install-ate.sh` calls |

## The files that matter most

Items marked ⚠ are dangerous to modify; the reason follows each one.

**API contracts**
1. `pkg/proto/ateapipb/ateapi.proto`: the public API, the `ActorState` enum,
   and the snapshot config. ⚠ Wire-compatible changes only. Regenerate with
   `hack/update-all.sh`, never by editing the `*.pb.go` files.
2. `internal/proto/ateletpb/atelet.proto` and `internal/proto/ateompb/ateom.proto`:
   the node contracts. ⚠ `SnapshotScope` is duplicated across the two files and
   mapped by hand in atelet (`toAteomSnapshotScope`). atelet and ateom versions
   can differ across a fleet.
3. `pkg/api/v1alpha1/*_types.go`: the CRDs. ⚠ Their generated output lives in
   `manifests/ate-install/generated/` and `zz_generated.*`.

**Control plane**
4. `cmd/ateapi/main.go`: every server, informer, loop and backend is wired
   here.
5. `cmd/ateapi/internal/controlapi/workflow.go`: the ensure-step pattern and
   the per-actor lease.
6. `cmd/ateapi/internal/controlapi/workflow_resume.go`: the hot path; boot
   source, scheduling, bind, restore. ⚠ The state-edge checks are spread
   across `workflow_*.go`, and there is no central table to keep them
   consistent.
7. `workflow_suspend.go`, `workflow_pause.go`, `workflow_revert.go` and
   `workflow_delete.go` in the same directory.
8. `cmd/ateapi/internal/controlapi/template_reconciler.go`: builds golden
   snapshots.
9. `cmd/ateapi/internal/store/store.go`: `store.Interface` and the
   `Precondition` semantics (uid + version compare-and-swap).
10. `cmd/ateapi/internal/store/atepg/migrations/000001_initial.sql`. ⚠ It has
    already been applied to clusters, and CI checks that migrations are
    immutable. Add a new migration instead of editing this one; see
    `docs/dev/postgresql-schema-evolution.md`.
11. `cmd/ateapi/internal/store/atepg/outbox.go`. ⚠ The worker-change outbox
    uses a subtle partitioned, UNLOGGED design that `workercache` depends on.
12. `cmd/ateapi/internal/scheduling/scheduling.go`: worker selection.

**Node dataplane**
13. `cmd/atelet/main.go`: Restore, Checkpoint, upload and download. ⚠
    `manifest.json` must be uploaded last, because it is the commit marker.
14. `cmd/atelet/sandbox_assets.go`. ⚠ `sandboxAssetsRecord` is also the durable
    snapshot manifest, so old snapshots must keep parsing.
15. `cmd/atelet/internal/ategcs/sparsezstd.go`. ⚠ The `ATESPRSE` v2 on-object
    format and `.zstd` naming are read back from existing snapshots.
16. `internal/ateompath/ateompath.go`. ⚠ This path layout is shared by atelet
    and both ateoms, and paths are baked into OCI specs and micro-VM snapshots.
17. `internal/imagecache/imagecache.go`. ⚠ On-disk layout version "1" is read
    by GC.
18. `cmd/ateom-gvisor/main.go` and `cmd/ateom-microvm/restore.go`: the sandbox
    lifecycle. ⚠ micro-VM restore rewrites cloud-hypervisor `config.json` keys
    and depends on the frozen `<baseID>/rootfs` path.
19. `internal/ateomnet/sandbox.go`: the actor netns, veth, nftables redirect
    and DNS relay.

**Networking**
20. `cmd/atenet/internal/router/ingress/ingress.go` and `resumer.go`: header
    handling, the ResumeActor singleflight, and request parking.

## Tests and verification

- `make test` runs `go test -race ./...`. Store tests use Postgres through
  testcontainers (`store/storetest`), so Docker must be available.
  `store/storecontract` holds the backend contract tests.
- `make verify` runs the tests, then `hack/verify-all.sh`: gofmt, boilerplate,
  licenses, go mod, codegen drift and the metrics registry.
- `hack/run-root-tests.sh` runs root-gated tests (netns, mounts).
- `make e2e` runs `hack/run-e2e.sh`. The suites are in `internal/e2e/suites/*`
  and need a cluster.
- CI (`.github/workflows/pr-workflow.yaml`) runs the unit and verify job, plus
  a kind + KVM e2e matrix: Envoy is required and agentgateway is allowed to
  fail.

## Dead or unwired code (as of 2026-09-23)

- `internal/cdi` and `cmd/ateom-gvisor/internal/cdiinject`: used only by tests.
- `cmd/atelet/internal/filecache`: imported only by its own tests.
- `internal/authz` (OpenFGA): started by ateapi but never queried.
