# Plan: Cluster API (CAPI) — browse and manage workload clusters

Status: **v1 shipped** — read-only cluster browser + kubeconfig pivot
landed in `k8s/k8s-capi.el` (`G` on the dashboard / `M-x k8s-capi`).
Lifecycle writes (§7) and the niceties (§9) are still pending.

## Goal

Turn a CAPI **management cluster** into a single pane that lists every
**workload cluster** it owns, renders the Cluster → control-plane →
MachineDeployment → MachineSet → Machine tree as collapsible
magit-sections, and lets you **pivot into any workload cluster** with a
keystroke (browse its pods/nodes, come back).  Day-2 lifecycle actions
— scale, pause, delete-for-remediation, trigger upgrade — follow as
plain CRUD over the API.  No new package dependencies and no
`clusterctl`/`kubectl`: CAPI is just CRDs on the API server, so the
existing `docker-http` transport and `k8s-get` / PATCH / DELETE
primitives already reach all of it.

The line we will *not* cross: provisioning brand-new clusters from
templates, and installing/upgrading providers, stay with `clusterctl`
(see §8).  This plan targets the read + day-2-management surface, which
is where the value is and where the pure-HTTP constraint holds cleanly.

## 1. What CAPI is on the wire

Everything CAPI exposes is a CustomResource in the management cluster,
across a few API groups.  Kinds we care about (versions are discovered
per-CRD at runtime, see §5 — do **not** hardcode `v1beta1`):

| Group | Kinds |
|-------|-------|
| `cluster.x-k8s.io` | `Cluster`, `MachineDeployment`, `MachineSet`, `Machine`, `MachinePool`, `MachineHealthCheck`, `ClusterClass` |
| `controlplane.cluster.x-k8s.io` | `KubeadmControlPlane` (KCP) |
| `bootstrap.cluster.x-k8s.io` | `KubeadmConfig` |
| `infrastructure.cluster.x-k8s.io` | provider infra — `DockerCluster`/`DockerMachine` (CAPD), `AWSCluster`/`AWSMachine`, `AzureCluster`, `GCPCluster`, … (one group, kind varies by provider) |
| `addons.cluster.x-k8s.io` | `ClusterResourceSet` (v2+ only) |

### The ownership / grouping model

Two complementary linkages:

- **Grouping by cluster** — every owned object carries the label
  `cluster.x-k8s.io/cluster-name=<cluster>`.  Listing all MDs / KCPs /
  Machines for a Cluster is a single label-selector GET, not an
  ownerRef walk.
- **Nesting within a cluster** — `ownerReferences` give the real tree:
  `MachineDeployment` → `MachineSet` → `Machine`; `KubeadmControlPlane`
  → control-plane `Machine`s.  Each `Machine` also points sideways to
  its infra machine (`spec.infrastructureRef`), bootstrap config
  (`spec.bootstrap.configRef`), and — crucially — to the **Node in the
  workload cluster** via `status.nodeRef`.

### Status we render

- `Cluster.status.phase`: Pending / Provisioning / Provisioned /
  Deleting / Failed; plus `status.controlPlaneReady`,
  `status.infrastructureReady` booleans and `status.conditions`.
- `KubeadmControlPlane.status`: `replicas` / `readyReplicas` /
  `updatedReplicas` / `unavailableReplicas`, `spec.version`.
- `MachineDeployment.status`: `replicas` / `readyReplicas` /
  `updatedReplicas` / `availableReplicas`, `status.phase`
  (ScalingUp / ScalingDown / Running / Failed),
  `spec.template.spec.version`.
- `Machine.status.phase`: Provisioning / Provisioned / Running /
  Deleting / Failed; `status.nodeRef`, `status.addresses`.

## 2. The Clusters view (magit-section layout)

A new buffer `*k8s:capi*` (mode derived from `magit-section-mode`,
per the UI conventions; the `*k8s:` prefix means a context-switch's
buffer cleanup catches it).  Target rendering:

```
Cluster prod-eu  (Provisioned)             infra: AWS    k8s v1.30.2
  KubeadmControlPlane  3/3 ready  ✓ up-to-date
  MachineDeployment workers   5/5  ⟳ rolling 1.29→1.30 (2/5 updated)
    MachineSet workers-abc123  (current)
      Machine workers-abc123-x   Running   node ip-10-0-1-7    ✓
      Machine workers-abc123-y   Running   node ip-10-0-1-9    ✓
      …
  MachineDeployment gpu       2/2  Running  v1.30.2
```

Section hierarchy maps 1:1 to the ownership model: `cluster` →
`(controlplane | machinedeployment)` → `machineset` → `machine`.  Each
section's value is the resource alist, so at-point actions (§7) read
it directly — same pattern as the existing pod/deployment views.

