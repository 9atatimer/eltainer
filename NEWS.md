# NEWS — eltainer

User-visible changes, **reverse-chronological** by date.  Each
heading is a day; under it sit the features that landed that day.
Entries are written from the user's point of view — what's now
possible, which key does what.  Implementation detail belongs in
commit messages.

See `docs/*-plan.md` for design docs and `docs/new-features.md` for
the in-flight backlog.

---

## 2026-06-08

### Cluster API (CAPI) cluster browser + pivot (`G`)

`G` on the dashboard (or `M-x k8s-capi`) opens a new Clusters view for
Cluster API **management clusters**: every workload cluster the
management cluster owns, rendered as a collapsible tree — `Cluster` →
control plane (`KubeadmControlPlane`) and `MachineDeployment`s →
`MachineSet`s → `Machine`s — with phase and ready/desired replica
counts at each level.  It's read directly off the API server, so it
needs no `clusterctl`/`kubectl` and works with any infrastructure
provider; on a non-management cluster it just says CAPI isn't
installed.

`RET` on a `Cluster` row **pivots** eltainer into that workload
cluster — it fetches the `<cluster>-kubeconfig` Secret CAPI publishes,
caches it (mode 0600), and switches the active context — so you can
list clusters, drop into one to browse its pods/nodes, and `b` back
out. Read-only browsing + pivot for now; lifecycle actions (scale /
pause / delete / upgrade) are planned.

| Key | Action |
|-----|--------|
| `G` | Open the Clusters (CAPI) view from the dashboard |
| `RET` | Pivot into the workload cluster under point |

## 2026-05-29

### Always-visible key-hint strip (`key-hints-mode`)

A compact "what can I do here" strip now sits in a 1-line side
window at the bottom of the frame whenever you're in an eltainer
view — like having `?` permanently pressed.  The window
auto-hides in buffers that didn't register hints, so the bar
only appears where it's useful (not in scratch / source files).

Examples:

| Buffer                | Strip                                            |
|-----------------------|--------------------------------------------------|
| `*eltainer*`          | `c ps  k pods  b ctx  I images  T stacks  o nodes +3` |
| `*k8s:pods*`          | `l logs  e exec  f browse  M metric  K kill  N ns +2` |
| `*docker:containers*` | `e exec  l logs  f browse  M metric  K kill  + create +1` |
| `*docker:df*`         | `p prune  P prune!  g refresh`                  |

The trailing `+N` is the count of additional keys the strip
didn't have room for; press `?` for the full transient menu.

Customisation via `M-x customize-group RET key-hints RET`:

| Knob                                   | Default | What                                               |
|----------------------------------------|---------|----------------------------------------------------|
| `key-hints-restrict-to-registered`     | `t`     | only render in modes that called `key-hints-register'.  Set to nil for universal auto-extract. |
| `key-hints-max-items`                  | 8       | items rendered before the `+N' badge               |
| `key-hints-truncate-label-width`       | 10      | per-label max chars                                |
| `key-hints-side-window-height`         | 1       | lines of side-window height                        |
| `key-hints-hide-modes`                 | …       | modes where the strip is suppressed                |

To turn off: `(key-hints-mode -1)` after `(require 'eltainer)`.

### Dev: Keymap audit (`make audit-keys`)

`test/keymap-audit.el` walks every `*-mode-map` in the codebase
and prints a construction-pattern survey, per-map binding list,
and cross-mode drift table.  Run it from the shell with
`make audit-keys` or interactively via `M-x keymap-audit`.

Read alongside `docs/keymap-audit.md` for the curated triage of
the report's flags (most "inconsistencies" are intentional —
the dashboard's letter launchers vs. resource-view verbs, the
dired/eltainer-dired override pattern, the per-view `g`-refresh
overrides — and the doc names which is which).

---

## 2026-05-28

### Dashboard letter shuffles

Three docker launchers were silently shadowed by their Kubernetes
neighbours iterated after them: `S` (Stacks vs StatefulSets), `V`
(Volumes vs PVs), `B` (Build vs PDBs).  Renamed:

| Was | Now | Mnemonic              |
|-----|-----|-----------------------|
| `S` | `T` | s**T**acks            |
| `V` | `O` | v**O**lumes           |
| `B` | `M` | i**M**age build       |

