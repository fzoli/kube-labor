#!/bin/bash
set -x
set -euo pipefail

# Use nip.io for demo
IP=$(ip -j addr ls | jq -r ".[${IFN:-1}].addr_info[0] | select(.family == \"inet\") | .local")
ROOT_DOMAIN="${IP//./-}.nip.io"
ARGO_HOST="argocd.$ROOT_DOMAIN"

# Just checks that kubectl is installed (if not, execute init-master-with-cilium.sh)
kubectl get nodes

# Create Argo CD namespace
kubectl create namespace argocd

# Setup certificate issuer
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-server-cert
  namespace: argocd
spec:
  secretName: argocd-server-tls # used by argocd-server pods
  dnsNames:
    - $ARGO_HOST
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
    group: cert-manager.io
EOF

# Wait for certificate
kubectl wait \
  --for=condition=Ready \
  --timeout=180s \
  certificate/argocd-server-cert \
  -n argocd

# Deploy Argo CD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.14.11/manifests/install.yaml

# Deploy TCP ingress for Argo CD
kubectl apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: argocd-route-tcp
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
  - match: HostSNI(\`$ARGO_HOST\`)
    services:
    - name: argocd-server
      port: 443
  tls:
    passthrough: true
EOF

# Install binary
wget https://github.com/argoproj/argo-cd/releases/download/v2.14.11/argocd-linux-amd64
sudo mv argocd-linux-amd64 /usr/local/bin/argocd
sudo chmod ugo+x /usr/local/bin/argocd

# Wait initial secret
until kubectl get secret argocd-initial-admin-secret -n argocd &>/dev/null; do
  sleep 1
done

# Login
ARGO_PASSWORD=$(argocd admin initial-password -n argocd \
           | grep -v '^\s*$' \
           | head -n 1)
argocd login "$ARGO_HOST" --username admin --password "$ARGO_PASSWORD"
