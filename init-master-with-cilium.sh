#!/bin/bash
set -x

export GLOBAL_NETWORK=10.0.0.0/9
export POD_NETWORK=10.1.0.0/16
export CLUSTER_ID=1

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

sudo snap install helm --classic
helm repo add cilium https://helm.cilium.io/

sudo apt install -y wireguard-tools
kubectl taint nodes cka02-master-01 node-role.kubernetes.io/control-plane:NoSchedule-
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