The dashboard now warns if two `eltainer-views` entries map to
the same key, so a future repeat fails loudly instead of silently
binding the second.

### Docker: Disk-usage view + per-section prune (`f` from dashboard)

`*docker:df*` — eltainer's read-friendly take on `docker system
df`.  Five sections: Images / Containers / Volumes / Build cache
/ Networks.  Each shows total count, total size, and (where it
applies) reclaimable bytes if you pruned it.

`p` on a section prunes that category, with a confirm.  `P`
(capital) does the more aggressive variant where one exists:

| Section     | `p`                  | `P`                                |
|-------------|----------------------|------------------------------------|
| Images      | dangling only        | all unused (`{"dangling":["false"]}`) |
| Containers  | stopped              |                                    |
| Volumes     | unused               |                                    |
| Build cache | old / unused layers  | `prune --all`                      |
| Networks    | unused custom nets   |                                    |

Reports `N objects pruned; reclaimed XX MB` on success.  `g`
re-polls.

## 2026-05-27

### Docker: Volume browser (`O` from dashboard, originally `V`)

`*docker:volumes*` lists every named volume on the daemon with
NAME / DRIVER / SIZE / USED BY / CREATED, plus the mountpoint
on the second line.  Size comes from `/system/df`; the "used
by" column lists which containers mount the volume (resolved
per-container).  `d` deletes (with confirm; engine refuses if
in use and surfaces the error).

### Docker: Image build (`M` from dashboard, originally `B`; `M-x docker-build`)

`M-x docker-build' prompts for a context directory + optional
`:tag', tars the context in pure Elisp (recursive walk, USTAR
format reusing the docker-fs archive primitives), POSTs to
`/build' with `Content-Type: application/x-tar', and streams
the daemon's NDJSON progress into `*docker:build*'.  Real
step-by-step rendering (`Step 1/4: FROM …', `Successfully
tagged …'), errors in the error face.

Coarse `.dockerignore' substitute via `docker-build-skip-rx'
(skips `.git', `.elc', backup files, etc.).  Full
`.dockerignore' parsing + BuildKit are queued for v2.

### Docker: Image push (`P` on the images view)

Mirror of `docker-pull-image' for the reverse direction.
`POST /images/<name>/push?tag=<tag>' with `X-Registry-Auth'
resolved from `~/.docker/config.json' (same path `docker-auth.el'
already drives for pull).  Streams progress into
`*docker:push:NAME*'; reuses the pull view's renderer.
`M-x docker-image-push' as the cluster-wide entry; `P' on a
docker-images row pushes whatever's at point.

### Docker: Container-create form (`+` on the containers view)

`+` on a docker containers row (or `M-x docker-create`) pops
`*docker:create*` with a JSON template for `POST /containers/
create`.  Edit the body, `C-c C-c` POSTs + starts; `C-c C-k`
cancels.

JSON is the engine API's native shape — every field the daemon
supports is editable (Cmd / Env / Labels / ExposedPorts /
HostConfig.PortBindings / Binds / NetworkMode / RestartPolicy
/ …).  `#`-prefixed banner at the top of the buffer documents
the common fields; the `---` separator marks where the JSON
body starts.  Container name defaults to
`eltainer-<image-stem>-<random>`; the prompt accepts any
override.

Errors (image missing, bad JSON, port already bound, name
collision) pop a `*docker:create:error*` buffer with the
daemon's response so you can fix and retry.

### Docker: Compose-stack view (`T` from dashboard, originally `S`)

`*docker:stacks*` lists every Compose-managed stack on the
daemon, grouped by the `com.docker.compose.project` label and
expanded by service.  Each row shows running/total replica
counts, container state, image, and bound ports; the path to
`docker-compose.yml` appears under each stack heading.  Stacks
fully up render in green, partially up in yellow, all-down in
red.

Read-only in v1.  Mutating ops (up/down/restart) need the
`compose` plugin's CLI semantics (volume creation, network
setup, dependency ordering) — see `docs/docker-feature-ideas.md`
for v2 thinking.

### Docker: Single-host pulse (`p` from dashboard)

`*docker:pulse*` — mirror of the k8s cluster-pulse, scoped to
the local docker daemon.  Sections:

