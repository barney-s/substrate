# Substrate Object Model and Actor Architecture

## 1. Architectural Model: Dual-Tier Object Hierarchy

Substrate partitions its object model into two distinct tiers based on frequency of state transitions, persistence constraints, and latency targets (`docs/architecture.md:210-260`, `docs/glossary.md:8-50`):

1. **System Configuration (Kubernetes Custom Resources)**: Declares physical compute capacity, node-level runtime dependencies, and storage integrations. These resources are stored in `etcd`, reconciled asynchronously via standard Kubernetes controllers (`atecontroller`), and subject to standard Kubernetes RBAC and admission validation.
2. **Dynamic Workload State (Control Plane Records)**: Governs individual agent instances, blueprints, snapshots, and routing state. These records are stored in a high-performance PostgreSQL database managed by `ate-api-server` (`cmd/ateapi/internal/store/atepg/`) and accessed over gRPC (`pkg/proto/ateapipb/ateapi.proto:24-147`). 

### Why the Control Plane Bypasses Kubernetes `etcd` for Actors
* **Scale Target**: Substrate targets up to 1 billion total actors (active and suspended) with high churn (`docs/architecture.md:113-117`, `metrics/substrate.yaml:135`). Managing individual actor objects in Kubernetes `etcd` would exhaust cluster storage and controller watch streams.
* **Latency Target**: Actor resumption has a target latency of 100ms at p95 (`docs/architecture.md:111`). Relying on the Kubernetes API server, scheduler, and container startup sequence introduces multi-second convergence latency.
* **Decoupled Execution**: Physical compute (`WorkerPool` standby pods running the `ateom` herder) is pre-warmed. Actors are scheduled and multiplexed onto these ready workers dynamically.

---

## 2. Complete Inventory of Substrate Objects

### Kubernetes CRDs (`ate.dev/v1alpha1`)

| Object | Scope | Definition | Purpose |
| :--- | :--- | :--- | :--- |
| **`WorkerPool`** | Namespaced | `pkg/api/v1alpha1/workerpool_types.go:129` | Declares warm compute capacity; reconciled into a Kubernetes `Deployment`. Sets `spec.replicas`, `spec.workerImage` (`ateom-gvisor` or `ateom-microvm`), `spec.sandboxClass`, and `spec.template.resources.limits` (which defines total shared compute capacity per worker). |
| **`SandboxConfig`** | Cluster | `pkg/api/v1alpha1/sandboxconfig_types.go:101` | Pins sandbox runtime binaries (e.g., gVisor `runsc` or Kata Containers Cloud Hypervisor firmware/kernel/pause image). Referenced by `ActorTemplate.sandboxConfig.configName`. |
| **`CSIDriverConfig`** | Cluster | `pkg/api/v1alpha1/csidriverconfig_types.go:74` | Configures CSI storage plugins and driver parameters for dynamic volume provisioning. |

### Substrate Control Plane API Objects (`ate-api-server`)

| Object | Scope | Definition | Purpose |
| :--- | :--- | :--- | :--- |
| **`Atespace`** | Global | `pkg/proto/ateapipb/ateapi.proto:735` | Global logical boundary and namespace. Actors, templates, and tags belong to an Atespace. Cannot be deleted while containing resources (`cmd/ateapi/internal/controlapi/atespace.go`). |
| **`ActorTemplate`** | Atespace | `pkg/proto/ateapipb/ateapi.proto:26`, `docs/api-guide.md:112-389` | Immutable workload blueprint. Specifies container specs, resource limits (`cpu`, `memory`), sandbox class, volumes (`DurableDir`, `systemInfo`, external CSI volumes), and snapshot scopes (`onPause`, `onCommit`, `onResume`). |
| **`Actor`** | Atespace | `pkg/proto/ateapipb/ateapi.proto:361` | Dynamic stateful instance derived from an `ActorTemplate`. Moves between workers and object storage across its lifecycle. |
| **`Tag`** | Atespace | `pkg/proto/ateapipb/ateapi.proto:704` | Standalone snapshot checkpoint object created from a suspended Actor. Acts as an immutable alias and retention pin. |
| **`EgressPolicy`** | Actor (nested) | `pkg/proto/ateapipb/ateapi.proto:401` | Policy nested under an Actor (`default`) setting host, CIDR, and TLS MITM credential-injection egress rules (`docs/egress-traffic.md`). |
| **`Worker`** | Global | `pkg/proto/ateapipb/ateapi.proto:77` | Control-plane record tracking a physical worker pod's registration, remaining capacity, status, and current actor slot assignments. |

