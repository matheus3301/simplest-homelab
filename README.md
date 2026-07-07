# simplest-homelab

A single-node k3s homelab, GitOps-managed with ArgoCD. Public traffic in via a
Cloudflare tunnel, private services over Tailscale, secrets in Vault (synced by
External Secrets), TLS from cert-manager, service mesh via Istio ambient, and
observability via VictoriaMetrics.

Runs on a 4 GB Hetzner VPS: k3s + **flannel** CNI (no Cilium), no Kiali.

## Setup (in order)

1. **[Host hardening](docs/security-hardening.md)** — SSH, fail2ban, UFW, sysctl, swap (before k3s).
2. **[Install k3s](setup/install.md)** — with `setup/config.yaml` (skip `setup/cillium.md`).
3. **[Bootstrap ArgoCD + stack](setup/bootstrap.md)** — ArgoCD then reconciles everything from git.
4. **Vault init + secrets**, then wire ingress/DNS — see the runbook.

## Docs

| Doc | What |
|---|---|
| [deployment-runbook.md](docs/deployment-runbook.md) | End-to-end deploy, **gotchas & fixes**, ingress/DNS wiring |
| [security-hardening.md](docs/security-hardening.md) | Reusable host hardening runbook |
| [resource-tuning.md](docs/resource-tuning.md) | Memory accounting + caps for a 4 GB node |
| [architecture.md](docs/architecture.md) | Stack overview, traffic flows, secrets model |
| [traffic-flow.md](docs/traffic-flow.md) | Request paths (public/private) |
| [cilium-troubleshooting.md](docs/cilium-troubleshooting.md) | Reference only — Cilium is not currently used |

## Layout

```
gitops/
├── 00-bootstrap/   # ArgoCD install, repo, ApplicationSets
├── 01-core/        # Istio, Vault, ESO, cert-manager, Tailscale
├── 02-services/    # monitoring (VictoriaMetrics), cloudflared, Zot
└── 03-apps/        # user apps (hello-world)
setup/              # imperative install steps + k3s config
docs/               # architecture + operational docs
```
