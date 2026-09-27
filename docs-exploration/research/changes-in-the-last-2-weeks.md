# Substrate Changes and Evolution (September 13 – September 27, 2026)

This document records the major changes, architectural shifts, churn distribution, breaking interface modifications, and open follow-up tasks in the [Substrate](https://github.com/agent-substrate/substrate) repository over the two-week window from September 13, 2026 to September 27, 2026.

---

## 1. Scope, Methodology, and Release Milestones

* **Window Covered:** September 13, 2026 22:35 UTC through September 27, 2026 00:00 UTC.
* **Commit Range:** `67253354..ed6d2a1f` (138 non-merge commits on `main` following commit `67253354`).
* **Tag & Release Branch:** Release tag `v0.2.0` was cut on commit `10a1bfb2` (September 25, 2026), creating branch `release-0.2`.
* **Investigation Note:** The GitHub CLI (`gh`) was unauthenticated in this environment; all analysis, pull request references, issue connections, and architectural diffs were traced directly from git history, commit metadata, code diffs, and in-repo test fixtures.

---

## 2. Core Themes

### A. Multi-Actor Worker Concurrency and Per-Sandbox Networking
Substrate previously operated on a 1:1 worker-to-actor allocation model: a worker pod ran a single actor sandbox at any given time. During this two-week window, Substrate landed multi-actor concurrency on worker nodes. A single worker pod (running `atelet` and `ateom`) now concurrently hosts multiple independent actor sandboxes. This required dedicated per-sandbox Linux network namespaces, per-actor veth interfaces, local loopback and DNS relays, per-actor cgroup slices keyed by actor UID, and a separation of directory structures passed over RPC via `ActorDirs`.

### B. Egress Security, Credential Brokering, and Dataplane Hardening
Outbound traffic from actor sandboxes transitioned from an uninspected bypass to a strictly evaluated multi-leg pipeline governed by `EgressPolicy`. The data plane (`atenet` Envoy proxy + external processing) now intercepts traffic across outer mTLS CONNECT tunnels, cleartext HTTP, and decrypted TLS MITM legs (via `sdsmint`). Matching rules can inject platform-brokered credentials (such as API keys stored in Kubernetes Secrets) without ever revealing the secrets to guest code. Unintercepted UDP egress was blocked for all destination ports except 53, closing covert QUIC/HTTP-3 bypasses. An experimental Envoy dynamic module written in Rust was introduced for in-process policy evaluation.

### C. Resilient Lifecycle Recovery (`RevertActor`) and Crash Semantics
Previously, an actor transitioning to the `CRASHED` state was in a terminal state that could only be deleted. This window introduced the `RevertActor` lifecycle RPC, allowing actors in `RUNNING`, `PAUSED`, or `CRASHED` states to safely discard corrupted execution state, cancel partial in-progress snapshots, and roll back to `SUSPENDED` at their last valid external snapshot. Concurrently, the legacy `ateerrors` taxonomy was deleted in favor of explicit fail-fast crash semantics, logging failure causes directly onto `ActorStatus`.

### D. Embedded Authorization (OpenFGA) and Relational Storage Refactoring
Fine-grained authorization was unified with the core API server. OpenFGA was embedded directly inside `ateapi`, sharing its PostgreSQL connection pool (`pgxpool.Pool`) and participating in database transactions (`pgx.Tx`). OpenFGA tables are now managed through standard Goose migrations alongside Substrate schemas (`000002_openfga.sql`). Simultaneously, the massive `atepg.go` storage file was decomposed into modular, per-resource stores.

### E. Developer Operations, Tooling, and Observability
More than 1,600 lines of brittle shell scripts in `hack/` were pruned or converted to shims delegating to `ate-setup`, a compiled Go CLI providing reproducible cluster installations, overlay management, and multi-architecture (arm64/amd64) builds. In observability, actor state transitions and usage metrics were wired to OpenTelemetry (OTel) logs with dual-write guarantees to pod stdout and OTLP collectors. The benchmarking harness gained `sweperf`, a trajectory-based workload based on realistic SWE-bench tasks.

---

## 3. Structural Architecture

The following diagram illustrates the updated runtime isolation model: multi-actor worker nodes with per-sandbox networking, split SPIFFE identities, and 3-leg egress inspection.

```mermaid
graph TD
    subgraph K8s_Worker_Pod["Worker Node / Worker Pod (atelet + ateom)"]
        direction TB
        Atelet["atelet (Daemon/Host)"]
        Ateom["ateom (gVisor runsc / microVM CLH)"]
        
        Atelet -->|"ActorDirs via RPC<br/>(ateom.proto)"| Ateom
        
        subgraph Sandbox1["Actor Sandbox 1 (UID: act-101)"]
            App1["Guest Workload 1"]
            Netns1["Dedicated netns 1<br/>(10.0.1.2)"]
            DNS1["Local DNS Relay :53"]
            App1 --> Netns1
            Netns1 --> DNS1
        end

        subgraph Sandbox2["Actor Sandbox 2 (UID: act-102)"]
            App2["Guest Workload 2"]
            Netns2["Dedicated netns 2<br/>(10.0.2.2)"]
            DNS2["Local DNS Relay :53"]
            App2 --> Netns2
            Netns2 --> DNS2
        end

        Atunnel["atunnel (Transparent TCP Intercept)"]
        Netns1 -->|"TCP Redirect (nftables)"| Atunnel
        Netns2 -->|"TCP Redirect (nftables)"| Atunnel
        Netns1 -.->|"UDP non-DNS"| DropUDP["DROP (nftables)"]
        Netns2 -.->|"UDP non-DNS"| DropUDP
    end

    subgraph Security_Identities["Cryptographic Identity Layer"]
        ActorCert["ActorSPIFFEID<br/>spiffe://.../actor/space/name<br/>(Guest Actor Identity)"]
        AteomCert["AteomForActorSPIFFEID<br/>spiffe://.../ateom-for-actor/space/name<br/>(Infrastructure Identity)"]
    end

    Atunnel -->|"mTLS with AteomForActorSPIFFEID"| EgressGW

    subgraph EgressGW["atenet Egress Gateway (Envoy + ext_proc)"]
        direction TB
        OuterConn["Leg 1: Outer CONNECT<br/>Authenticates Ateom SPIFFE ID<br/>Evaluates CIDR / Address Rules"]
        
        OuterConn --> PlainHTTP["Leg 2: Cleartext HTTP<br/>Inspects Host header"]
        OuterConn --> MITM["Leg 3: Decrypted TLS (sdsmint)<br/>Terminates TLS, validates SNI"]
        
        PolicyEngine["EgressPolicy Evaluator<br/>(internal/egresspolicy)"]
        OuterConn -.-> PolicyEngine
        PlainHTTP -.-> PolicyEngine
        MITM -.-> PolicyEngine
        
        CredInject["Credential Injector<br/>(k8s-secrets provider)"]
        MITM -->|"inject_static_headers"| CredInject
    end

    CredInject -->|"Outbound Request with Injected Auth Header"| ExternalAPI["External Services<br/>(e.g., api.openai.com)"]
```

---

## 4. Notable Changes

### 1. Multi-Actor Worker Support & Per-Sandbox Networking
* **Commits:** `14c0c136` (PR #1836), `cd102f0a` (PR #1689), `a0b680d7` (PR #1730)
* **Details:**
  - Workers support concurrent actor sandboxes. In `internal/ateomnet/sandbox.go:29`, each actor is allocated an isolated network namespace with a unique veth pair and loopback interface.
  - Dedicated local DNS forwarders run inside `internal/ateomnet/dns.go` and `internal/atunnel/dns.go`, proxying UDP and TCP DNS queries to host cluster resolvers while preventing DNS poisoning across sandboxes.
  - `ActorDirs` (`internal/proto/ateompb/ateom.proto:113-128`) decouples directory derivation between `atelet` and `ateom`, splitting paths into `cmd/atelet/internal/ateletpath` and `internal/nodepath`.
  - In `cmd/ateom-gvisor/internal/cgroupstats` and `internal/ateomcgroup/actor.go`, cgroup resource accounting is partitioned under per-actor UID leaf nodes.

### 2. Cryptographic Split Between Actor and Ateom Identities
* **Commits:** `8ea4abe1` (PR #1626), `8d6be5fb` (PR #1809), `7f7a40c1` (PR #1810), `ed6d2a1f` (PR #1923)
* **Details:**
  - `internal/resources/spiffe.go:27-108` defines two distinct SPIFFE IDs:
    - `ActorSPIFFEID`: `spiffe://substrate-actor.local/actor/<atespace>/<name>`
    - `AteomForActorSPIFFEID`: `spiffe://substrate-actor.local/ateom-for-actor/<atespace>/<name>`
  - `pkg/proto/ateapipb/ateapi.proto:2051` introduces `rpc MintAteomActorCertificate`.
  - In `cmd/ateapi/internal/authz/model.fga:87-95`, OpenFGA enforces **Node Restriction**: only the specific Kubernetes node hosting the scheduled worker pod (`can_mint_ateom_actor_credential: host_node`) may mint ateom credentials. System tunnels like `atunnel` use this certificate to communicate with `atenet` on behalf of the actor, preventing guest code from impersonating control plane infrastructure.

### 3. EgressPolicy Enforcement and Credential Injection
* **Commits:** `85ce8ed5` (PR #1360), `57234a86` (PR #1335), `30e6d33d` (PR #1535), `514e6109` (PR #1659), `d7d70420` (PR #1813), `e517df95`, `f980a57d`, `58624ee8`
* **Details:**
  - `internal/egresspolicy/egresspolicy.go:27-50` implements pure policy evaluation against normalized hostnames and CIDRs.
  - `cmd/atenet/internal/router/egress/request.go:34-50` enforces rules across three filter chain legs: outer CONNECT, cleartext HTTP, and decrypted TLS MITM.
  - When a matched rule specifies `inject_static_headers`, `cmd/credential-provider/kubernetes-secrets/` fetches credentials from Kubernetes secrets and injects them upstream.
  - `58624ee8` drops actor UDP egress to all ports except 53 via nftables forward chains, blocking QUIC/HTTP-3 bypasses of the TLS MITM proxy.
  - `30e6d33d` introduced an experimental Envoy Dynamic Module in Rust (`cmd/dataplane/envoy/dynamic-modules/egress-policy/src/lib.rs`).

### 4. `RevertActor` Lifecycle RPC and Resilient Crash Handling
* **Commits:** `944abe32` (PR #1675), `47b67574` (PR #1711), `aae7df78` (PR #1220), `e87c55fc` (PR #1867)
* **Details:**
  - Added `rpc RevertActor(RevertActorRequest)` in `pkg/proto/ateapipb/ateapi.proto:48, 1448-1457` and CLI verb `ate revert actor`.
  - Workflow in `cmd/ateapi/internal/controlapi/workflow_revert.go:31-60` safely accepts actors in `RUNNING`, `PAUSED`, or `CRASHED` state, terminates worker execution, discards uncommitted in-progress snapshots, and rolls the actor back to `SUSPENDED` at its last valid external snapshot.
  - Actors no longer consider `CRASHED` a terminal state.
  - Added `crash_reason` and `crashed_at` fields to `ActorStatus` (`pkg/proto/ateapipb/ateapi.proto:1191-1215`).

### 5. Embedded OpenFGA Engine & Migrations
* **Commits:** `b29f9777` (PR #1670), `5fb129d8` (PR #1839)
* **Details:**
  - OpenFGA was embedded directly in `cmd/ateapi/internal/authz`.
  - Tables are created and versioned via Goose migrations (`cmd/ateapi/internal/store/atepg/migrations/000002_openfga.sql`).
  - OpenFGA datastore operations reuse the application's PostgreSQL connection pool (`pgxpool.Pool`) and caller database transactions (`pgx.Tx`), preventing dual-write inconsistencies.

### 6. Pruned Shell Scripts in Favor of `ate-setup` Go Tooling
* **Commits:** `6c70d60c` (PR #1785), `d6d2a0fa` (PR #1632), `5ebccf38` (PR #1869)
* **Details:**
  - Eight `hack/install-demo-*.sh` scripts were deleted.
  - `hack/install-ate.sh` dropped 1,626 lines, functioning as a shim delegating to `cmd/ate-setup`.
  - `cmd/ate-setup` compiles as a Go CLI with typed testing for overlays, kind/GKE clusters, Cloud SQL, and multi-architecture Dockerfile image building.

### 7. Release v0.2.0 & PodCertificateRequest v1
* **Commits:** `10a1bfb2` (PR #1829), `8b5d9ff0` (PR #1874)
* **Details:**
  - Dual `v1beta1` and `v1` PodCertificateRequest (PCR) support was added in `cmd/podcertcontroller/internal/podcertificate/client.go:140-230`, favoring Kubernetes 1.37 `v1`.
  - Release `v0.2.0` was tagged and `release-0.2` branch was cut.

---

## 5. Where the Churn Is

The following table reflects the relative churn across the codebase over this two-week window (677 non-vendor files modified, 57,629 insertions, 21,694 deletions):

| Subsystem / Directory | File Churn (%) | Commits | Key Movement & Architectural Focus |
| :--- | :--- | :--- | :--- |
| **`cmd/ateapi/`** | ~14.0% | 34 | `controlapi/` added `RevertActor`, snapshot tags, crash reason recording; `store/atepg/` split `atepg.go` into per-resource files; embedded OpenFGA with Goose migrations; moved `apiauthn` into internal server package. |
| **`cmd/ate-setup/`** | ~7.0% | 12 | Completely ported install and demo scripts into Go (`steps/`, `kube/`, `demos/`, `config/`), added multi-arch arm64 support, and large-cluster sizing options. |
| **`cmd/kubectl-ate/`** | ~6.2% | 8 | Consolidated scattered verb-resource files into unified per-resource CLI definitions (`actor.go`, `actortemplate.go`, `worker.go`); added `revert actor` and `egress-policy` subcommands; switched single outputs to bare objects. |
| **`internal/e2e/`** | ~5.5% | 19 | Added new `multiactor` test suites, updated volume tests (`combinedvolumes`), added assertions for OTLP lifecycle log events and egress credential injection. |
| **`cmd/atenet/`** | ~4.8% | 15 | Implemented multi-leg `EgressPolicy` enforcement in `router/egress/` and `extproc/`; increased default route timeout from 10s to 5m; handled `unknown` resume metrics. |
| **`benchmarking/`** | ~4.5% | 11 | Added SWE-bench / SWE-perf trajectory workload (`boomer/sweperf/`); cluster hardware and density frontier discovery (`cluster_facts.py`); eliminated checked-in Python protobufs. |
| **`cmd/atelet/`** | ~4.1% | 10 | Refactored `RestoreRequest` to use typed `base_config` snapshot sources; integrated `ActorDirs`; added actor cleanup on termination; supported resolved sandbox assets. |
| **`cmd/ateom-microvm/` & `cmd/ateom-gvisor/`** | ~4.3% | 14 | Multi-actor support; Kata Assets bumped to 4.1.0 with virtiofsd 1.14.0; dropped `kata-config`; fixed runsc zombie container teardown races; per-actor cgroup trees. |
| **`internal/atunnel/`, `internal/ateomnet/`, `internal/ateomcgroup/`** | ~3.1% | 12 | Per-sandbox network namespaces, veth plumbing, local DNS relays, UDP non-DNS drop filters, and UID-keyed cgroups. |
| **`hack/`** | ~2.6% | 14 | Removed ~1,600 lines from `install-ate.sh`; deleted all `install-demo-*.sh` scripts; integrated `gotestsum` for JUnit output and test timeouts. |
| **`internal/actorevent/`, `internal/otlprelay/`, `internal/serverboot/`** | ~1.5% | 7 | OTLP log event pipeline for actor state changes (`ate.actor.state_changed`, `ate.actor.crashed`), usage sampling events (`ate.actor.usage_sampled`), and relay logging. |
| **`cmd/dataplane/envoy/` & `cmd/credential-provider/`** | ~1.5% | 5 | Envoy Dynamic Modules (Rust crate for egress policy); Kubernetes Secrets credential provider service with `statusz` health probes. |

---

## 6. Critical Interface Changes and Developer Gotchas

1. **Incompatible `RestoreRequest` Wire Format (`1d7ca8ce`):**
   `golden_snapshot_uri` was removed from `RestoreRequest` in `internal/proto/ateletpb/atelet.proto:452-479`. It is replaced by `ExternalRestoreConfiguration base_config = 12` and required field `SandboxAssets sandbox_assets = 16`. `ateapi` and `atelet` must be rolled and updated together.

2. **`kubectl-ate` Single-Resource Output Formatting (`32e08c22`):**
   `kubectl ate get <resource> <name> -o json|yaml` now emits a single un-wrapped object rather than a `{ "items": [ ... ] }` list (`cmd/kubectl-ate/internal/printer/printer.go:81-120`). Automated scripts parsing `.items[0]` will fail.

3. **Complete Removal of `internal/ateerrors` (`74bbfc52`):**
   The `ateerrors` package and its failure-reason taxonomy were deleted. Actor crash details are now stored directly in `Actor.status.crash_reason` and `Actor.status.crashed_at` (`pkg/proto/ateapipb/ateapi.proto:1191-1215`).

4. **Schema and Field Renames:**
   * `SnapshotsConfig` renamed to `SnapshotConfig` across all protos and templates (`fb4b3152`).
   * `readyz` probe in `ActorTemplate` renamed to `wakeupProbe` (`d277088b`).
   * `LocalSnapshotInfo` renamed to `LocalSnapshot` (`d72edfbb`).
   * `golden_snapshot` field in `ActorTemplateSpec` renamed to `golden_tag` (`a58481a1`).

5. **Path Package Relocations:**
   * `cmd/atelet` no longer imports `internal/ateompath`. Per-actor paths now reside in `cmd/atelet/internal/ateletpath`, while shared mounts and sockets are defined in `internal/nodepath` (`a0b680d7`).
   * Authentication configs moved from `internal/ateapiauth` to `cmd/ateapi/internal/apiauthn` (`c7b54699`).

6. **Worker Sandbox Class Immutability (`44f4000c`):**
   `UpdateWorker` rejects modifications to `sandbox_class`. Changing the isolation runtime requires creating a new worker pool.

7. **Dropped UDP Egress (`58624ee8`):**
   Actor egress for UDP traffic on ports other than 53 is now dropped at the worker veth interface. Applications attempting to establish direct QUIC/HTTP-3 connections externally must fall back to HTTP/1.1 or HTTP/2 over TCP.

---

## 7. Unresolved Follow-Ups and Open Work

While remote GitHub issues could not be retrieved over the network due to unauthenticated CLI credentials, explicit follow-up commitments and architectural gaps documented across the commits include:

| Area / Component | Unresolved Task | Background & Tracking |
| :--- | :--- | :--- |
| **Worker / `ateom` Paths** | **Switch `ateom` to read `ActorDirs` over RPC**: `atelet` now transmits `ActorDirs` during workload execution RPCs, but `ateom-gvisor` and `ateom-microvm` still derive paths via `internal/ateompath`. Follow-up PRs are needed to consume `ActorDirs` and delete `internal/ateompath`. | Issue #1604, PR #1730 (`a0b680d7`) |
| **Observability / OTLP** | **Step 4 of Actor Usage Events**: Event schemas and scopes (`ate.actor.usage_sampled`) were registered (`03ba5821`), and relay logging was enabled (`93e691d9`). Step 4 must move the emission anchor into the `ateom` runtime, update poller comments, and instruct `atecontroller` to pass `OTEL_LOGS_EXPORTER` to worker pods. | Issue #1748, PR #1881 (`03ba5821`) |
| **Autoscaling / HPA** | **Capacity-Aware HPA for Multi-Actor Pools**: Multi-actor worker support (`14c0c136`) invalidates the previous 1:1 worker autoscaling assumptions. HPA logic needs redesigning to scale based on slot occupancy and memory frontiers. | Issue #1266, PR #1836 (`14c0c136`) |
| **Lifecycle / Revert** | **Local Snapshot File Pruning on Revert**: `RevertActor` (`944abe32`) resets database state and clears worker assignments, but does not yet prune the local checkpoint bytes on disk for paused actors. | Issue #641, PR #1675 (`944abe32`) |
| **Security / Logging** | **Context Logging Redaction Handler**: Protobuf fields were marked with `debug_redact` (`25cdbe00`, `232d0f22`), but redaction is currently executed only inside unary interceptors. Redaction needs to be integrated into `internal/contextlogging` with a type descriptor cache, and Postgres credentials must be sanitized from startup flag logs. | Issue #1743, PR #1822 (`232d0f22`) |
| **Benchmarking** | **Public SWE-bench Image Registry & Prometheus Harvest**: The SWE-perf benchmark (`cdac9bae`) currently points to a personal Artifact Registry container image; a public project repository is required. Part 2 of cluster hardware discovery must add Prometheus harvest metrics. | Issue #1590, Issue #1692, PR #1694 (`cdac9bae`) |
| **Dataplane Networking** | **Turn Timeout Request Decoupling**: Default route timeouts were increased to 5m (`94f2285f`), but orphaned turns that time out continue running in the background and may deliver responses to subsequent callers. Proper cancellation propagation across the router is still unresolved. | Issue #1525, PR #1529 (`94f2285f`) |
