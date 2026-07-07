# Host Security Hardening

Applied to the VPS **before** installing k3s. Order matters: harden + firewall
first so k3s layers its iptables rules on top cleanly. Every SSH/firewall change
was verified with a *second* live session before proceeding, to avoid lockout.

Threat-model note: the homelab needs **no public inbound web ports** — public
traffic arrives via the outbound Cloudflare tunnel (`cloudflared`), and private
services are reached over Tailscale. The only public port is SSH (22).

## 1. System updates

```bash
apt update && apt full-upgrade -y
# unattended-upgrades is enabled by default on Ubuntu; keep it for security patches
```

Reboot if a new kernel was installed (`/var/run/reboot-required`).

## 2. SSH hardening

`/etc/ssh/sshd_config.d/99-hardening.conf`:

```
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

```bash
sshd -t && systemctl reload ssh   # validate before reload
# then confirm a NEW ssh session connects before closing the current one
```

## 3. fail2ban

`/etc/fail2ban/jail.d/sshd.local`:

```ini
[DEFAULT]
backend = systemd
bantime = 1h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w
findtime = 10m
maxretry = 4
# never ban the tailnet (Tailscale CGNAT range)
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10

[sshd]
enabled = true
port = ssh
```

```bash
apt install -y fail2ban
systemctl enable --now fail2ban
fail2ban-client status sshd
```

## 4. UFW (k3s-safe)

k3s manages its own iptables rules; UFW must not block pod/service traffic.
Set `DEFAULT_FORWARD_POLICY="ACCEPT"` in `/etc/default/ufw`, then:

```bash
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp                 # rate-limit SSH (fail2ban complements this)
ufw allow in on tailscale0       # full tailnet access (incl. kube API 6443, kubelet)
ufw allow from 10.42.0.0/16      # k3s pod CIDR
ufw allow from 10.43.0.0/16      # k3s service CIDR
ufw enable
```

Result: only **22/tcp** is exposed to the public internet. The kube API (6443)
and kubelet (10250) are reachable only over `tailscale0`.

> The `ufw status` line may show `disabled (routed)` — cosmetic. The actual
> FORWARD chain is governed by `DEFAULT_FORWARD_POLICY=ACCEPT`, which is what
> keeps k3s pod networking working.

## 5. sysctl (CNI-safe hardening)

`/etc/sysctl.d/99-hardening.conf`:

```
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 1
kernel.dmesg_restrict = 1
```

**Do NOT** set `net.ipv4.ip_forward=0` (k3s needs forwarding) and **leave
`rp_filter` at its default** — strict reverse-path filtering breaks
flannel/kube-proxy. Also apply the k3s/QUIC bits (see `setup/install.md`,
`setup/sysctl.md`): `net.ipv6.conf.{all,default}.forwarding=1`,
`net.core.{r,w}mem_max=7340032`.

## 6. Swap (safety net)

The stack is memory-tight on a 4 GB node; add swap so a spike evicts to disk
instead of OOM-killing. It is a cushion, not a substitute for RAM.

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
# vm.swappiness=10 (set in /etc/sysctl.d/99-k3s-homelab.conf)
```

## Verification

```bash
# From an OFF-tailnet host: only 22 should answer
for p in 22 80 443 6443 8200; do nc -z -w4 <public-ip> $p && echo "$p open" || echo "$p filtered"; done
ufw status verbose
fail2ban-client status sshd
```
