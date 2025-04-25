# Local Console

## Installing the Cilium binary (if not already installed)

```sh
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

## Preparing Helm

```sh
sudo snap install helm --classic
helm repo add cilium https://helm.cilium.io/
```

## Creating two masters; no workers are needed for this example.

```sh
./labor.sh create 2 0
```

The POD CIDRs must differ between the two clusters.
The service CIDR can stay the same.

# Cluster 1 SSH (cka02-master-01)

Run `ps ax | grep python | grep cloud` and if the output is empty, the following commands can be issued.

```sh
export POD_NETWORK=10.1.0.0/16
./k8s-prepare.sh master

# 'cilium clustermesh enable' does not run automatically on the master; since there are no workers, we remove this taint
kubectl taint nodes cka02-master-01 node-role.kubernetes.io/control-plane:NoSchedule-

sed -i 's/^\(\s*name:\s*\)kubernetes$/\1doa-01-cluster/' ~/.kube/config
sed -i 's/^\(\s*-\s*name:\s*\)kubernetes-admin$/\1doa-01-admin/' ~/.kube/config
sed -i 's/^\(\s*name:\s*\)kubernetes-admin@kubernetes$/\1doa1/' ~/.kube/config
sed -i 's/^\(\s*cluster:\s*\)kubernetes$/\1doa-01-cluster/' ~/.kube/config
sed -i 's/^\(\s*user:\s*\)kubernetes-admin$/\1doa-01-admin/' ~/.kube/config
sed -i 's/^current-context: kubernetes-admin@kubernetes$/current-context: doa1/' ~/.kube/config
cat ~/.kube/config
```

# Cluster 2 SSH (cka02-master-02)

```sh
export POD_NETWORK=10.2.0.0/16
./k8s-prepare.sh master
kubectl taint nodes cka02-master-02 node-role.kubernetes.io/control-plane:NoSchedule-

sed -i 's/^\(\s*name:\s*\)kubernetes$/\1doa-02-cluster/' ~/.kube/config
sed -i 's/^\(\s*-\s*name:\s*\)kubernetes-admin$/\1doa-02-admin/' ~/.kube/config
sed -i 's/^\(\s*name:\s*\)kubernetes-admin@kubernetes$/\1doa2/' ~/.kube/config
sed -i 's/^\(\s*cluster:\s*\)kubernetes$/\1doa-02-cluster/' ~/.kube/config
sed -i 's/^\(\s*user:\s*\)kubernetes-admin$/\1doa-02-admin/' ~/.kube/config
sed -i 's/^current-context: kubernetes-admin@kubernetes$/current-context: doa2/' ~/.kube/config
cat ~/.kube/config
```

Sorry for the ugly `sed` block, but beautifying it is not the focus right now.

# Local Console

# Merging the Two Config Files

In the code below, replace the IP addresses with your own. I promise, this is the last manual step.

```sh
scp doa@10.240.3.58:.kube/config config-doa1
scp doa@10.240.3.71:.kube/config config-doa2
KUBECONFIG=config-doa1:config-doa2 kubectl config view --flatten > ~/.kube/config
rm config-doa1
rm config-doa2
```

[Example](kube-example-config.yaml)

From now on, `cka02-master-01` will be accessible under the `doa1` context, and `cka02-master-02` under the `doa2` context.

### Global CIDR Consideration

The `10.0.0.0/8` global network CIDR can cause issues if any component outside the clusters has a `10.X.Y.Z` IP address!

See: https://medium.com/@isalapiyarisi/learned-it-the-hard-way-dont-use-cilium-s-default-pod-cidr-89a78d6df098

Global network CIDR: `10.0.0.0/9`

This way, ranges beyond `10.128.0.0` are excluded and can be freely used, e.g., `10.240.3.58`.
It is important to note that the `10.96.0.0/12` service CIDR is still included.

## Cilium Installation in Both Clusters

It is important to use a unique cluster name and cluster ID; the default (e.g., cluster ID 0) must not be used.

```sh
#cilium install --context=doa1 --set ipv4NativeRoutingCIDR=10.0.0.0/9 --set cluster.name=doa1 --set cluster.id=1
helm --kube-context doa1 install cilium cilium/cilium --version 1.17.3 --namespace kube-system --set ipv4NativeRoutingCIDR=10.0.0.0/9 --set cluster.name=doa1 --set cluster.id=1 --set operator.replicas=1
cilium status --context=doa1 --wait

