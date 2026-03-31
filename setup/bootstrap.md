# Bootstrap ArgoCD

# 1. Apply bootstrap manifests (CRDs + namespace first)
kubectl apply -f gitops/00-bootstrap/00-argocd-Namespace.yaml

# 2. Apply ArgoCD raw manifest - MUST use -n argocd (no namespace in the YAML)
kubectl apply -n argocd -f gitops/00-bootstrap/01-argocd-Raw.yaml --server-side --force-conflicts

# 3. Delete NetworkPolicies - they conflict with Cilium
kubectl delete networkpolicies --all -n argocd

# 4. Wait for ArgoCD to be ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s

# 5. Apply repo, projects, and applicationsets
kubectl apply -f gitops/00-bootstrap/02-homelab-repo-Secret.yaml
kubectl apply -f gitops/00-bootstrap/03-core-AppProject.yaml
kubectl apply -f gitops/00-bootstrap/04-services-AppProject.yaml
kubectl apply -f gitops/00-bootstrap/05-apps-AppProject.yaml
kubectl apply -f gitops/00-bootstrap/06-core-applications-ApplicationSet.yaml
kubectl apply -f gitops/00-bootstrap/07-core-manifests-ApplicationSet.yaml
kubectl apply -f gitops/00-bootstrap/08-services-applications-ApplicationSet.yaml
kubectl apply -f gitops/00-bootstrap/09-services-manifests-ApplicationSet.yaml
kubectl apply -f gitops/00-bootstrap/10-apps-applications-ApplicationSet.yaml
kubectl apply -f gitops/00-bootstrap/11-apps-manifests-ApplicationSet.yaml

# 6. ArgoCD will now sync everything from git automatically

# --- Vault post-deploy (after pods are running) ---

# Init vault (save the unseal key and root token!)
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json

# Unseal
kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key>

# Store root token for setup job
kubectl create secret generic vault-root-token -n vault --from-literal=token=<root-token>

# The vault-setup Job (ArgoCD PostSync hook) will automatically:
# - Enable KV v2 at secret/
# - Create external-secrets policy
# - Enable Kubernetes auth
# - Create external-secrets role

# NOTE: Vault needs manual unseal after every pod restart
