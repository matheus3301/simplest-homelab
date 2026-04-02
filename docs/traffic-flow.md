# Traffic Flow: Cloudflare → Istio → Service

## Overview

This homelab uses Cloudflare Tunnels + Istio ambient mode + Gateway API to route external traffic to services running in k3s. No ports are exposed on the host — all traffic flows through an outbound tunnel.

## The Full Path

```
User (internet)
    │
    ▼
Cloudflare Edge (CDN, WAF, DDoS protection, SSL termination)
    │
    │  Cloudflare Tunnel (encrypted, outbound-only)
    │
    ▼
cloudflared pod (cloudflared namespace)
    │
    │  HTTP to ClusterIP service
    │
    ▼
Istio Gateway pod (istio-system namespace)
    │
    │  Gateway API routing (hostname + path matching)
    │
    ▼
Application pod (app namespace)
```

## Components Explained

### 1. Cloudflare Tunnel (cloudflared)

The `cloudflared` pod creates an outbound connection to Cloudflare's edge network. This means:

- No inbound ports needed on your firewall/router
- Cloudflare handles SSL, CDN caching, WAF, and DDoS protection for free
- Traffic is encrypted between Cloudflare and your cluster

The tunnel is **remotely managed** — you configure which hostnames route to which services in the Cloudflare dashboard. All hostnames point to the same backend: the Istio public gateway.

```
Cloudflare Dashboard → Public Hostname:
  hello.mmonteiro.dev → http://public-istio.istio-system.svc.cluster.local:80
```

cloudflared doesn't know or care about individual services. It just forwards everything to the Istio gateway and lets Istio handle the routing.

### 2. Istio Gateway (Gateway API)

The Istio Gateway is the entry point into the service mesh. It's a standard Kubernetes Gateway API resource:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public
  namespace: istio-system
  annotations:
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All  # any namespace can attach routes
```

This creates:
- An Envoy proxy pod (`public-*` in istio-system)
- A ClusterIP Service (`public-istio`) that cloudflared sends traffic to

We have two gateways:
- **public** — for internet-facing services (cloudflare tunnel points here)
- **private** — for internal services (accessible within cluster / tailscale only)

### 3. HTTPRoute (Gateway API)

HTTPRoutes define how traffic gets routed from a Gateway to your services. They live in the **application's namespace**, not in istio-system:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: apps-hello-world
  namespace: apps-hello-world
spec:
  parentRefs:
    - name: public              # which gateway to attach to
      namespace: istio-system
      sectionName: http         # which listener on the gateway
  hostnames:
    - "hello.mmonteiro.dev"     # match this hostname
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: apps-hello-world  # route to this service
          port: 80
```

The hostname in the HTTPRoute **must match** what you configured in the Cloudflare tunnel dashboard. Istio uses the `Host` header to decide which HTTPRoute handles the request.

### 4. Waypoint Proxies (optional, for L7 between services)

Istio ambient mode works at L4 by default (mTLS between pods via ztunnel). If you need L7 features **between services** (retries, traffic splitting, request routing), you deploy a waypoint:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint-public
  namespace: istio-system
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
```

Waypoints are **not needed** for basic ingress routing — that's handled by the Gateway + HTTPRoute above. Waypoints are for service-to-service L7 policies inside the mesh.

## How to Expose a New Service

1. **Deploy your app** with a Deployment + Service in `03-apps/`

2. **Create an HTTPRoute** in the app's namespace, attaching to the public gateway:
   ```yaml
   spec:
     parentRefs:
       - name: public
         namespace: istio-system
         sectionName: http
     hostnames:
       - "myapp.mmonteiro.dev"
   ```

3. **Add the hostname in Cloudflare** dashboard → tunnel → public hostname:
   - Subdomain: `myapp`
   - Domain: `mmonteiro.dev`
   - Service: `http://public-istio.istio-system.svc.cluster.local:80`

That's it. Cloudflare routes traffic to cloudflared → Istio gateway matches the hostname via HTTPRoute → traffic reaches your service.

## What Cloudflare Gives You

Since all traffic passes through Cloudflare's edge:

- **SSL/TLS** — automatic HTTPS, no cert management needed
- **CDN** — static content cached at edge (300+ locations)
- **WAF** — web application firewall rules
- **DDoS protection** — automatic L3/L4/L7 mitigation
- **Bot management** — challenge suspicious traffic
- **Analytics** — traffic insights in the dashboard
- **WebSockets, gRPC, SSE** — all supported through tunnels

## Private vs Public

| | Public Gateway | Private Gateway |
|---|---|---|
| Exposed to internet | Yes (via Cloudflare) | No |
| Access method | `*.mmonteiro.dev` | Cluster internal / Tailscale |
| cloudflared routes to | `public-istio:80` | N/A |
| Use case | Public apps, APIs | Dashboards, admin tools, internal services |
