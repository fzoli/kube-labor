#!/bin/bash
set -x
set -euo pipefail

export LE_EMAIL_ADDRESS="info@example.com" # TODO: replace it with your own address (Let's Encrypt rejects example.com) then remove next line
exit 1

export GLOBAL_NETWORK=10.0.0.0/9
export POD_NETWORK=10.1.0.0/16
export CLUSTER_ID=1

# Init single node cluster

export VERSION=${VERSION:-1.32}
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
sudo tee /etc/modules-load.d/k8s.conf <<EOF
br_netfilter
overlay
EOF

sudo modprobe br_netfilter
sudo modprobe overlay
sudo tee /etc/sysctl.d/99-k8s.conf <<EOF
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

sudo systemctl restart procps
sudo apt install -y containerd
sudo mkdir -p /etc/containerd/
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -ie 's|SystemdCgroup = false|SystemdCgroup = true|' /etc/containerd/config.toml
sudo sed -ie 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
sudo systemctl restart containerd
if [ -z ${IP+x} ]; then   export IP=$(ip -j addr ls | jq -r ".[${IFN:-1}].addr_info[0] | select(.family == \"inet\") | .local"); fi
echo API server IP: $IP
sudo kubeadm init --apiserver-advertise-address ${IP} --pod-network-cidr ${POD_NETWORK} --ignore-preflight-errors=NumCPU --skip-phases=addon/kube-proxy
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes

# Setup Cilium CNI

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}{"\n"}')

sudo snap install helm --classic
helm repo add cilium https://helm.cilium.io/

sudo apt install -y wireguard-tools
kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule-
helm install cilium cilium/cilium --version 1.17.3 --namespace kube-system --set ipv4NativeRoutingCIDR=$GLOBAL_NETWORK --set cluster.name=doa$CLUSTER_ID --set cluster.id=$CLUSTER_ID --set operator.replicas=1 --set kubeProxyReplacement=true --set k8sServiceHost=${IP} --set k8sServicePort=6443 --set encryption.enabled=true --set encryption.type=wireguard

CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

cilium status --wait

kubectl get nodes
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement

# Deploy Traefik ingress

helm repo add traefik https://traefik.github.io/charts
helm repo update

kubectl label nodes "$NODE_NAME" ingress-ready=true

helm install traefik traefik/traefik \
  --namespace ingress-traefik --create-namespace \
  --version 35.1.0 \
  -f - <<EOF

nodeSelector:
  ingress-ready: "true"

hostNetwork: true

ports:
  web:
    port: 80
  websecure:
    port: 443
    hostPort: 443
    http3:
      enabled: true
      advertisedPort: 443

service:
  single: false

# Enable dashboard without exposing it
ingressRoute:
  dashboard:
    enabled: true

# Custom image that supports TLS curve X25519MLKEM768
image:
  repository: progfarkas/pqtraefik
  tag: v3.0.1-2
versionOverride: v3.0.1

# Enable default namespace
providers:
  kubernetesCRD:
    enabled: true
    namespaces:
      - ingress-traefik
      - default
  kubernetesIngress:
    allowExternalNameServices: true

# Configure logger plugin
experimental:
  plugins:
    traefiklogger:
      moduleName: github.com/fzoli/traefiklogger
      version: v0.10.0

# Allow bind to port 80 and 443
securityContext:
  capabilities:
    drop: [ALL]
    add: [NET_BIND_SERVICE]
  readOnlyRootFilesystem: true
  runAsGroup: 0
  runAsNonRoot: false
  runAsUser: 0

EOF

helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.12.0 \
  --set installCRDs=true

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $LE_EMAIL_ADDRESS
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
EOF

kubectl apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  namespace: default
  name: mlkemtls
spec:
  sniStrict: false
  minVersion: VersionTLS13
  curvePreferences:
    - X25519MLKEM768
    - CurveP521
    - CurveP384
EOF

kubectl apply -f - <<EOF
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  namespace: default
  name: jsonlogger
spec:
  plugin:
    traefiklogger:
      Enabled: true
      Name: json-logger
      LogFormat: json
EOF