## 3. Health / progress rendering — reuse what exists

No new gauge code.  Reuse:

- **Replica readiness** as the `ready/desired` fraction already used by
  Deployments — `k8s-gauge` style or the `N/M` columns.
- **Rollout progress** for KCP/MD upgrades from `updatedReplicas` vs
  `replicas` (`⟳ rolling 1.29→1.30 (2/5)`), the same shape the metrics
  views already render.
- **Phase / conditions** via the pulse-view helpers
  (`k8s-pulse.el` condition/phase counting) — a per-Cluster health
  glyph and a foldable conditions block.

## 4. Detection & dashboard gating

**Shipped (revised from the original gating proposal).**  The
dashboard lists every view unconditionally — gating one launcher on a
live CRD probe would be inconsistent with that and would need an API
call at dashboard-render time (when there may be no connection).  So
the `G` launcher is always present, and detection happens *inside* the
view instead: `k8s-capi--collect` probes the CRD list via
`k8s-crds-list`, and when the `cluster.x-k8s.io` `Cluster` CRD is
absent it returns nil and the view renders a one-line "not a CAPI
management cluster" message — the same graceful-empty-state pattern
`k8s-crds` uses for "(no CRDs installed)".

The launcher row lives in `eltainer-views` (a `defconst` — so the new
row shows up on `eltainer-reload`; a `defvar` would be a silent no-op,
see the reload notes in CLAUDE.md).

## 5. Read path

- **Version discovery.** Build list paths from the CRD's served
  version via `k8s-crds--active-version` (already implemented) rather
  than hardcoding — CAPI bumps storage versions (`v1beta1` → `v1beta2`)
  across releases.
- **Fetches.** All reads are `k8s-get conn PATH` / `k8s-get-resource`
  (existing).  Per Cluster:
  `GET /apis/<grp>/<ver>/namespaces/<ns>/machinedeployments?labelSelector=cluster.x-k8s.io/cluster-name=<cluster>`
  and likewise for `kubeadmcontrolplanes`, `machinesets`, `machines`.
- **JSONPath cells.** Where a value is provider-shaped or nested,
  reuse `k8s-crds--eval-jsonpath` instead of bespoke accessors.
- **Refresh.** `g` re-fetches (manual, magit-style).  Watch-driven
  live refresh is deferred to §9.

## 6. The kubeconfig pivot (the multi-cluster payoff)

CAPI stores each workload cluster's kubeconfig in a Secret named
`<cluster>-kubeconfig` (type `cluster.x-k8s.io/secret`) in the
cluster's namespace; `data.value` is the base64 kubeconfig.

An action on a `Cluster` row (proposed `RET` or `b` for "switch into"):

1. `k8s-get-resource` the Secret, base64-decode `data.value` — the
   decode precedent is `k8s-helm--decode-secret` in `k8s-helm.el`.
2. Hand the bytes to the existing switch path
   (`eltainer-switch-kubeconfig` / `eltainer--discover-kubeconfigs`)
   so the rest of eltainer points at the workload cluster.

This is the feature that makes "manage multiple clusters" real: list
every cluster in the mgmt cluster, drill into any one, browse it, come
back.  It leans entirely on machinery that already exists.

**Resolved — shipped as option (a).**  The decoded kubeconfig is
written to a `0600` file under `k8s-capi-kubeconfig-cache-dir`
(default `$XDG_CACHE_HOME/eltainer/capi`) and handed to the existing
file-based switch via `eltainer--apply-context-switch`.  This reused
everything and was the simplest cut.  One caveat carried forward:
these files hold cluster-admin creds and are not yet garbage-collected
— a cleanup story (or option (b), teaching the connection layer to
accept kubeconfig bytes directly) is future work.

## 7. Lifecycle / write actions (day-2)

All plain CRUD on CRDs — eltainer already has every verb it needs
(`k8s-actions.el` PATCH, `k8s-edit.el` PUT, `k8s-api.el` DELETE).  Each
behind a confirm, magit-key conventions:

| Key | Action | Mechanism |
|-----|--------|-----------|
| `+` / `-` (or a prompt) | Scale an MD / KCP | `scale` subresource PATCH — reuse the existing Deployment scale plumbing; MD/MS/KCP implement `scale` |
| `P` | Pause / resume | toggle `spec.paused` (Cluster) or the `cluster.x-k8s.io/paused` annotation |
| `k` | Delete a Machine (remediation) | DELETE the `Machine`; CAPI replaces it.  For targeted scale-down, set `cluster.x-k8s.io/delete-machine` then scale the owner |
| `d` | Delete a Cluster | DELETE the `Cluster`; CAPI cascades teardown.  Strong confirm (type the name) |
| `u` | Trigger upgrade | PATCH `KubeadmControlPlane.spec.version` / MD `spec.template.spec.version`; the controllers roll machines |

