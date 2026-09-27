# Substrate Objects and Actor Architecture: Research and Analysis

## Context and Questions Addressed

This research note investigates the object model and compute abstraction of Agent Substrate. It covers:
1. What an **Actor** is in Substrate, its parameters, lifecycle, and runtime behavior.
2. The full inventory of configuration and state objects exposed by Substrate.
3. Whether **Tag** is an independent object or an attribute of another entity.
4. Whether these resources operate declaratively or imperatively.
5. Concrete code and documentation anchors, CLI operations, and open architectural problems.

---

## 1. Architectural Foundations: Why Substrate Uses a Dual-Tier Model

Agentic workloads spend the vast majority of their existence idle (waiting for human interaction, tool execution, or asynchronous external events) and burst with activity for short intervals (`docs/architecture.md:23-31`). Maintaining dedicated Kubernetes Pods for millions of idle agents exhausts cluster compute and memory, while spinning up fresh pods per event incurs prohibitive multi-second cold-start delays.

Substrate resolves this by decoupling the logical workload unit (**Actor**) from physical compute pods (**Workers** in a `WorkerPool`). When idle, an Actor is suspended (its memory and filesystem diff are checkpointed to object storage) and its worker slot is vacated. When traffic arrives, the Actor is restored onto a pre-warmed standby worker pod in under 100 milliseconds (`docs/architecture.md:108-111`).

Because Substrate targets scaling up to one billion actors with high state churn (`docs/architecture.md:113-117`, `metrics/substrate.yaml:134-135`), it establishes a strict split between infrastructure objects and runtime state objects (`docs/architecture.md:210-260`, `docs/glossary.md:8-50`):

1. **System Configuration (Kubernetes CRDs)**: Stored in Kubernetes `etcd` and managed via standard Kubernetes declarative tooling (`kubectl apply`).
2. **Dynamic Workload & Lifecycle State (Control Plane Records)**: Stored in a specialized PostgreSQL database managed by `ate-api-server` (`cmd/ateapi/internal/store/atepg/`) and accessed via a high-throughput gRPC API (`pkg/proto/ateapipb/ateapi.proto:24-147`).

---

## 2. Complete Inventory of Substrate Objects

### Tier 1: Kubernetes Custom Resource Definitions (`ate.dev/v1alpha1`)

| Object | Scope | Code Definition | Description |
| :--- | :--- | :--- | :--- |
| **`WorkerPool`** | Namespaced | `pkg/api/v1alpha1/workerpool_types.go:129` | Declares standby worker pod capacity. Reconciled by `atecontroller` into a standard Kubernetes `Deployment`. Sets `spec.replicas`, `spec.workerImage` (`ko://.../ateom-gvisor` or `ko://.../ateom-microvm`), `spec.sandboxClass` (`gvisor` or `microvm`), and worker pod resource limits (`spec.template.resources.limits`), which form the shared capacity envelope for hosted actors. |
| **`SandboxConfig`** | Cluster | `pkg/api/v1alpha1/sandboxconfig_types.go:101` | Pins sandbox runtime binaries (e.g., gVisor `runsc` binary or Kata Cloud Hypervisor kernel, firmware, and rootfs pause images) for a runtime family. |
| **`CSIDriverConfig`** | Cluster | `pkg/api/v1alpha1/csidriverconfig_types.go:74` | Configures CSI storage driver plugins for dynamically mounting external persistent volumes into actors. |

### Tier 2: Substrate Control Plane Objects (`ate-api-server`)

| Object | Scope | Code Definition | Description |
| :--- | :--- | :--- | :--- |
| **`Atespace`** | Global | `pkg/proto/ateapipb/ateapi.proto:735` | The logical tenant isolation boundary and namespace. Every Actor, ActorTemplate, and Tag lives within an Atespace. Cannot be deleted while containing resources (`cmd/ateapi/internal/controlapi/atespace.go`). |
| **`ActorTemplate`** | Atespace | `pkg/proto/ateapipb/ateapi.proto:26`, `docs/api-guide.md:112-389` | The immutable workload blueprint ("class"). Defines container images, commands, arguments, environment variables, resource limits (`cpu`, `memory`), sandbox class, attached volumes (`DurableDir`, `systemInfo`, CSI volumes), and snapshot scopes (`onPause`, `onCommit`, `onResume`). |
| **`Actor`** | Atespace | `pkg/proto/ateapipb/ateapi.proto:361` | The stateful, active or suspended instance of an `ActorTemplate`. |
| **`Tag`** | Atespace | `pkg/proto/ateapipb/ateapi.proto:704` | A first-class, standalone object capturing a snapshot from a suspended Actor as a stable checkpoint and retention pin. |
| **`EgressPolicy`** | Actor (nested) | `pkg/proto/ateapipb/ateapi.proto:401` | Per-actor egress authorization rules nested under the Actor as `default`. Governs destination hostnames, CIDRs, and MITM credential injection (`docs/egress-traffic.md`). |
| **`Worker`** | Global | `pkg/proto/ateapipb/ateapi.proto:77` | A database record representing an active worker pod registered by its node `atelet`. Tracks IP, node name, capacity, and current actor slot allocations. |

