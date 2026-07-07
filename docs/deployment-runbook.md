# Deployment Runbook & Operational Notes

End-to-end record of bringing the stack up on a fresh Hetzner VPS
(Ubuntu 26.04, 3 vCPU / 4 GB), plus the gotchas hit along the way and their
fixes. Read alongside `setup/` (imperative steps) and `security-hardening.md`.

## Order of operations

1. **[Host hardening](security-hardening.md)** — SSH, fail2ban, UFW, sysctl, swap (before k3s).
2. **Install k3s** — `setup/install.md` + `setup/config.yaml`. **Cilium is not used**
   (see below); k3s keeps its default flannel CNI.
3. **Bootstrap ArgoCD + stack** — `setup/bootstrap.md`.
4. **Vault init + secrets**, then **wire ingress/DNS**.

## This deployment's deltas from a vanilla install

- **No Cilium.** `istio-cni` is already configured with `platform: k3s` to chain
  onto flannel (`gitops/01-core/istio-system/istio-cni-Application.yaml`), so
  dropping Cilium matches the design. Skip `setup/cillium.md` entirely; k3s runs
  flannel (VXLAN). QUIC still needs the `--protocol http2` workaround for
  cloudflared (flannel MTU).
- **No Kiali** — removed to save RAM on a 4 GB node.
- **`tls-san`** in `setup/config.yaml` must list this host's public IP, tailnet
  IP, and MagicDNS name so `kubectl` works over Tailscale.

## Bootstrap gotchas & fixes

### 1. AppProjects don't exist yet → ApplicationSets error
`setup/bootstrap.md` applies the ApplicationSets, but the generated Applications
reference projects `core`/`services`/`apps`, which are themselves managed as
manifests → chicken-and-egg. **Fix:** apply the projects directly once, before
the ApplicationSets converge:
```bash
kubectl apply -f gitops/01-core/argocd/projects/
```

### 2. ArgoCD `ERR_TOO_MANY_REDIRECTS`
argocd-server does its own HTTPS redirect while the private gateway already
terminates TLS → redirect loop. The repo sets `server.insecure: "true"` in
`argocd-cmd-params-ConfigMap.yaml`, but **argocd-server starts during bootstrap
before that ConfigMap is applied**. **Fix:** restart it once after bootstrap:
```bash
kubectl rollout restart deploy/argocd-server -n argocd
```

### 3. Pods stuck `ContainerCreating` on a missing secret mount
`vault-setup` (and the tailscale operator) are created before the secrets they
mount exist; kubelet's remount backoff is long. **Fix:** delete the stuck pod so
its controller recreates it once the secret is present:
```bash
kubectl delete pod -n vault -l job-name=vault-setup
```

### 4. ExternalSecrets `SecretSyncedError` until the store is valid
The `vault` ClusterSecretStore reports `InvalidProviderConfig` if ESO started
before Vault was unsealed/configured. **Fix:** after Vault init + `vault-setup`
completes, restart ESO: `kubectl rollout restart deploy/external-secrets -n external-secrets`.

### 5. Istio does NOT honor `spec.addresses` (ClusterIP pin)
On Istio 1.28, pinning the private gateway's ClusterIP via Gateway
`spec.addresses` is a **no-op** — the `private-istio` Service gets a *dynamic*
ClusterIP. The advertised subnet route (see below) and the Cloudflare wildcard
DNS must match the **actual** assigned ClusterIP:
```bash
kubectl get svc private-istio -n istio-system -o jsonpath='{.spec.clusterIP}'
```
Put that value in the host's `tailscale set --advertise-routes` and the
`*.mmonteiro.dev` A record. If the Service is ever recreated, the IP changes and
both must be updated.

## Vault init + secrets

```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json  # SAVE keys
kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key>
kubectl create secret generic vault-root-token -n vault --from-literal=token=<root-token>
# store the 3 secrets (cloudflared tunnel, cloudflare api-token, tailscale operator) — see bootstrap.md
```
The unseal key + root token are single-shard — losing them means losing the Vault.

## Ingress / DNS wiring

- **Public** (`hello.mmonteiro.dev`): Cloudflare tunnel (outbound). The tunnel's
  public-hostname → `http://public-istio.istio-system.svc.cluster.local:80` is
  managed in the Cloudflare Zero Trust dashboard (the DNS-scoped API token cannot
  edit tunnel config).
- **Private** (`*.mmonteiro.dev`): wildcard A record → private-istio ClusterIP
  (**DNS only, proxy OFF**). Reachable only from the tailnet via the subnet route.
- **Subnet router = the HOST's tailscaled, not an in-cluster Connector.** The host
  advertises the ClusterIP as a subnet route and forwards to it (the host is the
  k8s node, so kube-proxy DNATs the ClusterIP to the backend pod):
  ```bash
  tailscale set --advertise-routes=<private-istio-clusterIP>/32   # on the host
  ufw allow 41641/udp                                             # WireGuard underlay
  ```
  Why not the operator `Connector`? The Connector runs as a **pod behind the
  node's MASQUERADE (symmetric NAT)** — `netcheck` shows `MappingVariesByDestIP:
  true`, so it can only reach the tailnet via a **DERP relay** (bandwidth-capped).
  The host has a public IP with no NAT (`MappingVariesByDestIP: false`), so it
  gets a **direct, full-throughput** WireGuard path. (Note: for a client far from
  the VPS, DERP may show *lower latency* than direct — but direct wins on
  throughput, which matters for image push/pull and backups.)
- **Tailnet route approval:** the advertised route (`<clusterIP>/32`) must be
  approved in the Tailscale admin console for the **`javazap-cloud`** node (no
  `autoApprovers` configured). Add an `autoApprovers.routes` entry for that node
  so future ClusterIP changes self-approve.
- cert-manager issues the Let's Encrypt `*.mmonteiro.dev` wildcard via Cloudflare
  DNS-01; the private gateway terminates TLS.

## Resource tuning (4 GB node)

See `resource-tuning.md` for the full memory accounting, what was capped, and
which levers are/aren't worth pulling.
