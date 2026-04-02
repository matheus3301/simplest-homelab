# Cilium Troubleshooting

Everything we hit running Cilium v1.19.2 on a single-node k3s homelab with Istio ambient mode.

## Installation

```bash
# Install Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin

# Install Cilium with pod CIDR matching k3s config
cilium install --version 1.19.2 --set=ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16"

# Wait for ready
cilium status --wait
```

## Required Config Changes

### Istio CNI compatibility

Cilium `cni.exclusive=true` (default) keeps removing Istio CNI config. They fight over `/etc/cni/net.d/`.

**Symptoms:** `istio-cni-node` pod stays 0/1, logs show:
```
Configuration has been reconciled multiple times in a short period of time.
Hint: Cilium CNI was detected; ensure 'cni.exclusive=false' in the Cilium configuration.
```

**Fix:**
```bash
cilium config set cni-exclusive false
```

### Native routing mode (recommended for single node)

Default VXLAN tunnel mode is unnecessary on a single node and causes MTU issues.

```bash
cilium config set routing-mode native
cilium config set ipv4-native-routing-cidr 10.42.0.0/16
cilium config set tunnel disabled
```

**What this fixes:**
- Pod MTU drops from 1500 to 1280 with VXLAN (breaks QUIC handshakes)
- Unnecessary encapsulation overhead on a single node

## Known Issues

### ArgoCD NetworkPolicies blocked by Cilium

ArgoCD's raw install manifest includes 7 NetworkPolicies. With Cilium in kube-proxy replacement mode, these policies block internal communication between ArgoCD components (applicationset-controller can't reach repo-server).

**Symptoms:** ApplicationSets show error:
```
connection error: desc = "transport: Error while dialing: dial tcp 10.43.x.x:8081: connect: operation not permitted"
```

**Fix:** Delete NetworkPolicies after every ArgoCD install/upgrade:
```bash
kubectl delete networkpolicies --all -n argocd
```

**Note:** They come back every time you re-apply the raw manifest. Consider stripping them from the YAML permanently.

### BPF recompilation CPU spikes (clang)

Every Cilium config change triggers eBPF program recompilation using `clang`. On a homelab this can:
- Saturate a CPU core for 30-60 seconds
- Cause packet drops during recompilation
- Make Tailscale flap, SSH timeout, services become unreachable

**How to detect:**
```bash
# Check if clang is running
pgrep -a clang

# Check load average
uptime

# Check from host
ps aux --sort=-%cpu | head -10
```

**Mitigation:** Batch config changes together and wait for recompilation to finish before making more changes. Don't panic-delete things during recompilation.

### IPv6 broken in pods

Cilium with IPv4-only IPAM doesn't provide IPv6 routing for pods. Pods get link-local `fe80::` addresses only, no default IPv6 route.

**Symptoms:** Apps that try IPv6 first (like `helm`) hang for 60-90s before falling back to IPv4. Intermittent timeouts on `helm pull`.

**How to verify:**
```bash
# Check pod has no IPv6 route
kubectl run test --rm -i --restart=Never --image=busybox -- sh -c 'ip -6 route show default; ip -6 addr show eth0'

# Test IPv6 connectivity (will fail)
kubectl run test --rm -i --restart=Never --image=curlimages/curl -- curl -6 -s --connect-timeout 5 https://example.com
```

**Fix:** Block AAAA responses in CoreDNS (not yet implemented) or switch to flannel.

### VXLAN MTU reduction

VXLAN adds 50 bytes overhead, reducing pod MTU to ~1280.

**Symptoms:**
- Cloudflared QUIC handshake fails (`timeout: handshake did not complete in time`)
- Post-quantum TLS handshakes fail (large initial packets)

**How to verify:**
```bash
kubectl run test --rm -i --restart=Never --image=busybox -- sh -c 'ip link show eth0 | grep mtu'
# Shows mtu 1280 instead of 1500
```

**Workarounds:**
- Use `--protocol http2` for cloudflared instead of QUIC
- Switch to native routing mode (see above)

### socket LB bypass breaks outbound TCP

