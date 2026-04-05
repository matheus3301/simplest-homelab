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