---

## 3. The `Actor` Deep-Dive

### Schema and Parameters

An Actor is defined in `pkg/proto/ateapipb/ateapi.proto:361-396`:

```protobuf
message Actor {
  ResourceMetadata metadata = 1;
  ObjectRef actor_template = 4;
  Selector worker_selector = 5;
  ObjectRef source_tag = 6;
  ActorStatus status = 7;
}
```

#### User-Configurable / Modifiable Fields
* **`metadata.atespace`** (`string`, required on create, immutable): Logical namespace boundary.
* **`metadata.name`** (`string`, required on create, immutable): DNS-1123 label uniquely identifying the actor within the atespace. Together, `(atespace, name)` forms the actor's primary address.
* **`actor_template`** (`ObjectRef`, required, mutable): Points to the `ActorTemplate` (`atespace`, `name`). Can be updated while the actor is suspended to change code/configuration, provided volume specifications match (`cmd/ateapi/internal/controlapi/actor.go:380`).
* **`worker_selector`** (`Selector`, optional, mutable): Map of key-value label selectors (`match_labels`). Evaluated via logical `AND` with the template's `workerSelector` against `WorkerPool.metadata.labels` during placement. Changes take effect on the next resume (`docs/api-guide.md:374-380`).
* **`source_tag`** (`ObjectRef`, optional, immutable): Pointer to an existing `Tag` (`atespace`, `name`). Seeds the actor from an existing snapshot instead of the template's golden snapshot.

#### System-Managed Fields (`metadata` and `status`)
* **`metadata.uid`** (`string`): Globally unique UUID assigned at creation.
* **`metadata.version`** (`int64`): Monotonically increasing revision number used as an optimistic locking guard for updates and deletes (`cmd/ateapi/internal/controlapi/actor.go:256`).
* **`status.state`** (`ActorState` enum, `pkg/proto/ateapipb/ateapi.proto:529-541`):
  * `ACTOR_STATE_SUSPENDED`: Hibernated in object storage; holds no worker allocation.
  * `ACTOR_STATE_RESUMING`: Worker assigned; snapshot actively streaming/restoring.
  * `ACTOR_STATE_RUNNING`: Active inside a sandbox on a worker pod.
  * `ACTOR_STATE_PAUSING` / `ACTOR_STATE_PAUSED`: Checkpointed to the worker host node's local disk (avoids object storage round-trips for quick re-animation).
  * `ACTOR_STATE_SUSPENDING`: Streaming memory and volume diffs to external storage.
  * `ACTOR_STATE_CRASHED`: Process failed or worker pod was evicted past the 30-minute deadline.
  * `ACTOR_STATE_REVERTING`: Rolling back to the last committed external snapshot.
  * `ACTOR_STATE_DELETING`: Tearing down volumes, allocations, and snapshots.
* **`status.worker_assignment`** (`WorkerAssignment`): Denormalized record of the assigned pod (`worker_pod`, `worker_pod_ip`, `worker_namespace`, `worker_pool`, `node_name`). Hot-path routing components read `worker_pod_ip` directly from this struct.
* **`status.external_snapshot`** (`ExternalSnapshot`): URI in object storage (`snapshot_uri`), scope (`Full` or `Data`), and the `actor_template_uid` under which the snapshot was captured.
* **`status.local_snapshot`** (`LocalSnapshot`): Local checkpoint UUID and node VM addresses when paused.
* **`status.actor_volumes`** (`repeated ExternalVolume`): Provisioned CSI storage volumes bound to this actor.
* **`status.crash`** (`ActorCrash`): Error diagnostics and timestamp when moving to `CRASHED`.

### Lifecycle State Machine and Workflows

```
                   +---------------------+
                   |    CreateActor      |
                   +----------+----------+
                              | (starts in SUSPENDED)
                              v
           +------------> SUSPENDED <------------+
           |                  |                  |
    (SuspendActor)      (ResumeActor)       (RevertActor)
           |                  v                  |
           |               RESUMING              |
           |                  |                  |
           |                  v                  |
       PAUSED <==========> RUNNING ==========> CRASHED
    (node-local)              |        (worker eviction / failure)
                              v
                          DELETING
```