---

## 3. The `Actor` Object Specification

The `Actor` message (`pkg/proto/ateapipb/ateapi.proto:361-396`) defines the stateful execution unit:

```protobuf
message Actor {
  ResourceMetadata metadata = 1;
  ObjectRef actor_template = 4;
  Selector worker_selector = 5;
  ObjectRef source_tag = 6;
  ActorStatus status = 7;
}
```

### Parameters and Fields

* **`metadata` (`ResourceMetadata`, `pkg/proto/ateapipb/ateapi.proto:239-295`)**:
  * `atespace` (`string`, required on create, immutable): Logical isolation domain.
  * `name` (`string`, required on create, immutable): DNS-1123 label uniquely identifying the actor within the atespace.
  * `uid` (`string`, server-managed): UUID assigned at creation; immutable.
  * `version` (`int64`, server-managed): Monotonically increasing version counter required as a precondition on updates and guarded deletes (`cmd/ateapi/internal/controlapi/actor.go:256`).
  * `create_time` and `update_time` (timestamps, server-managed).
* **`actor_template` (`ObjectRef`, required, mutable)**: References `(atespace, name)` of the `ActorTemplate` defining the workload. Can be mutated while the actor is suspended to upgrade or change the template, provided storage volume definitions remain compatible (`cmd/ateapi/internal/controlapi/actor.go:380`).
* **`worker_selector` (`Selector`, optional, mutable)**: Map of `match_labels` evaluated via `AND` with the template's `workerSelector` against `WorkerPool.metadata.labels` during scheduling (`docs/api-guide.md:374-380`). Changes take effect on the next `ResumeActor` call.
* **`source_tag` (`ObjectRef`, optional, immutable)**: Pointer to an existing `Tag` (`atespace`, `name`) to clone the actor from. When set, the actor borrows the tag's snapshot without immediate duplication until its own first suspend (`docs/api-guide.md:503`).
* **`status` (`ActorStatus`, server-managed, `pkg/proto/ateapipb/ateapi.proto:543-611`)**:
  * `state` (`ActorState` enum): Current lifecycle state.
  * `worker_assignment` (`WorkerAssignment`): Details of the assigned physical pod (`worker_pod`, `worker_pod_ip`, `worker_namespace`, `worker_pool`, `node_name`). Unset when not running.
  * `external_snapshot` (`ExternalSnapshot`): Snapshot URI in cloud storage, snapshot content scope (`Full` vs. `Data`), and the originating `actor_template_uid`.
  * `local_snapshot` (`LocalSnapshot`): Checkpoint name and node VM identity for fast-resume node-local pause checkpoints.
  * `actor_volumes` (`repeated ExternalVolume`): Attached CSI external volumes.
  * `crash` (`ActorCrash`): Reason and timestamp when entering `ACTOR_STATE_CRASHED`.

### Actor Lifecycle States

```
                +-------------------+
                |      Created      |
                +---------+---------+
                          | (starts in SUSPENDED)
                          v
        +-----------> SUSPENDED <-----------+
        |                  |                |
(SuspendActor)       (ResumeActor)     (RevertActor)
        |                  v                |
        |               RESUMING            |
        |                  |                |
        |                  v                |
    PAUSED <==========> RUNNING =========> CRASHED
 (node-local)              |       (failure / eviction)
                           v
                       DELETING
```

Lifecycle execution rules:
* **Suspend**: Checkpoints process state and writable rootfs overlay/volumes to cloud storage (`workflow_suspend.go:41`). Releases worker allocation.
* **Pause**: Creates a node-local checkpoint on the worker's host node VM without uploading to object storage (`workflow_pause.go:37`). Subsequent resumes on the same node achieve lower latency.
* **Eviction Deadline**: If a worker pod is evicted by Kubernetes, the hosted actor receives `SIGTERM` and has 30 minutes to suspend cleanly before moving to `ACTOR_STATE_CRASHED` (`docs/api-guide.md:455-458`).
* **Revert**: `RevertActor` resets an actor from `RUNNING`, `PAUSED`, or `CRASHED` back to `ACTOR_STATE_SUSPENDED` using its last committed `external_snapshot` (`cmd/ateapi/internal/controlapi/workflow_revert.go:50`).

---

## 4. The `Tag` Object

`Tag` is an explicit, first-class resource in Substrate (`pkg/proto/ateapipb/ateapi.proto:704-731`, `cmd/kubectl-ate/internal/cmd/tag.go:81`).