- **Containers** by state, with relative bars.
- **Stacks** summary (total / fully-up / partial).
- **Disk usage** from `/system/df`: images / containers /
  volumes / build cache.
- **Top 5 CPU** and **Top 5 memory** consumers among running
  containers (CPU% via single-call delta against `precpu_stats`).
- Footer: engine version, kernel, CPU count, host RAM.

Self-refreshes every `docker-pulse-refresh-interval` (default 30
s); `g` re-polls; `q` quits.

### CRDs view shows served versions

The CRDs listing grew a VERSIONS column listing every served
version of each CRD; the storage version is marked with `*` (so
`v1*, v1beta1` reads as "v1 is storage, v1beta1 also served").
The per-CRD instance buffer's header now includes the active
version (`Certificate.cert-manager.io/v1`) so you always know
exactly which API you're hitting.

### Cluster sanity scan (`Z` from dashboard / `!` from `?`)

`*k8s:scan*` runs a battery of read-only checks against every
Pod / Deployment / StatefulSet / DaemonSet / Service / Node /
Ingress / PVC / ClusterRoleBinding on the cluster, and reports
findings grouped by severity (Error / Warning / Info) with a
0-100 cluster-hygiene score at the top.

Findings are colour-coded; each row carries a `k8s-jump-target'
so `RET` opens the offending resource's view narrowed to it.

v1 linters cover:
- **Pods**: no resources.limits, no livenessProbe, no
  readinessProbe (info), `:latest` / unpinned image tags,
  containers without securityContext.runAsNonRoot, restartCount
  > `k8s-scan-pod-restarts-warn' (default 5), Pending >5 min.
- **Deployments / STS / DS**: replicas=0 (info),
  spec.selector.matchLabels mismatch with
  spec.template.metadata.labels (error).
- **Services**: no selector + not ExternalName, multiple ports
  without names.
- **Nodes**: Ready != True (error), MemoryPressure /
  DiskPressure / PIDPressure True.
- **Ingresses**: rule with no host (catch-all, info).
- **PVCs**: phase != Bound.
- **ClusterRoleBindings**: cluster-admin bound to non-system
  subjects.

Each linter is a small pure function over a resource alist; the
set is easy to extend.

### Emacs-bookmark integration for K8s rows

`bookmark.el` now knows how to record-and-jump K8s resource rows.
Stand on any row in any k8s view, hit `C-x r m`, name it — later
`C-x r b` re-opens the right view, switches kubeconfig context if
needed, sets the namespace filter, and scrolls to that row.

Works across clusters: each record carries `(context, kubeconfig,
kind, ns, name)`, and the jump invokes `eltainer--apply-context-
switch` when the active context doesn't match.

### Cluster events view (`E` from dashboard / `?`)

`*k8s:events*` lists `/api/v1/events` cluster-wide, newest first,
filtered to the last `k8s-events-window-minutes` (default 60 min;
0 disables the cutoff).  Warning rows render in the error face,
Normal in success; the involvedObject's kind/namespace/name is the
right-hand column.  TAB on a row hides its message body.
Composes with namespace + label + name-regex filters.

### RBAC: ServiceAccounts, Roles, RoleBindings, ClusterRoles, ClusterRoleBindings

Five new read-only RBAC views:

| Key (dashboard) | View                  | Scope       |
|-----------------|-----------------------|-------------|
| `a`             | ServiceAccounts        | namespaced |
| `r`             | Roles                  | namespaced |
| `e`             | RoleBindings           | namespaced |
| `X`             | ClusterRoles           | cluster    |
| `Y`             | ClusterRoleBindings    | cluster    |

RoleBindings / ClusterRoleBindings summarise their `subjects`
compactly: `sa:default/foo + user:alice + 2 more`.  ClusterRoles
mark aggregated vs. direct (whether they synthesise their rules
from labelled child roles).

### Port-forward (experimental, `P` on a Pod row)

WebSocket-based port-forward via the API server's
`/pods/.../portforward` endpoint — no `kubectl` shell-out.
Implementation present; live verification against a running pod
is still pending an interactive smoke test (batch-mode emacs is
the wrong driver).  Use at your own risk; expect debugging.
`*k8s:port-forwards*` lists active forwards; `k` kills.

