# Resource Tuning (4 GB node)

The stack (service mesh + GitOps + Vault + full observability + registry) is
heavy for a 4 GB VPS. This documents where the RAM goes, what was capped, and —
importantly — which levers were tested and found **not** worth pulling.

## Memory accounting (~3.3 GB used of 3.8 GB)

| Subsystem | RAM | Notes |
|---|---|---|
| **k3s control plane** | ~700–770 MB | apiserver + kine + kubelet + containerd + scheduler/CM, one process. **Effectively fixed.** |
| containerd shims | ~270 MB | ~8 MB × ~34 pods of runtime overhead |
| Monitoring (VictoriaMetrics) | ~786 MB | largest workload |
| ArgoCD | ~560 MB | |
| Istio ambient mesh | ~255 MB | istiod + ztunnel + 2 gateways + 2 waypoints + cni |
| external-secrets | ~128 MB | |
| tailscale / zot / vault / cert-manager / cloudflared | ~205 MB | |

**~1 GB (k3s + shim overhead) is an unavoidable floor** before any workload runs.
On Linux, "used" also includes reclaimable cache; the box is stable (no OOM, swap
flat) at ~75% used.

## What was capped (all in git, `helm template`-validated)

Nothing had resource limits out of the box — workloads could balloon until OOM.
Everything now has hard caps (they bound worst-case, they don't cut steady use much):

**VictoriaMetrics** (`victoria-metrics-k8s-stack-Application.yaml`):
- Removed the alerting stack (`vmalert` + `alertmanager` + `defaultRules`) — no
  receivers were configured, so it was pure overhead.
- `vmsingle`: `retentionPeriod: 7d`, `memory.allowedPercent: 40`, limit **512Mi**
  (384Mi OOMed during WAL replay), storage 8Gi.
- `vmagent`: limit **256Mi** (160Mi ran at ~95%).
- `grafana`: limit 224Mi.
- **Grafana sidecars**: the two `k8s-sidecar` (python) containers were uncapped
  at ~75–80 MB each. Capped via the **shared** `grafana.sidecar.resources`
  (128Mi) — per-sidecar `resources` keys are silently ignored by the chart
  (caught with `helm template`). Also scoped them to the `monitoring` namespace
  (`searchNamespace`) since all dashboards/datasource live there.
- `kube-state-metrics` 96Mi, `node-exporter` 64Mi, `victoria-metrics-operator` 128Mi.

**ArgoCD** — the install (`00-bootstrap/01-argocd-Raw.yaml`) ships with no limits.
Concurrency knobs are git-tracked in `argocd-cmd-params-ConfigMap.yaml`
(`controller.status.processors: 4`, `operation.processors: 2`,
`kubectl.parallelism.limit: 4`, `reposerver.parallelism.limit: 2`). The rest is
applied to the bootstrap-managed workloads directly — **documented in
`setup/bootstrap.md`** ("ArgoCD memory tuning" section):
- Disabled **dex** + **notifications** controllers (unused: no SSO, no notifications).
- `GOMEMLIMIT=400MiB` on the application-controller → RSS ~500 MB → ~380 MB.
- Resource limits on controller / repo-server / server / applicationset / redis.

## Levers tested and rejected

- **k3s Go GC tuning** (`GOGC=50` + `GOMEMLIMIT=600MiB`): pulled k3s RSS from
  ~716 MB to ~585 MB but drove it to **242% CPU / load ~4 on 3 vCPUs** (constant
  GC — the live heap *is* ~600 MB). Reverted. **k3s memory is not reclaimable**
  without paying CPU the box doesn't have.
- **Reducing CRDs** would cut apiserver cache (89 CRDs installed), but each means
  removing an operator/feature (Istio, VM, ESO, cert-manager, …).

## If more RAM is genuinely needed

Tuning is exhausted. Real reclaim requires removing a subsystem or resizing:

| Action | Frees | Cost |
|---|---|---|
| Drop Grafana + sidecars (keep vmsingle `vmui`) | ~300 MB | lose dashboards, keep metrics + query UI |
| Raise scrape interval to 60s, drop cadvisor series | ~100–150 MB | coarser resolution |
| Drop monitoring entirely | ~786 MB | no metrics |
| ArgoCD → Flux | ~400 MB | GitOps re-architecture |
| **Resize to 8 GB (Hetzner CPX31)** | — | ~€4/mo; zero refactor, real headroom |

The current state is stable (no OOM, swap not thrashing); further reduction is a
comfort/headroom choice, not a fix for an active problem.