* **Resume Workflow** (`cmd/ateapi/internal/controlapi/workflow_resume.go:68`):
  1. Validates actor state and selects an eligible worker via the scheduler based on template `sandboxClass`, remaining worker capacity, and `worker_selector`.
  2. Ensures CSI volumes are attached to the worker node.
  3. Atelet pulls the snapshot from object storage (or local disk if resuming from `PAUSED` on the same node).
  4. Ateom restores the sandbox (`runsc` restore or Cloud Hypervisor snapshot memory demand-paging).
  5. Status updates to `ACTOR_STATE_RUNNING`.
* **Suspend Workflow** (`cmd/ateapi/internal/controlapi/workflow_suspend.go:41`):
  1. Marks actor as `ACTOR_STATE_SUSPENDING`.
  2. Ateom checkpoints the running process tree / guest memory and filesystem diffs.
  3. Atelet streams the snapshot tarballs to object storage under the actor's prefix.
  4. Worker pod assignment is released, volumes detached, and status transitions to `ACTOR_STATE_SUSPENDED`.
* **Revert Workflow** (`cmd/ateapi/internal/controlapi/workflow_revert.go:50`): Discards uncommitted or crashed execution and restores the actor record to `ACTOR_STATE_SUSPENDED` pointing at its last valid `external_snapshot`.
* **Eviction Rules**: When a Kubernetes node or worker pod is drained/evicted, the hosted actor receives `SIGTERM` and a 30-minute grace window to suspend cleanly. If it fails to suspend within 30 minutes, it enters `ACTOR_STATE_CRASHED` (`docs/api-guide.md:455-458`).

### Traffic Ingress & Identity Injection
* **Substrate Router Ingress**: Clients route traffic to `atenet-router` with the header `ate-target-actor: <atespace>/<actor>` (`docs/api-guide.md:145-177`). Envoy's `ext_proc` intercepts this header, invokes `ResumeActor` if the actor is not running, and tunnels traffic to port 443 on the worker's `atunnel` proxy over mTLS.
* **SystemInfo Volume & Credentials**: Actor identity is injected into container filesystems using `systemInfo` volumes with `actorMetadata` (`name`, `atespace`, `uid`) or `trustBundle` (`docs/api-guide.md:178-236`).
* **Actor Identity Service**: The control plane provides `MintCert` and `MintJWT` RPCs (`pkg/proto/ateapipb/ateapi.proto:67-73`, `docs/api-guide.md:542-570`), allowing running actors to obtain SPIFFE mTLS certificates (`spiffe://substrate-actor.local/atespace/${atespace}/actor/${actor_name}`) or OIDC JWTs tied to their actor identity.

---

## 4. The `Tag` Object

### Is `Tag` a Separate Object?
**Yes.** `Tag` is an explicit, first-class resource in the Substrate control plane API (`pkg/proto/ateapipb/ateapi.proto:704-731`, `cmd/kubectl-ate/internal/cmd/tag.go:81`).

```protobuf
message Tag {
  ResourceMetadata metadata = 1;
  TagStatus status = 2;
  TagScope scope = 3;
  ObjectRef source_actor = 4;
}
```

### Storage and Retention Lifecycle
* **Overcoming Overwrites**: An Actor keeps only its most recent snapshot. Every subsequent suspend overwrites the previous snapshot. To preserve a specific checkpoint, a caller creates a `Tag` referencing the suspended actor (`CreateTag`).
* **Storage Independence**: Substrate copies the snapshot bytes from the actor's prefix into tag-owned storage:
  ```
  <storage_location>/atespaces/<atespace>/tags/<tag_uid>/
  ```
  Deleting or modifying the source actor cannot garbage-collect or corrupt this tag snapshot (`docs/api-guide.md:358-372`).
* **Scope**:
  * `TAG_SCOPE_ATESPACE`: Usable for cloning only by actors in the same atespace.
  * `TAG_SCOPE_PUBLISHED`: Available to actors across any atespace in the cluster.
* **Golden Snapshots**: When an `ActorTemplate` is created, Substrate runs a temporary golden actor boot, snapshots it, and publishes the result as a `Tag` in the reserved `ate-golden` atespace (`internal/resources/actor.go:23`, `docs/api-guide.md:437-445`). New actors created without an explicit `source_tag` seed from this golden tag.

---

## 5. Declarative vs. Imperative Modality

Substrate implements a hybrid operational model:

### 1. Pure Declarative (Kubernetes CRDs)
`WorkerPool`, `SandboxConfig`, and `CSIDriverConfig` follow standard Kubernetes declarative patterns:
* Applied using `kubectl apply -f manifest.yaml`.
* Continuously reconciled by `atecontroller` towards desired state.

