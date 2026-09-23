# Deploy — in-pod (build, test, image build without push)

*Drafted 2026-09-23 against `050a584c`. Mirrors the `run-tests` job of
`.github/workflows/pr-workflow.yaml` plus a no-push `make build-images`.*

## What this needs

**Can this run in the pod? Partly.** Everything CI's `run-tests` job does runs
here: compiling every binary, `go test -race ./...`, the root-gated tests, and
the verifiers. Building the container images with `ko --push=false` also works,
because ko needs no Docker daemon. Running Substrate does not work here: the
atelet DaemonSet needs real nodes. It mounts kubelet's plugin and device-plugin
sockets, a hostPath BasePath it shares with the ateom worker pods, and host
`/dev`. Each worker runs `runsc` (gVisor) or a KVM micro-VM. CI's e2e job gets
this from a kind cluster on a VM with `/dev/kvm`. This pod has neither Docker
nor `/dev/kvm`, so that part is in `deploy-gcp.md`.

What a pass proves: the tree builds, the unit and root tests are green, and
every image in `CONTROL_PLANE_IMAGES`/`WORKER_IMAGES` builds. It does not prove
that anything deploys.

Feasibility, probed 2026-09-23 in this pod:

- ✓ `go` 1.27 (downloads the toolchain `go.mod` asks for), `make`, `git`, `bash`, `jq`, `python3`
- ✓ `hack/run-tool.sh ko version` resolves ko v0.19.1 from `hack/tools/ko`, which needs module-proxy network access
- ✓ Runs as uid 0, so `hack/run-root-tests.sh` runs without `sudo`
- ✓ `go build ./...` succeeds (about 7 minutes cold, on 4 CPUs)
- ✗ **Docker is missing.** The PostgreSQL-backed tests (`cmd/ateapi/internal/store/atepg`,
  `internal/authz`) use testcontainers and **skip** when Docker is absent
  (`cmd/ateapi/internal/store/dockerenv`). This is accepted, not fixed. Setting
  `REQUIRE_DOCKER=1` makes them fail instead.
- ✗ **`weaver` is missing.** `hack/verify/metrics.sh` needs weaver v0.25.1 or Docker.
  Install it from https://github.com/open-telemetry/weaver/releases/tag/v0.25.1
  and put it on `PATH`, or skip that verifier (Step 5 does).
- ✗ **`shellcheck` 0.9.0 is missing.** `hack/verify/shellcheck.sh` falls back to Docker.
  Install it with `apt-get install -y shellcheck` (check `shellcheck --version`
  says 0.9.0), or skip that verifier (Step 5 does).
- ⚠ **Disk:** `/workspaces` is a 9.8 GB volume, and the default `GOCACHE` there
  fills it; a build failed with `no space left on device`. `/` has about 79 GB
  free. Step 1 moves the cache there.
- No cloud credentials, and nothing to tear down except `/tmp` and `bin/`.

## Preconditions

- A checkout of the repository, with the current directory at its root.
- Network access to `proxy.golang.org`, for the tool modules under `hack/tools`.

## Steps

```bash
# 1. Put the Go build cache on the large filesystem.
export GOCACHE=/tmp/gocache GOTMPDIR=/tmp/gotmp
mkdir -p "$GOCACHE" "$GOTMPDIR"

# 2. CI's immutable-migration guard, and the binaries.
hack/verify/postgresql-migrations.sh
make build-atectl build-ate-setup build-atenet

# 3. Unit tests (CI: go test -race -v ./...), including tools/apitool's own module.
make test
(cd tools/apitool && go test -race ./...)

# 4. Root-gated tests: overlay mounts, whiteout mknod, trusted.* xattrs.
hack/run-root-tests.sh -race

# 5. Verifiers. This is hack/verify-all.sh's loop without the two that need
#    Docker here. Drop the filter once weaver and shellcheck are installed.
for F in $(find ./hack/verify -name '*.sh' | sort); do
  case "$F" in ./hack/verify/metrics.sh|./hack/verify/shellcheck.sh) echo "SKIP $F"; continue ;; esac
  echo "Running $F"; "$F"
done

# 6. Build every installer image (control plane + workers) without pushing.
make build-images KO_FLAGS=--push=false
```

## Verify

- Every step exits 0, and `bin/` holds `kubectl-ate`, `ate-setup` and `atenet`.
- `./bin/kubectl-ate --help` and `./bin/ate-setup --version` both run.
- `go run ./cmd/ate-setup deploy demo --help` lists the demos. This parses the
  installer's registry, with no cluster involved.
- Step 6 prints one `ko` image reference per package in `ALL_IMAGES`.
  `ateom-microvm` is the slow one, because it is built on a Debian base.
- Look for skips in step 3's output: `go test ./cmd/ateapi/internal/store/atepg/ -v 2>&1 | grep -c SKIP`.
  Nonzero means the store tests did not run here, as expected.

## Teardown

```bash
make clean                 # removes bin/
rm -rf /tmp/gocache /tmp/gotmp
```
