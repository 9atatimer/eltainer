# eltainer

A pure Emacs Lisp porcelain for **Docker and Kubernetes**, fronted by
a single magit-style UI.

![eltainer dashboard + docker exec](docs/exec-demo.gif)

*`M-x eltainer` opens a dashboard listing every available view in
both backends, including the currently-active kubeconfig context.
`c` jumps to the docker containers list; `e` on a row opens a real
shell inside the container via HTTP Upgrade hijack of
`POST /exec/{id}/start`, rendered in `eat`.  `b` switches Kubernetes
contexts the way `b` switches branches in magit.  No `docker` CLI
or `kubectl` involved.*

## Install

Emacs **30+** required (see [Requirements](#requirements)).  The
recommended setup is `use-package` with `:vc` — the package's
declared `Package-Requires:` (Emacs 30.1, `magit-section`,
`transient`, `eat`) is resolved by `package-vc` automatically
from your configured archives, so a single block does it all:

```elisp
(require 'package)
(add-to-list 'package-archives '("melpa"  . "https://melpa.org/packages/"))
(add-to-list 'package-archives '("nongnu" . "https://elpa.nongnu.org/nongnu/"))
(package-initialize)
(unless package-archive-contents (package-refresh-contents))

(unless (package-installed-p 'use-package)
  (package-install 'use-package))

(use-package eltainer
  :vc (:url "https://github.com/JacobGabrielson/eltainer" :rev :newest)
  :commands (eltainer docker k8s))
```

(`magit-section` + `transient` are on MELPA; `eat` is on NonGNU
ELPA.  Both archives are added above.  `package-vc` pulls each
dep on first install.)

`:rev :newest` follows the default branch.  Pin to a specific
tag or SHA with `:rev "v1.0.0"` if you'd rather track a release.

To pull the latest changes later:

    M-x package-vc-upgrade RET eltainer RET

…or `M-x package-vc-upgrade-all` to refresh every `:vc`-installed
package at once.

Then any of:

    M-x eltainer    ; dashboard listing every view + active context
    M-x docker      ; jump straight to docker containers
    M-x k8s         ; jump straight to k8s pods

## Philosophy

**Pure Elisp talking directly to the daemon.**

eltainer speaks HTTP/1.1 to the Docker daemon over its Unix socket
**and** HTTPS to the Kubernetes API server.  Both halves share one
transport, one streaming/event pipeline, one terminal abstraction.
JSON via native `json-parse-*`, TLS via built-in GnuTLS; the package
refuses to load without the former and refuses to TLS-connect
without the latter.

CLI fallbacks are kept *only* for things the engine APIs genuinely
can't do — `docker build` (BuildKit gRPC), `docker compose`, CLI
plugins, `docker login` config writes, `DOCKER_HOST=ssh://…`
transport, `docker-credential-*` helpers, and Kubernetes
`users.exec` plugins (`aws eks get-token`, `gke-gcloud-auth-plugin`,
…).  Each is one clearly-named function in one place.  See
[docs/architecture.md](docs/architecture.md).

## What you can do

`M-x eltainer` is the home screen.  From there, single-key launchers:

| Backend | Key | View |
|---------|-----|------|
| Docker | `c` | Containers (running; `a` toggles all) |
| Docker | `T` | Compose stacks (grouped by project label) |
| Docker | `p` | Pulse (single-host dashboard) |
| Docker | `I` | Images |
| Docker | `O` | Volumes |
| Docker | `N` | Networks (+ connected containers) |
| Docker | `u` | Pull image (streamed per-layer progress) |
| Docker | `M` | Build image from a Dockerfile context |
| Docker | `f` | Disk usage + per-section prune |
| Kubernetes | `k` | Pods grouped by namespace |
| Kubernetes | `d` | Deployments |
| Kubernetes | `s` | Services |
| Kubernetes | `S` | StatefulSets |
| Kubernetes | `D` | DaemonSets |
| Kubernetes | `j` / `J` | Jobs / CronJobs |
| Kubernetes | `i` | Ingresses |
| Kubernetes | `m` / `x` | ConfigMaps / Secrets |
| Kubernetes | `o` | Nodes (roles, conditions, live perf gauges) |
| Kubernetes | `A` | Sandboxes (agent-sandbox SIG — `agents.x-k8s.io`) |
| Kubernetes | `G` | Clusters (Cluster API) — `RET` pivots into a workload cluster |
| — | `b` | Switch Kubernetes context (across all discovered kubeconfigs) |
| — | `g` | Refresh dashboard |

`M-x docker` and `M-x k8s` still work directly and bypass the
dashboard if that's what you want.

### Always-visible key hints

`key-hints-mode` is on by default — eltainer views show a compact
"what can I do here" strip in a 1-line side window pinned to the
bottom of the frame.  The window auto-hides in any buffer that
didn't register hints, so the bar only appears where it's useful.

Examples:

| Buffer                | Strip                                            |
|-----------------------|--------------------------------------------------|
| `*eltainer*`          | `c ps  k pods  b ctx  I images  T stacks  o nodes  p pulse  f disk +1` |
| `*k8s:pods*`          | `l logs  e exec  f browse  M metric  K kill  N ns  Y edit  T xray` |
| `*docker:containers*` | `e exec  l logs  f browse  M metric  K kill  + create  d rm` |
| `*docker:df*`         | `p prune  P prune!  g refresh`                  |

Trailing `+N` is the count of additional keys that didn't fit;
press `?` for the full transient menu.

Off entirely:

    (key-hints-mode -1)

Universal (also show auto-extracted hints in non-eltainer modes):

    (setq key-hints-restrict-to-registered nil)

Full customisation: `M-x customize-group RET key-hints RET`.

### Inside any docker view

| Key | Action |
|-----|--------|
| `?` | Transient dispatch menu |
| `g` | Refresh |
| `q` | Quit window |
| `RET` | Toggle section / DWIM |
| `i` | Inspect resource at point |
| `d` | Delete / disconnect (context-aware) |
| `a` | Toggle running-only vs. all (containers view) |
| `F` | Narrow by label selector (`F l`) / name regex (`F n`); engine `?filters=` for labels (equality only — `!=` / `!key` are unsupported on docker) |
| `s` `S` `r` `K` | Start / Stop / Restart / Kill container |
| `l` | Tail logs (streaming, stdout / stderr demuxed) |
| `e` | Exec a shell inside the container (TTY) |
| `f` | Browse the container's filesystem (real dired-mode buffer; containers view) |
| In the FS browser: `D R C + I C-x C-q` | Delete / rename / copy / mkdir / import-from-host / wdired |
| `D` | DNS lookup from inside the container (`getent` → `nslookup` → `/etc/resolv.conf`+`/etc/hosts`) |
| `M` | Per-container metrics buffer (containers view) |
| `j` `J` | Join / leave a network |
| `+` | New-container form (containers view; JSON template → POST `/containers/create` + start) |
| `P` | Push image to its registry (images view; uses `~/.docker/config.json` auth) |
| `p` `P` | Prune this section (disk-usage view); capital does the more aggressive variant where one exists |

Views auto-refresh as the daemon's `/events` stream tells us what
changed (debounced).  The TTY exec lands in an
[`eat`](https://codeberg.org/akib/emacs-eat) buffer — eat is a hard
dependency (see [Requirements](#requirements)).

`TAB` on a running container shows live gauges — CPU% (with a
`throttled` note when it's hitting its CFS limit), memory, block-I/O
and network throughput sparklines, and the PID count — polled from
`/containers/{id}/stats`.  `M` opens a focused, self-refreshing
metrics buffer for the container.

![docker + k8s resource metrics](docs/metrics-demo.gif)

*The metrics gauges in action across both backends — see
[docs/DEMO.md](docs/DEMO.md).*

### Inside the k8s view

| Key | Action |
|-----|--------|
| `?` | Context-aware dispatch — actions for the resource under point, plus `v` for the view switcher |
| `g` | Refresh |
| `N` | Switch namespace |
| `F` | Narrow this view (`F l` label selector, `F n` name regex, `F c` clear) — labels go server-side via `?labelSelector=`; name-regex is client-side |
| `w` | Toggle live watch (auto-update via the K8s watch API) |
| `b` | Switch kubeconfig context (same picker as from the dashboard) |
| `i` | Describe resource |
| `l` | Tail pod logs (pods view); on a Deployment / StatefulSet / DaemonSet / Job / Service, opens a multi-pod tail (each pod colored distinctly); on a CronJob, tails the last run |
| `m` / `u` / `U` / `t` / `DEL` | dired-style marks: mark / unmark / unmark-all / toggle / unmark-backward (works in any view) |
| `L` | Multipod tail of every marked pod (pods view) |
| In any log view: `n` / `p` navigate, `P` pause/resume the stream, current line highlighted |
| `e` | Interactive TTY exec into the pod (pods view only) |
| `f` | Browse the pod's filesystem (real dired-mode buffer; pods view only) |
| In the FS browser: `D R C + I C-x C-q` | Delete / rename / copy / mkdir / import-from-host / wdired |
| `D` | DNS lookup from inside the pod (`getent` → `nslookup` → `/etc/resolv.conf`+`/etc/hosts`) |
| `M` | Per-pod metrics buffer (pods view only) |
| `T` | Open the xray tree for the workload at point (Deployment / STS / DS / Job / CronJob / RS / Service / Pod) |
| `Y` | Edit the YAML of the resource at point; `C-c C-c` PUTs the change back |
| `S` `R` `K` | Scale / rollout-restart / force-kill the workload at point |
| `c` `D` | Cordon-toggle / drain (Nodes view) |
| `C-u l` | Show the *previous* container run's logs (after a crash) |
| `d` | Delete resource (with confirmation) |
| `TAB` | Expand / collapse section |
| `RET` on an Ingress backend row | Jump to the referenced Service in the services view |
| In the services view: `IN/s` + `OUT/s` columns | Aggregate of each Service's backing pods' network counters (kubelet Summary); `M` opens a per-Service sparkline buffer |

`?` is **context-aware** — the first group of the menu reflects
whatever the cursor is on (a pod, a container, or another resource),
so it only ever offers actions that apply there.  `l` / `e` / `f` /
`M` on a container row target that container directly.

`TAB` on a pod expands it to show its containers, each as its own
section — point on a container row makes `l` / `e` / `f` target that
container directly (no picker).  Expanded containers also show live
CPU, memory and disk gauges (with trend sparklines), and the pod
gets a network rx/tx sparkline — CPU/memory need metrics-server,
disk/network need the kubelet stats API; each degrades gracefully if
unavailable.  `M` opens a focused, self-refreshing metrics buffer
for the pod.

### The Nodes view

`o` (on the dashboard, or `?` → `o` from any k8s view) opens the
cluster Nodes view — every node with its roles, status, kubelet
version and age.  `TAB` expands a node to its conditions (including
the `MemoryPressure` / `DiskPressure` / `PIDPressure` flags),
capacity vs. allocatable, scheduled-pod count, addresses, OS /
kernel / container-runtime and taints.  Each node carries live
CPU / memory / disk gauges (metrics-server + the kubelet stats API)
and the buffer self-refreshes.

When a Prometheus is reachable in the cluster, the Nodes view
enriches each node with load averages (1m / 5m / 15m) and swaps the
short in-buffer sparklines for real hour-long CPU / memory trends.
eltainer queries Prometheus *through the Kubernetes API server's
service proxy* — it reuses the existing authenticated connection,
so there is no port-forward and no second set of credentials.  The
Prometheus Service is auto-discovered; override it with
`eltainer-prometheus-service` (`"namespace/name:port"`), or set
that to `disabled` to switch the integration off.  With no
Prometheus the view simply omits those rows.

### Switching contexts

`b` (on the dashboard *or* any k8s view) enumerates every context
across every discovered kubeconfig file (`$KUBECONFIG`, anything
under `~/.kube` and `~/.kube/configs`, plus
`eltainer-kubeconfig-extra-paths`).  Pick one and the dashboard
flips immediately: any open `*k8s:…*` buffers are killed so they
re-open against the new context the next time you visit them.
Same muscle memory as `b` in magit for branches.

### Cluster API (CAPI)

`G` (on the dashboard, or `M-x k8s-capi`) opens the Clusters view when
you're pointed at a [Cluster API](https://cluster-api.sigs.k8s.io/)
**management cluster** — the one pane lists every workload cluster it
owns, each as a collapsible tree: `Cluster` → its control plane
(`KubeadmControlPlane`) and `MachineDeployment`s → `MachineSet`s →
`Machine`s, with phase and ready/desired replica counts at every
level.  It's built entirely on the API server (no `clusterctl`, no
`kubectl`), so it works against any provider; on a non-management
cluster the view just says so.

`RET` on a `Cluster` row **pivots** eltainer into that workload
cluster: it reads the `<cluster>-kubeconfig` Secret CAPI publishes,
caches it (mode 0600, under `k8s-capi-kubeconfig-cache-dir`), and
switches the active context to it — so you can list a cluster, drop
into it to browse its pods/nodes, and `b` back, all without leaving
Emacs.  (Read-only browsing + pivot today; scale / pause / delete /
upgrade are planned — see `docs/capi-plan.md`.)

### Stopping everything

`M-x eltainer-stop-all` is the panic button.  It kills every
`*docker:*` / `*k8s:*` / `*eltainer:*` buffer (each one's
kill-hooks cancel its timers and close its streams), tears down
the global Docker `/events` stream, and sweeps any orphan
eltainer-owned timer the kill-hooks didn't catch.  Live exec TTY
buffers are left alone by default — killing them drops a shell;
pass a prefix arg (`C-u M-x eltainer-stop-all`) to include those
too.

Metrics polling defaults to once every 30 seconds — tune via
`docker-metrics-refresh-interval` and `k8s-metrics-refresh-interval`.

## Architecture

```
eltainer.el              Dashboard + `M-x eltainer'
eltainer-ui.el           Shared faces, age-string, describe-value
eltainer-gauge.el        Shared text gauges + sparklines for the metrics views
eltainer-fs.el           Shared FS-listing scripts + entry struct + parser
eltainer-dired.el        Shared dired-mode parent for the FS browser
eltainer-net.el          Shared DNS-lookup chain (getent / nslookup / fallback)
eltainer-filter.el       View-narrowing layer (label selector + name regex)
eltainer-terminal.el     eat-backed terminal host for interactive exec
eltainer-shell-helper.el Invoke external helpers (cred / exec plugins)
key-hints.el             Always-visible mode-line / side-window key-hint strip
reload.el                Dev helper: byte-compile + reload both halves

docker/
  docker-http.el         HTTP/1.1 over unix / TCP / TCP+TLS (GnuTLS)
                         + chunked-decoded streaming.  Used by k8s too.
  docker-stream.el       8-byte multiplex demux + ndjson splitter
  docker-api.el          /vX.Y-prefixed engine GET / POST / DELETE
  docker-config.el       Connection params struct (used by k8s too)
  docker-ps.el           Containers: list / inspect / lifecycle
  docker-images.el       Images: list / inspect / tag / remove
  docker-networks.el     Networks: list / inspect / connect / remove
  docker-events.el       Long-lived /events stream + pub/sub
  docker-logs.el         Streaming /containers/{id}/logs, demuxed
  docker-exec.el         Upgrade-hijacked /exec/{id}/start TTY
  docker-auth.el         ~/.docker/config.json + docker-credential-* helpers
  docker-pull.el         Streamed /images/create with per-layer progress
  docker-fs.el           Filesystem listing via docker-exec; cat via the
                         archive API (works on distroless / scratch)
  docker-dired.el        Dired-mode buffer over a container's filesystem
  docker-stacks.el       Read-only Compose-stack view (group by project label)
  docker-pulse.el        Single-host docker pulse dashboard
  docker-create.el       Create + start a container from a JSON template (`+')
  docker-volumes.el      Volume browser + delete-with-confirm (`O' on dashboard)
  docker-build.el        Build an image; in-process recursive USTAR + /build (`M' on dashboard)
  docker-push.el         Push an image; `X-Registry-Auth' via docker-auth (`P' in the images view)
  docker-df.el           Disk-usage breakdown + per-section prune (`f' on dashboard)
  docker-metrics.el      Container /stats gauges: cpu / mem / io / net / pids
  docker.el              magit-section views + transient + actions

k8s/
  k8s-config.el          kubeconfig YAML parser (subset)
  k8s-api.el             REST client (thin wrapper over docker-http)
  k8s-prom.el            Prometheus client via the API service proxy
  k8s-watch.el           Watch streams on docker-http-stream
  k8s-marks.el           Dired-style marks (m/u/U/t/DEL) for any view
  k8s-metrics.el         Usage gauges / sparklines: metrics.k8s.io +
                         kubelet Summary API; per-pod + per-node data
  k8s-multilog.el        Multi-pod log tail (stern-style): one buffer,
                         one colour per pod, line-by-line interleaved
  k8s-pods.el            Pods view: phases, restarts, streamed logs,
                         container subsections, inline metrics
  k8s-fs.el              Pod-fs backend (list / stat / cat over k8s-exec)
  k8s-dired.el           Dired-mode buffer over a pod container's filesystem
  k8s-helm.el            Read-only Helm 3 view (decodes release secrets directly)
  k8s-traffic.el         Per-Service ingress/egress aggregation + M-buffer
  k8s-crds.el            Generic CRD browser (auto-detects + renders printer-columns)
  k8s-capi.el            Cluster API browser: workload-cluster tree + kubeconfig pivot
  k8s-pulse.el           Cluster-pulse dashboard (phase counts, top consumers, events)
  k8s-xray.el            Recursive resource-tree view of a workload
  k8s-edit.el            Edit any resource's YAML in place, PUT-on-apply
  k8s-actions.el         Scale / rollout-restart / force-kill / cordon / drain
  k8s-events.el          Cluster events view (`E')
  k8s-portforward.el     TCP port-forward via the API WebSocket (experimental)
  k8s-bookmarks.el       Emacs bookmark.el integration for resource rows
  k8s-scan.el            Cluster sanity scan (read-only linters, score)
  k8s-exec.el            One-shot + interactive TTY pod exec
  k8s.el                 Shared k8s magit-section views + transient
```

## Requirements

- Emacs 30+ with native JSON (`json-parse-string`) and, for any TLS
  target, GnuTLS (`gnutls-available-p`).  eltainer refuses to load
  without the former and refuses to TLS-connect without the latter.
- `magit-section`, `transient`.
- [`eat`](https://codeberg.org/akib/emacs-eat) (`M-x package-install
  RET eat RET` from MELPA / NonGNU ELPA).  Pure-Elisp xterm emulator;
  the sole supported terminal backend for `e` (interactive exec) in
  both Docker and Kubernetes views.  `eltainer-terminal.el` refuses
  to load without it.

  Why insist on eat?  The docker-exec and k8s-exec paths feed bytes
  through a custom process filter (HTTP-Upgrade hijack for Docker,
  WebSocket framing for Kubernetes).  built-in `term-mode` only
  renders bytes from an Emacs subprocess's stdout, and `vterm`
  doesn't expose a clean byte-injection seam — both silently no-op
  in this codebase.  eat does the right thing
  (`eat-term-process-output`) and is pure-Elisp, so it's a no-cost
  dep.
- A running Docker daemon and / or a kubeconfig.

## What's new

See [`NEWS.md`](NEWS.md) for a reverse-chronological log of
user-visible changes (new keys, new views, UX shifts).

## Hacking

For a development checkout (rather than a `package-vc` install), clone
somewhere and add it to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/eltainer")
(require 'eltainer)
(load "/path/to/eltainer/reload.el")
;; M-x eltainer-reload       ; byte-compile + reload + re-enter open buffers
```

`reload.el` only recompiles modules whose `.el` is newer than its
`.elc`, then reloads every module in dependency order; the
dashboard's `g` picks up new launchers without restarting Emacs.

## Tests

ERT suites under `test/`.  The pure-Elisp suite has no daemon / cluster
dependency; the integration suites in `test/docker/` and `test/k8s/`
hit a real Docker daemon / kubeconfig and `skip-unless` cleanly when
neither is reachable.

```
make test         # pure-Elisp unit tests only (parsers, path arithmetic,
                  # the `-F'-listing-switches regression, USTAR header parsing)
make test-all     # everything, including live-daemon + live-cluster integration
make compile      # clean + byte-compile every .el (no tests; CI sanity check)
make audit-keys   # construction-pattern survey + cross-mode key-drift report
                  # (read alongside `docs/keymap-audit.md')
```

Add a test whenever you change JSON parsing, magit-section rendering,
metrics math, watch handling, or API-path construction (per CLAUDE.md).
The fixture / replay system in `docs/test-fixtures-plan.md` is still
proposal — the existing integration tests just exercise live state.

## Demo

The GIF up top is regenerated by `docs/record-demo.sh` (requires
[asciinema](https://asciinema.org/) and
[agg](https://github.com/asciinema/agg) — `brew install agg`).  It
spins up a sentinel container, scripts an `emacs -nw` session
through [`docs/demo-init.el`](docs/demo-init.el), records with
asciinema, and converts to GIF.

## License

Apache 2.0 — see [LICENSE](LICENSE).
