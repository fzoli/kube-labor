Install the NVIDIA driver:

```sh
sudo apt update
sudo apt install -y ubuntu-drivers-common
sudo ubuntu-drivers autoinstall
```

Install containerd based on default config, updated for kubernetes:

```sh
sudo apt install -y containerd
sudo mkdir -p /etc/containerd/
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -ie 's|SystemdCgroup = false|SystemdCgroup = true|' /etc/containerd/config.toml
sudo sed -ie 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
sudo systemctl restart containerd
```

Then install NVIDIA container toolkit and the device plugin: https://github.com/NVIDIA/k8s-device-plugin

```sh
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd
```

After executing `sudo nvidia-ctk runtime configure --runtime=containerd` the default runtime stays the same: `runc`

There are two options.

**A) Change the default runtime to nvidia**

This is the simplest solution, but each container will use the NVIDIA runtime on this node.

```sh
sudo sed -i 's/^\(\s*default_runtime_name\s*=\s*\)"runc"/\1"nvidia"/' /etc/containerd/config.toml
sudo systemctl restart containerd
```

Relevant result:

```toml
# /etc/containerd/config.toml
[plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "nvidia"
```

From this point, install kubernetes.

Here is a single node playground example using kubeadm and cilium with wireguard:

```sh
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

if [ -z ${IP+x} ]; then   export IP=$(ip -j addr ls | jq -r ".[${IFN:-1}].addr_info[0] | select(.family == \"inet\") | .local"); fi
echo API server IP: $IP
sudo kubeadm init --apiserver-advertise-address ${IP} --pod-network-cidr ${POD_NETWORK} --ignore-preflight-errors=NumCPU --skip-phases=addon/kube-proxy
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

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
```

Install NVIDIA device plugin:

```sh
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --version 0.17.1
```

Add nvidia gpu label to the node:
```sh
kubectl label node ${NODE_NAME} nvidia.com/gpu.present=true
# kubectl label node ${NODE_NAME} nvidia.com/mps.capable=true # if MPS is supported by your GPU; to check it run nvidia-smi -q | grep -i MPS
```

Test it:
```sh
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  restartPolicy: Never
  containers:
    - name: cuda-container
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
      resources:
        limits:
          nvidia.com/gpu: 1 # requesting 1 GPU
#          nvidia.com/mps: 1 # or requesting 1 MPS server
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
EOF
```

```sh
kubectl logs gpu-pod
```

Expected output:
```text
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

```sh
kubectl delete pod/gpu-pod
```

Activate time slicing:

```sh
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: plugin-config
  namespace: nvidia-device-plugin
data:
  time-slicing: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: false
        resources:
          - name: nvidia.com/gpu
            replicas: 4
EOF
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --set config.name=plugin-config \
  --set config.default=time-slicing
```

**B) Define nvidia RuntimeClass and patch the device plugin then use `runtimeClassName: nvidia` on each pod where nvidia card is required.**

```sh
helm upgrade -i nvdp nvdp/nvidia-device-plugin   --namespace nvidia-device-plugin   --create-namespace   --version 0.17.1
cat <<EOF | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF
kubectl -n nvidia-device-plugin patch daemonset nvdp-nvidia-device-plugin   --type=json -p='[
    {"op":"add","path":"/spec/template/spec/runtimeClassName","value":"nvidia"},
    {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"NVIDIA_VISIBLE_DEVICES","value":"all"}}
  ]'
```

Test it:

```sh
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  containers:
    - name: cuda-container
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
      resources:
        limits:
          nvidia.com/gpu: 1 # requesting 1 GPU
#          nvidia.com/mps: 1 # or requesting 1 MPS server
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
EOF
kubectl logs gpu-pod
```