Writes are **v2** (see Rollout) — v1 ships read-only + pivot, which is
already high-value and low-risk.

## 8. Scope boundary — what stays with clusterctl

Out of scope; these genuinely need `clusterctl` (Go templating,
provider controllers, cross-cluster move) and don't fit the pure-HTTP
constraint:

- `clusterctl init` — install/upgrade providers (one-time bootstrap).
- `clusterctl generate cluster` — render a new cluster's manifest from
  templates + env vars.  Cluster *creation* is therefore out; cluster
  *deletion* (DELETE the Cluster object) is in.
- `clusterctl move` — pivot management between clusters.
- `clusterctl upgrade` — provider CRD/controller upgrades.

If templated generation is ever wanted, it would be a named
`clusterctl` shell-out exception, exactly like the existing
`aws eks get-token` / `gke-gcloud-auth-plugin` auth-plugin carve-outs —
not a core code path.

## 9. Deferred / nice-to-have

- `MachineHealthCheck` status and remediation surfacing.
- `ClusterClass` / managed-topology awareness (show the topology
  version, drive upgrades at the Cluster level).
- `MachinePool` (provider-managed node groups) as a sibling of MD.
- Watch-driven live refresh (`?watch=true` on the CAPI lists, reusing
  the existing watch/debounce layer) instead of manual `g`.
- A conditions-detail popup per object.

## 10. File layout & touch list

```
k8s/k8s-capi.el     — NEW: API paths + version discovery, parse of
                      Cluster/KCP/MD/MS/Machine, the *k8s:clusters*
                      magit-section view, health rendering (reusing
                      pulse/gauge), the kubeconfig pivot, and (v2)
                      the lifecycle actions.
```

Touches:

- `reload.el` — add `"k8s-capi"` to `eltainer-k8s-modules`.  **Then
  `M-x eval-buffer` reload.el itself** before `eltainer-reload` will
  see the new module (the module lists are captured at reload.el's load
  time — see CLAUDE.md).
- `eltainer.el` — add the conditional launcher row to `eltainer-views`.
- `README.md` — Requirements (no new dep), the new view + key table,
  the `k8s/` source-tree block.
- `NEWS.md` — user-facing entry when the view ships (new launcher /
  new keys).

## 11. Testing

Fixtures from a **kind + CAPD** management cluster — CAPD (the Docker
infra provider) runs entirely inside kind with no cloud credentials,
which makes it the ideal, reproducible test bed and fits the HTTP
fixture-replay harness (`docs/test-fixtures-plan.md`).  Capture:

- A management cluster with ≥1 workload cluster: the Cluster, its KCP,
  ≥1 MD → MS → Machines, the infra objects, and the
  `<cluster>-kubeconfig` Secret.
- A mid-rollout snapshot (`updatedReplicas < replicas`) so the rollout
  rendering is exercised.
- A non-management cluster (no `cluster.x-k8s.io` group) to assert the
  launcher gating hides the view.

ERT tests over those fixtures cover: list-path/version construction,
the section tree assembly, phase/condition/replica rendering, and the
Secret decode for the pivot.  **Redact** the kubeconfig Secret's
`value` and any cert/token material before checking fixtures in.  The
interactive pivot gesture itself (switching the live connection) can't
be cleanly ERT-tested — note that in the PR rather than implying it is.

## 12. Rollout / order of work

1. **v1 — read-only browser + pivot. — SHIPPED**
   - `k8s-capi.el`: per-CRD version discovery → fetch → label-grouped
     `*k8s:capi*` section tree → phase/replica rendering.
   - Unconditional `G` launcher in `eltainer-views`; detection +
     graceful empty state inside the view (§4).
   - The kubeconfig pivot (§6, option (a)).
   - ERT in `test/test-capi.el` over hand-authored inline fixtures
     (no live CAPI cluster was available to capture kind+CAPD
     fixtures; that capture is still worth doing — see §11).  README +
     NEWS updated.
2. **v2 — lifecycle writes.** Scale, pause/resume, delete-machine,
   delete-cluster, trigger-upgrade (§7), each behind a confirm; tests
   per action.
3. **v3 — niceties.** Items from §9 as appetite allows (watch-driven
   refresh, MHC, ClusterClass/topology, MachinePool).

Mark sections "shipped" here as the corresponding code lands; if the
design shifts mid-implementation, update this doc in the same PR.
