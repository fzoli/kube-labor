## HA control plane IP

Example:

```sh
helm repo add kube-vip https://kube-vip.github.io/helm-charts
helm repo update

helm install kube-vip kube-vip/kube-vip \
  -n kube-system \
  --set config.address=192.168.1.199 \
  --set config.interface=wlp0s20f3 \
  --set env.cp_enable=true \
  --set env.svc_enable=false \
  --set env.vip_arp=true \
  --set env.vip_interface=wlp0s20f3

kubectl config set-cluster microk8s-cluster --server=https://192.168.1.199:16443
```

## On-premise load balancer

```sh
helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb

# # if docker swarm is installed, change speaker bind port:
# helm upgrade metallb metallb/metallb --set speaker.memberlist.mlBindPort=7947
```

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: sandbox
spec:
  addresses:
  - 192.168.1.200-192.168.1.250
  - fd00::200-fd00::250

---

# BGP is preferred, but consumer routers do not support it.

#apiVersion: metallb.io/v1beta1
#kind: BGPAdvertisement
#metadata:
#  name: local
#spec:
#  ipAddressPools:
#  - sandbox

apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local
spec:
  ipAddressPools:
  - sandbox
  #interfaces:
  #- eth0

---

apiVersion: v1
kind: Service
metadata:
  name: nginx
  annotations:
    metallb.io/address-pool: sandbox
spec:
  ipFamilyPolicy: PreferDualStack
  ipFamilies:
  - IPv4
  - IPv6
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: nginx
  type: LoadBalancer

---

apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
          protocol: TCP
```