#cilium install --context=doa2 --set ipv4NativeRoutingCIDR=10.0.0.0/9 --set cluster.name=doa2 --set cluster.id=2
helm --kube-context doa2 install cilium cilium/cilium --version 1.17.3 --namespace kube-system --set ipv4NativeRoutingCIDR=10.0.0.0/9 --set cluster.name=doa2 --set cluster.id=2 --set operator.replicas=1
cilium status --context=doa2 --wait
```

Using Helm is better than `cilium install` because it is easier to modify settings later.
We will take advantage of this.

## Unifying Cilium CA

```sh
kubectl --context=doa2 delete secret cilium-ca -n kube-system
kubectl --context=doa1 get secret -n kube-system cilium-ca -o yaml | kubectl --context=doa2 create -f -
```

If there were a third cluster, we would copy the CA from `doa1` to `doa3` as well.

`doa1` can be considered the "main" cluster:
```
        doa1
       /    \
   doa2      doa3
```

## Enabling Mesh in Both Clusters

There is no load balancer; `NodePort` remains as the service type.

```sh
cilium clustermesh enable --context doa1 --enable-kvstoremesh=false --service-type=NodePort
cilium clustermesh enable --context doa2 --enable-kvstoremesh=false --service-type=NodePort
```

## Connecting the Two Clusters

```sh
cilium clustermesh connect --context doa2 --destination-context doa1
cilium clustermesh status --context doa1 --wait
```

## Running the Test

This takes some time.

```sh
cilium connectivity test --context doa1 --multi-cluster doa2
```

## Example Service Creation in the First Cluster

Using the `service.cilium.io/global: "true"` annotation, the service can be shared.

The pod runs in the first cluster.

```sh
kubectl --context doa1 apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: nginx-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: nginx-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: nginx-test
  annotations:
    service.cilium.io/global: "true"
spec:
  selector:
    app: nginx
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: ClusterIP
EOF
```

## Example Service Creation in the Second Cluster

In the second cluster, there is no pod, only the service.

```sh
kubectl --context doa2 apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: nginx-test
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: nginx-test
  annotations:
    service.cilium.io/global: "true"
    service.cilium.io/shared: "false"
spec:
  selector:
    app: nginx
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
  type: ClusterIP
EOF
```

## Test in the Second Cluster

The pod in the first cluster will serve the request.

```sh
kubectl --context doa2 run curl1 -n nginx-test --restart=Never --rm -it --image=curlimages/curl -- curl -m 10 -v nginx
```

# From Here: Beta (Spoiler: It Doesn't Work)

## Enabling the Multi-Cluster Services API

```sh
kubectl --context doa1 apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/62ede9a032dcfbc41b3418d7360678cb83092498/config/crd/multicluster.x-k8s.io_serviceexports.yaml
kubectl --context doa1 apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/62ede9a032dcfbc41b3418d7360678cb83092498/config/crd/multicluster.x-k8s.io_serviceimports.yaml
helm --kube-context doa1 upgrade cilium cilium/cilium --version 1.17.3 --namespace kube-system --reuse-values --set clustermesh.enableMCSAPISupport=true

kubectl --context doa2 apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/62ede9a032dcfbc41b3418d7360678cb83092498/config/crd/multicluster.x-k8s.io_serviceexports.yaml
kubectl --context doa2 apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/62ede9a032dcfbc41b3418d7360678cb83092498/config/crd/multicluster.x-k8s.io_serviceimports.yaml
helm --kube-context doa2 upgrade cilium cilium/cilium --version 1.17.3 --namespace kube-system --reuse-values --set clustermesh.enableMCSAPISupport=true
```

The installation guide also mentions some custom-built CoreDNS magic, but no thanks.

## Example Service Export

```sh
kubectl --context doa1 apply -f - <<EOF
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata:
   name: nginx
   namespace: nginx-test
EOF
```

## Test Service Export

```sh
kubectl --context doa2 run curl1 -n default --restart=Never --rm -it --image=curlimages/curl -- curl -m 10 -v http://nginx.nginx-test.svc.clusterset.local.
```

It doesn't really work... Maybe the CoreDNS magic is actually necessary after all.
We'll stick to explicit export. Customization is the death of a project.  
To be continued, once it's no longer in beta.