Setting `bpf-socket-lb-host-ns-only=true` (recommended by Tailscale docs for kube-proxy replacement mode) breaks all outbound TCP from pods.

**Symptoms:** All pods lose internet connectivity. `curl` from pods times out.

**DO NOT USE:**
```bash
# THIS BREAKS THINGS
cilium config set bpf-socket-lb-host-ns-only true
```

**If you already set it, revert immediately:**
```bash
cilium config set bpf-socket-lb-host-ns-only false
```

### Tailscale Connector + service CIDR conflict

Tailscale Connector advertising `10.43.0.0/16` (service CIDR) conflicts with Cilium's service routing. Causes BPF rate-limited drops (600k+).

**Symptoms:**
- `cilium_bpf_ratelimit_dropped_total` climbing rapidly
- Intermittent connectivity across entire cluster
- Tailscale devices flapping on/off

**How to check:**
```bash
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg metrics list | grep ratelimit_dropped
```

**Workaround:** Use `/32` for specific ClusterIPs instead of the whole CIDR. Still under investigation.

### Tailscale search domain + wildcard DNS = broken cluster

If you add a Tailscale search domain (e.g. `mmonteiro.dev`) AND have a wildcard DNS record (`*.mmonteiro.dev → 10.43.x.x`), ALL DNS lookups from pods will also try `<hostname>.mmonteiro.dev`, which resolves to your gateway IP.

**Symptoms:** External services unreachable. `curl http://ifconfig.me` returns 404 from istio-envoy. DNS resolves `ifconfig.me` to your private gateway IP.

**Root cause:** Tailscale search domain appends `.mmonteiro.dev` to all lookups. `ifconfig.me.mmonteiro.dev` matches the wildcard and returns the gateway ClusterIP.

**Fix:** Remove the search domain from Tailscale admin. Use split DNS or wildcard DNS records instead — they don't append to unrelated lookups.

### UDP buffer sizes for QUIC

Cloudflared QUIC needs larger UDP buffers than the default kernel provides. Even with native routing, the kernel defaults may be too small.

**Symptoms:** Cloudflared log:
```
failed to sufficiently increase receive buffer size (was: 208 kiB, wanted: 7168 kiB, got: 416 kiB)
```

**Fix on host (non-persistent):**
```bash
sudo sysctl -w net.core.rmem_max=7340032
sudo sysctl -w net.core.wmem_max=7340032
```

**Fix on host (persistent):**
```bash
echo -e "net.core.rmem_max=7340032\nnet.core.wmem_max=7340032" | sudo tee /etc/sysctl.d/99-udp-buffers.conf
```

**Note:** We currently use `--protocol http2` for cloudflared as a workaround instead of fixing QUIC.

## Useful Debug Commands

```bash
# Cilium status
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg status

# Check drops
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg metrics list | grep -i drop | grep -v "= 0"

# Check rate limiting
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg metrics list | grep ratelimit

# Check NAT table size
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg bpf nat list | wc -l

# Check current config
kubectl get configmap cilium-config -n kube-system -o json | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; [print(f'{k}: {v}') for k,v in sorted(d.items())]"

# Test connectivity from a pod
kubectl run test --rm -i --restart=Never --image=curlimages/curl -- curl -4 -vs --connect-timeout 5 https://example.com

# Check pod MTU
kubectl run test --rm -i --restart=Never --image=busybox -- sh -c 'ip link show eth0 | grep mtu'

# Check if clang is compiling on host
ssh matheus@192.168.0.10 "pgrep -a clang || echo 'no clang'"

# Monitor host load
ssh matheus@192.168.0.10 "uptime"
```

## Nuclear Option: Switch to Flannel

If Cilium keeps causing issues, swap to flannel (k3s default). Can be done without recreating the cluster:

1. Drain the node
2. Remove Cilium: `cilium uninstall`
3. Remove Cilium CLI artifacts
4. Restart k3s with flannel enabled (remove `flannel-backend: "none"` from `/etc/rancher/k3s/config.yaml`)
5. Restart k3s: `sudo systemctl restart k3s`
6. Uncordon the node

Flannel won't give you eBPF networking or Hubble observability, but for a single-node homelab with Istio handling the mesh, it's more than enough.