### Purpose & Storage Lifecycle
* **Snapshot Retention Pin**: Each suspend of an actor overwrites its previous external snapshot. To preserve a specific checkpoint, a caller tags the suspended actor using `CreateTag`. Substrate copies the snapshot into tag-owned storage:
  ```
  <storage_location>/atespaces/<atespace>/tags/<tag_uid>/
  ```
* **Decoupled Lifetime**: Once copied, deleting or resuming the source actor does not affect the tag. Deleting the tag deletes its underlying storage (`docs/api-guide.md:358-372`).
* **Scope (`TagScope`)**:
  * `TAG_SCOPE_ATESPACE`: Usable for cloning only within the same atespace.
  * `TAG_SCOPE_PUBLISHED`: Usable for cloning across any atespace in the cluster.
* **Golden Snapshots**: When an `ActorTemplate` is created, the control plane boots a temporary golden actor, checkpoints it, and publishes the resulting snapshot as a `Tag` in the internal `ate-golden` atespace (`internal/resources/actor.go:23`, `docs/api-guide.md:437-445`). Subsequent actors created under that template default to seeding from this golden tag.

---

## 5. Declarative vs. Imperative Modality

Substrate employs a hybrid operational model:

1. **Declarative**:
   * `WorkerPool`, `SandboxConfig`, and `CSIDriverConfig` are Kubernetes manifests applied declaratively via `kubectl apply -f`. Controllers reconcile actual pod and runtime states to match desired state.
   * `ActorTemplate` specifications are declarative workload definitions (containers, volumes, memory limits), but they are registered via the gRPC control-plane API (`CreateActorTemplate`) and are strictly immutable once created.
2. **Imperative & Event-Driven**:
   * `Actor` and `Tag` resources are registered and transitioned imperatively via gRPC RPCs or CLI commands.
   * While state is maintained in persistent records, actors do not follow a declarative reconciliation loop against static manifests. Transitions are event-driven: traffic hitting `atenet-router` with the header `ate-target-actor: <atespace>/<actor>` triggers an on-demand `ResumeActor` workflow through the control plane (`docs/architecture.md:320-335`).
   * Updates to mutable fields on an `Actor` require optimistic concurrency guards (`metadata.uid` and `metadata.version`).

---

## 6. CLI Usage (`kubectl-ate`)

The `kubectl-ate` plugin exposes operational controls for Actors and Tags (`cmd/kubectl-ate/internal/cmd/`):

```bash
# Manage Actors
kubectl ate create actor my-agent --atespace demo --template demo/agent-tmpl-v1
kubectl ate get actors --atespace demo
kubectl ate get actors -A
kubectl ate resume actor my-agent --atespace demo
kubectl ate suspend actor my-agent --atespace demo
kubectl ate pause actor my-agent --atespace demo
kubectl ate revert actor my-agent --atespace demo
kubectl ate logs actor my-agent --atespace demo -f
kubectl ate delete actor my-agent --atespace demo

# Manage Tags
kubectl ate create tag v1-checkpoint --atespace demo --actor my-agent --scope atespace
kubectl ate get tags --atespace demo
kubectl ate update tag v1-checkpoint --atespace demo --scope published
kubectl ate delete tag v1-checkpoint --atespace demo

# Clone Actor from Tag
kubectl ate create actor my-clone --atespace demo --template demo/agent-tmpl-v1 --tag demo/v1-checkpoint
```

---

## 7. Open Architectural Items & Unresolved Areas

* **Tag Deletion Protection**: An actor cloned from a tag borrows the tag's snapshot URI until the actor's first suspend. Deleting the tag while borrowed leaves the clone unable to resume; deletion prevention or automatic cloning on delete is not yet enforced (`docs/api-guide.md:507`).
* **Self-Contained Actor vs. Template Pointer**: The protobuf schema notes a pending architectural decision on whether Actors should remain pointers to an `ActorTemplate` or transition to self-contained specifications (`pkg/proto/ateapipb/ateapi.proto:368`).
* **Worker Autoscaling**: Standby worker pods currently rely on static replicas or external Horizontal Pod Autoscaling; dynamic cluster scaling tied directly to pending actor resumption rate is planned but unresolved (`docs/architecture.md:89-91`, `docs/roadmap.md:25`).
* **Control Plane Authorization**: `ate-api-server` implements authentication (mTLS / tokens) but full multi-tenant authorization policy (RBAC for actors and templates) remains in design (`docs/architecture.md:95-97`, `docs/authentication.md`).
