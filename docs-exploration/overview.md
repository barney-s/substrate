# Overview

*Derived from code at `c7b54699` (2026-09-26).*

## What it is

Agent Substrate ("ate") is a runtime on top of Kubernetes. It runs a large
number of mostly-idle, sandboxed workloads, called **actors**, on a much smaller
pool of pre-started Kubernetes pods, called **workers**. An idle actor is
**suspended**: its memory, rootfs changes and data volumes are snapshotted to
GCS or S3 and its worker is freed. When traffic or an API call arrives, the
actor is **resumed**: restored from the snapshot onto any free worker, in well
under a second, with no pod scheduling on the hot path.

It is aimed at AI agents (coding sandboxes, MCP servers, ADK and LangChain
agents), but anything that sits idle most of the time and tolerates
checkpoint/restore fits. It is a runtime, not an agent SDK. Downstream users
named in the README are google/ax (Agent Executor) and kagent.

## Why it exists

- **Pods are too slow and too expensive for this shape of workload.** Creating
  a pod goes through the scheduler, the kubelet and image pulls, and every idle
  pod still holds memory. Substrate keeps a warm fleet of pods (`WorkerPool`)
  and moves actor *state* in and out of them instead.
- **etcd cannot absorb the write rate.** Actor lifecycle state changes many
  times per second, so it lives in Postgres behind a dedicated gRPC API
  (`ateapi`), not in Kubernetes objects. Kubernetes still owns the slow,
  infrastructure-level things: worker Deployments, nodes, certificates.
- **Untrusted code needs strong isolation.** Every actor runs in a sandbox:
  gVisor (`runsc`) by default, or a Kata + Cloud Hypervisor micro-VM. Each
  sandbox has its own network namespace, and all ingress and egress goes
  through mTLS tunnels.

## The core idea, in one flow

1. An admin installs ate and creates a `WorkerPool`. atecontroller turns it
   into a Deployment of worker pods, each running an `ateom` process.
2. A developer creates an `ActorTemplate`: the images, sizing, snapshot
   policy and `SandboxConfig`. ateapi boots it once and captures a **golden
   snapshot**.
3. A user creates an actor. It starts `SUSPENDED` and costs nothing but a row
   in Postgres.
4. A request carrying `ate-target-actor: <atespace>/<actor>` reaches the
   router, which calls `ResumeActor`. ateapi picks a worker. atelet on that
   node downloads the snapshot and has ateom restore it. The router then
   tunnels the request to the worker.
5. Later, `SuspendActor` (full snapshot to object storage) or `PauseActor`
   (snapshot kept on the node's disk) frees the worker.

## Maturity (as of 2026-09-26)

- Early. The README says APIs will change and nothing is production-ready.
  `docs/architecture.md` opens with "much of this architecture is
  aspirational".
- **What works end to end:** CI runs the counter demo on both gVisor and
  micro-VM on kind with KVM, plus the egress, networking, parking, identity, and
  multiactor e2e suites.
- **Not yet enforced:**
  - Authorization: an OpenFGA server is started but never consulted.
- **Multi-Actor Workers:**
  - Support for multi-actor workers is now fully implemented. Workers can host multiple sandboxed actors concurrently (up to `--max-actors`, defaulting to 1000) using isolated network namespaces and per-actor cgroups.
- **Churn is concentrated in** `cmd/ateapi`, `cmd/ate-setup`, `cmd/ateom-gvisor`, `cmd/ateom-microvm`, and `cmd/atelet`.

## Vocabulary you need

| Term | Meaning |
|---|---|
| Atespace | Global namespace for actors and templates; not a k8s namespace |
| ActorTemplate | Immutable actor "class" stored in Postgres; produces the golden snapshot |
| WorkerPool / SandboxConfig | Kubernetes CRDs (`pkg/api/v1alpha1`): warm pods, and the sandbox runtime binaries |
| Snapshot scope | `Full` (memory + rootfs delta + volumes) or `Data` (DurableDir volumes only) |
| Pause vs Suspend | The snapshot stays on the node vs is uploaded to object storage |

See `architecture.md` for components and data flow, and `code-map.md` for where
things live.
