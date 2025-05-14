## Prepare

NOTE: 2 GB RAM is not enough!

Recommended values for labor.sh:
```
MASTER_CPU=4
MASTER_RAM=6G
```

## Install nvme-tcp kernel module

Optional. Only for Replicated Storage (mayastor).

```sh
sudo apt-get install -y linux-modules-extra-$(uname -r)
sudo tee /etc/modules-load.d/openebs.conf <<EOF
nvme-tcp
EOF
sudo modprobe nvme-tcp
```

## Install ZFS, create test zpool and install openebs 

```sh
sudo apt-get install -y zfsutils-linux
sudo truncate -s 10G /zfs-disk.img  # for testing
sudo zpool create zfspv-pool /zfs-disk.img # for testing
sudo apt-get install -y uuid
kubectl label node $(hostname) openebs.io/nodeid=$(uuid)
helm repo add openebs https://openebs.github.io/openebs
helm repo update
helm install openebs --namespace openebs openebs/openebs --create-namespace \
  --set engines.replicated.mayastor.enabled=false
```

### Scale down to 1 node if mayastor is enabled (for testing):

```sh
kubectl scale statefulset openebs-etcd --replicas=1 -n openebs
kubectl set env statefulset/openebs-etcd -n openebs --containers=etcd \
  ETCD_INITIAL_CLUSTER="$(kubectl get statefulset openebs-etcd -n openebs -o jsonpath='{.spec.template.spec.containers[?(@.name=="etcd")].env[?(@.name=="ETCD_INITIAL_CLUSTER")].value}' | cut -d, -f1)" \
  ETCD_INITIAL_CLUSTER_STATE=new
kubectl delete pod -l app.kubernetes.io/name=etcd -n openebs
```

### Wait mayastor to be ready

```sh
kubectl rollout status statefulset.apps/openebs-etcd -n openebs --timeout=3m
kubectl rollout status daemonset/openebs-csi-node -n openebs --timeout=3m # if not deleted
```

## Usage

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-zfspv
parameters:
  recordsize: "128k"
  compression: "off"
  dedup: "off"
  fstype: "zfs"
  poolname: "zfspv-pool"
provisioner: zfs.csi.openebs.io
allowedTopologies:
  - matchLabelExpressions:
      - key: kubernetes.io/hostname
        values:
          - cka02-master-01
```

```yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: csi-zfspv
spec:
  storageClassName: openebs-zfspv
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 4Gi
```

## Check

```sh
kubectl get zv -n openebs
zfs list
```

## Test pod with PVC

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: fio
spec:
  restartPolicy: OnFailure
  containers:
  - name: perfrunner
    image: openebs/tests-fio
    command: ["/bin/bash"]
    args: ["-c", "while true; do sleep 50; done"]
    volumeMounts:
       - mountPath: /datadir
         name: fio-vol
    tty: true
  volumes:
  - name: fio-vol
    persistentVolumeClaim:
      claimName: csi-zfspv
```

### Minimal write test:

```sh
kubectl exec -it fio -- /bin/bash
cd /datadir
echo "hello openebs" > testfile.txt
cat testfile.txt
```