### 2. Declarative Blueprint, Imperative Registration (`ActorTemplate`)
* The configuration of an `ActorTemplate` (containers, limits, snapshot triggers, volumes) is fully declarative.
* However, because it lives in PostgreSQL rather than Kubernetes, it is registered via `CreateActorTemplate` (`kubectl ate create actor-template`).
* It is strictly **immutable** once registered: changes require declaring a new template version (e.g. `v2`).

### 3. Dynamic and Lifecycle-Driven (`Actor`, `Tag`, `EgressPolicy`)
* Actors and Tags are structured objects with declarative validation schemas (`+k8s:...` tags in protobuf), but their lifecycles are **imperative and event-driven**:
* Actors do not converge against an "intended state" manifest. Instead, they transition between lifecycle states in response to network traffic (`atenet-router`) or explicit API calls (`ResumeActor`, `SuspendActor`, `PauseActor`, `RevertActor`, `CreateTag`).
* Mutations to existing actors rely on optimistic concurrency guards (`metadata.uid` and `metadata.version`).

---

## 6. Concrete CLI Operations (`kubectl-ate`)

The `kubectl-ate` CLI plugin (`cmd/kubectl-ate/internal/cmd/`) exposes actor and tag workflows:

```bash
# --- Actor Operations ---
# Create an actor under an atespace referencing an ActorTemplate
kubectl ate create actor agent-001 --atespace team-a --template team-a/python-agent-v1

# List actors in one atespace or across all atespaces
kubectl ate get actors --atespace team-a
kubectl ate get actors -A

# Inspect an actor and view its assigned worker pod
kubectl ate get actor agent-001 --atespace team-a

# Manually resume an actor onto physical compute
kubectl ate resume actor agent-001 --atespace team-a

# Stream logs directly from the assigned worker pod container
kubectl ate logs actor agent-001 --atespace team-a -f

# Suspend the actor to durable cloud storage
kubectl ate suspend actor agent-001 --atespace team-a

# Pause the actor locally on the worker's node VM
kubectl ate pause actor agent-001 --atespace team-a

# Revert a running, paused, or crashed actor back to its last snapshot
kubectl ate revert actor agent-001 --atespace team-a

# Delete an actor
kubectl ate delete actor agent-001 --atespace team-a

# --- Tag Operations ---
# Tag the current snapshot of a suspended actor
kubectl ate create tag v1-release --atespace team-a --actor agent-001 --scope atespace

# List tags
kubectl ate get tags --atespace team-a

# Promote tag to published scope (cross-atespace access)
kubectl ate update tag v1-release --atespace team-a --scope published

# Delete a tag and collect its storage
kubectl ate delete tag v1-release --atespace team-a

# --- Forking / Cloning ---
# Seed a new actor from an existing tag checkpoint
kubectl ate create actor agent-fork --atespace team-a --template team-a/python-agent-v1 --tag team-a/v1-release
```

---

## 7. Unresolved Architectural Items and Open Questions

1. **Tag Deletion Cascade & Borrowed Snapshot Safety**:
   * An actor created from a tag borrows the tag's snapshot URI until the actor's first suspend (`docs/api-guide.md:503-508`). Deleting the tag while an actor is still borrowing that snapshot leaves the actor unrecoverable. Prevention logic or reference counting on tags is currently unresolved.
2. **Self-Contained Actor vs. Template Pointer**:
   * `pkg/proto/ateapipb/ateapi.proto:368` contains an explicit TODO: `"replace with full actor_template spec if we decide to make each Actor self-contained."` Currently, actors are references to templates, requiring template volume immutability checks when templates change.
3. **Dynamic Worker Autoscaling**:
   * Standby worker pods are provisioned as static replicas or via standard Kubernetes HPA. Substrate lacks an integrated autoscaler to scale `WorkerPool` pods up and down based on pending actor resumption rates and burst demand (`docs/architecture.md:89-91`, `docs/roadmap.md:25`).
4. **Control Plane Authorization (RBAC)**:
   * `ate-api-server` authenticates requests (mTLS via pod certificates, tokens), but fine-grained authorization (e.g. per-Atespace or actor-to-actor ACL policies) is not yet implemented (`docs/architecture.md:95-97`, `docs/roadmap.md:45-47`).
5. **Hardware Acceleration (GPU Passthrough)**:
   * Device passthrough to actor sandboxes is temporarily disabled pending design of a container-targeted device sharing and migration API (`docs/api-guide.md:92-100`).
6. **Per-Sandbox Storage Limits**:
   * While microVM sandboxes support multiple `DurableDir` mounts via virtio-fs subdirectories, gVisor sandboxes currently support only a single durable directory mount (`docs/glossary.md:86-96`, `docs/api-guide.md:124`).
