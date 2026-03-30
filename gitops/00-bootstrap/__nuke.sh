#!/bin/bash

echo "Nuking ArgoCD installation..."

# Remove finalizers from ArgoCD resources (they block deletion)
echo "Removing finalizers..."
kubectl get applications -n argocd -o name 2>/dev/null | xargs -I {} kubectl patch {} -n argocd --type json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
kubectl get appprojects -n argocd -o name 2>/dev/null | xargs -I {} kubectl patch {} -n argocd --type json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
kubectl get applicationsets -n argocd -o name 2>/dev/null | xargs -I {} kubectl patch {} -n argocd --type json -p '[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true

# Delete everything using the same manifests used to create
echo "Deleting bootstrap resources..."
kubectl delete -f kubernetes/bootstrap/ -n argocd 2>/dev/null || true

# Delete CRDs (not included in bootstrap manifests cleanup)
echo "Deleting ArgoCD CRDs..."
kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io 2>/dev/null || true

echo ""
echo "ArgoCD nuked!"
echo ""
echo "To reinstall: kubectl apply -f kubernetes/bootstrap/ -n argocd"
