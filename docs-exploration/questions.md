# Open questions

*Opened 2026-09-23 against `985c2002`. Remove an entry once it is answered.*

## Behavior the code leaves ambiguous

- **Can finalize steps overwrite CRASHED?** Some writes never check the state
  they overwrite:
  - `ensureSuspendedFinalized` (`workflow_suspend.go`): its doc says an
    out-of-band crash is not overwritten, yet it writes SUSPENDED without
    checking for SUSPENDING.
  - `ensurePausedFinalized`: computes `wasAlreadyCrashed`, but still writes
    PAUSED.
  - `finalizeRunning` (`workflow_resume.go`): writes RUNNING without
    re-checking RESUMING.

  Is this intentional, with the lease plus the version compare-and-swap
  judged sufficient, or is it a bug? Crash paths (`crashActor`, worker
  delete) write *without* holding the actor lease.
- **No fencing token.** Leases (`atepg/lease.go`) cancel a context when lost,
  but data writes carry no lease epoch. Is version compare-and-swap alone the
  intended guarantee?
- **When will authorization be enforced?** `authz.NewServer` (OpenFGA +
  `internal/authz/model.fga`) runs migrations at ateapi start, but no request
  path calls Check; there are only `TODO(authz)` markers. Until then, any
  authenticated principal can call any RPC.
- **Multi-actor workers.** The scheduler, `WorkerResources.actors` and
  `HasRoom` all model N actors per worker, but `internal/ateomcapacity` hard-codes
  `actorsPerAteom = 1`, and the glossary says "at most one". Is N>1 planned,
  and which ateom changes does it need?
- **atelet → ateom uses insecure gRPC** over a hostPath unix socket
  (`cmd/atelet/main.go` `DialAteomPod`). Is filesystem permission on the
  shared BasePath the intended boundary?
- **The agentgateway dataplane path in Go.**
  `atenet router --atenet-dataplane=agentgateway` exists (`dataplane.go`),
  but the shipped `components/agentgateway` kustomize component removes the
  atenet container entirely. Is the Go path dead, or meant for another
  layout?
- **Parking retry codes.** In `atenet/.../resumer.go`, the `withParking`
  comment says only ResourceExhausted becomes retryable. `retryable()` also
  retries FailedPrecondition and Unavailable, and another comment says
  FailedPrecondition no longer means saturation. Which is intended?

## Docs vs code disagreements

These are noted, not fixed; the notes branch does not edit upstream docs.

- `internal/proto/ateompb/ateom.proto` still describes the micro-VM as future
  work, and says ateom downloads snapshots and fetches runsc. In the code,
  atelet does both, and `ateom-microvm` ships and is tested in CI.
  (`docs/architecture.md` "Sandbox Classes" matches the code.)
- `cmd/ateapi/internal/store/store.go` says `UpdateActor` is transactional
  and retries `mutate`. `atepg.UpdateActor` does one read and one
  compare-and-swap, with no transaction and no retry.
- `docs/request-parking.md` names `AssignWorkerStep`, which does not exist.
  The code is `ensureWorkerAssigned` / `assignWorkerAttempt`.
- `internal/ateompath/ateompath.go` has several stale comments:
  - it says gVisor Data snapshots use fscheckpoint, but the code does
    pause+tar;
  - it mentions a `-direct` flag and `CredentialBrokerSocket`, neither of
    which exists;
  - it gives the asset name as `gvisor.tar.bz2`, but `sandbox_assets.go`
    says `.zstd`.
- `cmd/atenet/README.md` lists only `router`. It omits `sdsmint`, egress mode
  and agentgateway.
- `scheduling.Schedule`'s doc says it returns a "free worker", but it
  actually returns a worker with remaining capacity.
