# Bootstrap ArgoCD

# 1. Apply namespace
kubectl apply -f gitops/00-bootstrap/00-argocd-Namespace.yaml

# 2. Apply ArgoCD raw manifest - MUST use -n argocd and server-side apply
kubectl apply -n argocd -f gitops/00-bootstrap/01-argocd-Raw.yaml --server-side --force-conflicts

# 3. Delete NetworkPolicies (conflict with flannel/cilium)
kubectl delete networkpolicies --all -n argocd

# 4. Wait for ArgoCD to be ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s

# 5. Wait for CRDs to be established
kubectl wait --for=condition=Established crd/appprojects.argoproj.io crd/applicationsets.argoproj.io --timeout=60s

# 6. Apply repo secret and ApplicationSets
kubectl apply -f gitops/00-bootstrap/02-homelab-repo-Secret.yaml
kubectl apply -f gitops/01-core/argocd/applications-ApplicationSet.yaml
kubectl apply -f gitops/01-core/argocd/manifests-ApplicationSet.yaml

# 7. ArgoCD picks up everything else from git:
#    - AppProjects, cmd-params, HTTPRoutes, VMServiceScrapes
#    - All 01-core, 02-services, 03-apps components

# --- Vault post-deploy (after pods are running) ---

# Init vault (save the unseal key and root token!)
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json

# Unseal
kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key>

# Store root token for setup job
kubectl create secret generic vault-root-token -n vault --from-literal=token=<root-token>

# The vault-setup Job (ArgoCD PostSync hook) will automatically configure Vault

# --- Restore secrets in Vault ---
# kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=<root-token> vault kv put secret/cloudflared/tunnel-token token=<token>'
# kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=<root-token> vault kv put secret/cloudflare/api-token token=<token>'
# kubectl exec -n vault vault-0 -- sh -c 'VAULT_TOKEN=<root-token> vault kv put secret/tailscale/operator client-id=<id> client-secret=<secret>'

# --- ArgoCD memory tuning for small nodes (post-bootstrap) ---
# The argocd install (01-argocd-Raw.yaml) ships without resource limits. On a
# ~4GB node, cap the components and disable unused controllers. The concurrency
# knobs live in git (argocd-cmd-params-ConfigMap.yaml); the rest are applied to
# the bootstrap-managed workloads directly:

# Disable unused controllers (no SSO / no notifications configured)
kubectl scale deploy argocd-dex-server argocd-notifications-controller -n argocd --replicas=0

# application-controller: cap RSS with a Go soft memory limit + resources
kubectl -n argocd set env statefulset/argocd-application-controller GOMEMLIMIT=400MiB
kubectl -n argocd patch statefulset argocd-application-controller --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"100m","memory":"256Mi"},"limits":{"memory":"512Mi"}}}]'

# repo-server / server / applicationset / redis
kubectl -n argocd set env deploy/argocd-repo-server GOMEMLIMIT=192MiB
kubectl -n argocd patch deploy argocd-repo-server --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"50m","memory":"96Mi"},"limits":{"memory":"256Mi"}}}]'
kubectl -n argocd patch deploy argocd-server --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"25m","memory":"64Mi"},"limits":{"memory":"192Mi"}}}]'
kubectl -n argocd patch deploy argocd-applicationset-controller --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"25m","memory":"48Mi"},"limits":{"memory":"160Mi"}}}]'
kubectl -n argocd patch deploy argocd-redis --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"25m","memory":"32Mi"},"limits":{"memory":"128Mi"}}}]'