### Resource coverage: PV / PVC / StorageClass / NetworkPolicy / HPA / PDB

Six new read-only views land in the dashboard and the `?`
resource-switcher:

| Key (dashboard) | View                  | Scope       |
|-----------------|-----------------------|-------------|
| `v`             | PersistentVolumeClaims | namespaced |
| `V`             | PersistentVolumes      | cluster     |
| `C`             | StorageClasses         | cluster     |
| `W`             | NetworkPolicies        | namespaced  |
| `h`             | HorizontalPodAutoscalers | namespaced |
| `B`             | PodDisruptionBudgets   | namespaced  |

Each composes with the existing facilities — `g` to refresh, `F`
to narrow by label / name, `Y` to edit, `d` to delete.
Cluster-scoped resources (PV, StorageClass) render under a
`<cluster>` group instead of a namespace group.

### Workload + node write actions

| Key | Action | Targets |
|-----|--------|---------|
| `S` | Scale (prompts for replicas; numeric prefix arg sets directly) | Deployment / StatefulSet / ReplicaSet |
| `R` | Rollout-restart (patches `kubectl.kubernetes.io/restartedAt` annotation on the pod template) | Deployment / StatefulSet / DaemonSet |
| `K` | Force-kill the Pod (controller will recreate) | Pod |
| `c` | Toggle cordon (`spec.unschedulable`) | Node |
| `D` | Drain — cordon + evict every non-DaemonSet, non-mirror pod | Node |
| `C-u l` | Tail the *previous* container run (`?previous=true`) — useful right after a crash | Pod |

All actions confirm before sending; node drain reports per-pod
success / failure / kept-as-DaemonSet counts.  Bound in
`k8s-common-map` so every view inherits them; each one type-checks
the section at point and errors cleanly elsewhere.

### Edit any resource's YAML in place (`Y`)

`Y` on a resource row in any k8s view opens that resource's YAML
in `*k8s:edit:NS/KIND/NAME*` (with `yaml-mode` if it's installed,
fundamental-mode otherwise).  Edit, then `C-c C-c` PUTs it back
via the K8s API.  `C-c C-k` cancels.

Content-type negotiation does the YAML round-trip on the server
side — no in-Emacs YAML parser required.  PUT (rather than PATCH)
sends the whole resource; the API server's
`metadata.resourceVersion' enforcement gives optimistic
concurrency for free (a 409 means someone else mutated it; the
error buffer surfaces the server's message).

After a successful apply the buffer reloads the freshly-returned
YAML (with the new `resourceVersion`, server-added defaults, etc.)
so the next edit cycle starts from current state.

Live-tested by bumping a Deployment's `replicas: 1 → 2` and
reverting via two PUTs.

### xray resource-tree view (`T` on a workload)

`T` on a Deployment / StatefulSet / DaemonSet / Job / CronJob /
ReplicaSet / Service / Pod row opens
`*k8s:xray:NS/KIND/NAME*` — a magit-section tree that descends
from the workload through every layer of its dependency graph.
For a Deployment, that's:

```
Deployment    podinfo  1/1 ready
  ReplicaSet    podinfo-6d98d7d6cd  1/1 ready
    Pod           podinfo-6d98...  Running · 1d
      Container     podinfo  ghcr.io/... · Running, 0 restarts
        [emptyDir]/data                   /data
        Secret/web-nginx-tls              /certs
```

Every level is a magit-section so `TAB` folds it.  Volume-mount
rows that point at a real resource (Secret, ConfigMap) carry a
`k8s-jump-target` — `RET` opens that resource's view narrowed to
the referenced object.  EmptyDirs / projected / hostPath /
downwardAPI mounts render their kind as a label but stay inert.

Init containers show with their actual phase ("Terminated
(Completed)" once they've finished), not `?`.

CronJob → most recent Jobs first → their Pods; Service → pods
matching its selector.

### Cluster-pulse dashboard

`P` from the dashboard (or `?` → *Pulse*) opens `*k8s:pulse*` —
a one-buffer cluster health summary that self-refreshes every 30
seconds.  Sections:

- **Pods** — count per phase, with a small bar per phase showing
  relative size; Running/Succeeded green, Pending yellow,
  Failed/Unknown red.
- **Nodes** — Ready + NotReady tallies.
- **Workloads** — Deployments / StatefulSets / DaemonSets / Jobs
  / CronJobs / Services / Ingresses, counted cluster-wide.
- **Recent Warning events** — every Warning event in the last
  hour (configurable via `k8s-pulse-recent-events-window-minutes`),
  newest first, with reason / involved-object / age.
- **Top 5 CPU consumers** and **Top 5 memory consumers** —
  pods ranked by total usage across containers.

The 5 in Top-5 is `k8s-pulse-top-consumers`.

### Generic CustomResourceDefinition browser

`R` from the dashboard (or `?` → *Custom resources*) opens
`*k8s:crds*` — every CRD on the cluster, grouped by API group,
with NAME / GROUP / SCOPE / KIND / AGE columns.  `RET` on a CRD
row drills into its instances; the columns of that view come
directly from the CRD's own `additionalPrinterColumns` spec.

No code per CRD: a small subset of JSONPath
(`.metadata.name`, `.status.replicas`, `[0]` indexing,
`[?(@.type=="Ready")]` equality filters) handles what every CRD's
printer-columns use in practice.  Date-typed columns render
through eltainer's age-tier face, so you get the same colour
gradient you do everywhere else.  Priority-1+ ("wide") columns are
hidden in v1 — describe (`i`) shows them.

Tested live against the `cert-manager` CRDs (Certificate /
CertificateRequest / Issuer / ClusterIssuer / Challenge / Order)
and the `agents.x-k8s.io/v1alpha1` Sandbox CRD.

### Services view: per-Service IN/s + OUT/s traffic columns

The Services view grows two new columns showing aggregate ingress
/ egress bytes-per-second for every Service.  For each Service we
resolve `.spec.selector` to its backing pods, sum their kubelet-
Summary `network.{rxBytes, txBytes}` counters, and rate-difference
against the previous poll (default every 30 s, controlled by
`k8s-metrics-refresh-interval`).  Works uniformly for ClusterIP,
NodePort, LoadBalancer, and headless Services — every shape ends
with the bytes hitting backing pods.

`M` on a Service row opens a focused `*k8s:traffic:NS/SVC*` buffer
with sparklines for the aggregate IN/s + OUT/s plus a per-backing-
pod breakdown.  Polls on its own timer; `g` re-polls; `q` quits.

The new columns can be turned off with
`(setq k8s-services-show-traffic nil)` if you'd rather have a
narrower row.  Selectorless / `ExternalName` Services render `—`.

Limitation: pod network counters can't attribute bytes to a
specific destination Service, so a pod selected by multiple
Services has its rx/tx split across them — the same limitation
`kubectl top` and most cloud-monitoring panels have.

## 2026-05-26

### Helm RESOURCES rows are jump-targets

Expanding a Helm release row shows a per-kind tally of the rendered
manifest (`1 Deployment / 1 Service …`).  Each kind line with a
registered resource view (Service, Deployment, StatefulSet,
DaemonSet, Job, CronJob, ConfigMap, Secret, Ingress, Pod) is now
`RET`-actionable — jumps to that view, switches to the release's
namespace, and pre-sets a name-regex filter narrowing to *exactly
the resources from that release*.  Resource names are pulled from
the manifest directly, so the filter is precise no matter what
labels the chart did or didn't add.

### Helm 3 releases view

`H` on the dashboard (or `?` → *Helm releases* from any k8s view)
opens a read-only listing of Helm 3 releases in the cluster.
Columns: NAME / REVISION / STATUS / CHART / APP / AGE; STATUS is
colour-coded (deployed = green, failed = red, other = yellow).

Per-row actions:
- `RET` / `TAB` — expand the row.  Shows a per-kind tally of the
  rendered manifest (`3 Service / 5 ConfigMap / 1 Deployment …`)
  and the chart's `NOTES.txt`.
- `v` — pop a buffer with the release's `values.yaml` (pretty-
  printed JSON, falls into `json-mode` when available).
- `m` — pop a buffer with the rendered manifest.
- `h` — pop the full revision history (every revision of this
  release, newest first; the main view shows only the active one).
- `F` — narrow composes with helm's `owner=helm` baseline.

Decoded directly from the API-server release Secrets — no `helm`
CLI invoked.

### Filter / narrow views by label (`F` prefix)

Every k8s view and the docker containers view now narrow on the
fly.  `F l SELECTOR` applies a K8s-style label selector
(`tier=frontend,env!=dev`).  `F n REGEX` narrows by name regex.
`F c` clears.  Filters are per-buffer and survive `g`.  The
mode-line shows `[label:… name:…]` in the warning face when
active.

Labels go server-side (K8s `?labelSelector=`, docker `?filters=`
JSON).  Name-regex is client-side.  Docker's filter is
equality-only — `!=` / `!key` terms in the selector are dropped
with a one-line warning.

### DNS lookup from inside a container (`D`)

On the pods view (or docker containers view), `D` prompts for a
hostname and resolves it *from inside that container*.  Tries
`getent hosts` → `nslookup` → falls back to dumping
`/etc/resolv.conf` + `/etc/hosts` (first probe that exits 0 wins).
Result pops a read-only buffer.  Distroless images get a clear
"no shell, no getent, no nslookup" diagnostic.

### Ingress backend `RET` jumps to the Service

When an Ingress section is expanded, each `host/path → service:port`
row is now actionable — `RET` jumps to that Service in the services
view.  Foundation for a general `k8s-jump-target` text-property
mechanism that future cross-resource jumps will reuse (Pod → Node,
Service → Endpoints, etc.).

### Age column colour tiers

The AGE column in every resource view now colour-codes by tier:

| Age      | Face                    | Default colour |
|----------|-------------------------|----------------|
| < 1 hour | `eltainer-age-very-new` | warning        |
| < 1 day  | `eltainer-age-new`      | success        |
| < 1 week | `eltainer-age-medium`   | default fg     |
| < 30 days| `eltainer-age-old`      | shadow         |
| ≥ 30 days| `eltainer-age-ancient`  | shadow + light |

Themable via `M-x customize-face`.

### Log views: `p` is `previous-line` again

In `k8s-multilog-mode`, `p` used to toggle pause/resume — but
every other view uses `n`/`p` for line navigation, so muscle
memory tripped.  Pause has moved to capital `P`.  All log buffers
(single-pod, multipod, docker) now enable `hl-line-mode` so the
cursor line is visibly highlighted.

### Writable filesystem browser (container-dired v2)

The dired-mode buffer over a container's filesystem (`f` on a pod
or container) is now writable.  The standard dired keys route
through the container's exec backend, after a yes-or-no confirm:

| Key | Action |
|-----|--------|
| `D` | Delete marked files (`rm -rf` inside the container) |
| `R` | Rename or move marked files (`mv`) |
| `C` | Copy in-container (`cp -r`) or export to host (`host:` prefix) |
| `+` | Create directory (`mkdir -p`) |
| `I` | Import a host file *into* this directory |
| `C-x C-q` | wdired — edit names in the buffer, `C-c C-c` commits the batch |

Host → container import uses Docker's archive PUT API on the
docker side, base64-through-argv on the k8s side (256 KB cap).
The first writable op probes for `rm` / `mv` / `mkdir` / `cp` and
caches the result on the buffer — distroless surfaces a single
friendly error instead of one per operation.

### Read-only filesystem browser (container-dired v1)

`f` on a pod or container row opens a real `dired-mode` buffer over
the container's filesystem.  Inherits every navigation / marking
keystroke from muscle memory.  Sentinel paths are
`/docker:NAME:/path` and `/k8s:NS/POD[CONTAINER]:/path` — *not*
TRAMP; eltainer never shells out.  Reads go through the engine
API directly, so distroless can still be catted (docker side) and
gives a clean error message instead of OCI noise (k8s side).

### `make test` / `make test-all`

`make test` runs the pure-Elisp unit suite (parsers, path
arithmetic, regression tests) with no daemon or cluster needed.
`make test-all` adds the live-daemon and live-cluster integration
suites — they `skip-unless` cleanly when nothing's reachable.
`make compile` does a clean byte-compile sanity check.

---

## 2026-05-25

### Friendlier error on distroless / scratch containers

When `f` (or any other exec-dependent action) hit a distroless or
scratch image, the user used to see several lines of raw OCI
runtime noise.  Now they get a single line:

```
eltainer-fs: container has no `sh' / `find' / `stat'
(distroless or scratch image) — filesystem browse needs a POSIX
shell + GNU/BusyBox coreutils inside the container
```

---

## 2026-05-24

### Dired-style marks across every view

`m` / `u` / `U` / `t` / `DEL` (plus `M-DEL`, `* !`, `* ?`) mark /
unmark resources in any k8s view.  Marks then feed multi-target
commands.

### Multi-pod log tailing (stern-style, `L`)

`L` on the pods view streams every marked pod's logs into one
buffer, each pod a distinct colour.  Or `l` on a controller
(Deployment / StatefulSet / DaemonSet / Job / Service / CronJob)
tails every pod the controller owns automatically.  Point at tail
on open / restart / clear.

### ANSI colour rendering in log buffers

Pod / container log streams used to leak `^[[` escape sequences
into the buffer.  They now render colour and basic SGR styles
inline.

### Stable cursor across refreshes; CronJob last-run logs

`g` (refresh) keeps the cursor on the same resource even when the
list above shifts.  `l` on a CronJob row tails the last run's
pod's logs.

---

## 2026-05-23

### `M-x eltainer-stop-all` panic button

A single command that closes every eltainer view, cancels every
metrics timer, and tears down every open watch stream.  Useful
when a slow cluster has made Emacs feel unresponsive.

Default metrics polling interval also relaxed (from 5 s to 30 s).

---

## 2026-05-22

### Kubernetes Nodes view, optionally Prometheus-enriched

`o` from the dashboard / `?` resource switcher opens a cluster
nodes view: per-node CPU and memory usage gauges off
`metrics.k8s.io`, plus disk usage from the kubelet Summary API.
If a Prometheus Service is present in the cluster, node 1m / 5m /
15m load averages and range queries fold in too.

### Kubernetes Sandboxes view (agent-sandbox SIG)

`A` opens a view of `agents.x-k8s.io/v1alpha1` `Sandbox` resources
when the CRD is installed.  Degrades gracefully (no rows, no
error) when it isn't.

### Container metrics dashboard (docker side)

`M` on a docker container row opens a per-container metrics buffer
with CPU, memory, disk I/O, network, and PIDs gauges — sampled
from the engine's `/stats` endpoint.  Fetched asynchronously so
slow daemons don't hang Emacs.  Memory gauges against host RAM for
containers with no explicit limit.

### Kubernetes metrics (phase 1 / 1.5 / 2)

Inline CPU and memory gauges render directly under each pod
section in the pods view, fed by `metrics.k8s.io`.  `M` on a pod
opens a per-pod metrics dashboard.  Disk usage gauges and network
sparklines from the kubelet Summary API.  Trend sparklines show
the recent history.  `?` dispatch grew an entry for the per-pod
metrics buffer.

---

## 2026-05-21

### Container-aware `l` / `e` / `f`

When point is on an expanded *container* sub-section of a pod
(vs. the pod row itself), `l` / `e` / `f` / `M` target that
container directly — no picker prompt.  On the pod line,
multi-container pods get a picker.

### Buffer-based container picker (no completion framework needed)

The multi-container picker for `e` / `l` is now its own
self-contained buffer with `n` / `p` / `RET` / `q` — works
identically regardless of whether the user has vertico / fido /
plain minibuffer completion configured.

### `k8s exec` always prompts for the command

`e` on a pod / container now always pops a prompt pre-filled with
`/bin/sh`.  Accept the default to trigger a shell probe; type
anything else (`bash`, `ash -x`, `python3 -c …`) to run that
instead.

---

## 2026-05-20

### Multi-container exec / logs picker

When `e` or `l` is invoked on a multi-container pod, eltainer
prompts for the container instead of silently picking the first.

---

## 2026-05-19

### Shell probe + readable failures for `k8s exec`

`e` defaults to `/bin/sh`, but if that doesn't exist eltainer
probes `bash`, `busybox sh`, `ash` and the first one that works.
Distroless images get a clear error message pointing at
`kubectl debug --image=busybox` instead of the bare engine error.

### Streaming pod logs

Pod logs stream in live (`l`) instead of being one-shot fetched.
`g` restarts the stream; `k` stops it.
