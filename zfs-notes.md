NOTE: 2 GB RAM is not enough!

```sh
sudo apt-get install -y zfsutils-linux
sudo truncate -s 10G /zfs-disk.img  # for testing
sudo zpool create zfspv-pool /zfs-disk.img # for testing
sudo apt-get install -y uuid
kubectl label node $(hostname) openebs.io/nodeid=$(uuid)
helm repo add openebs https://openebs.github.io/openebs
helm repo update
helm install openebs --namespace openebs openebs/openebs --create-namespace
```

Scale down to 1 node:

```sh
kubectl scale statefulset openebs-etcd --replicas=1 -n openebs
kubectl get statefulset openebs-etcd -n openebs -o yaml > openebs-etcd-sts.yaml
# edit openebs-etcd-sts.yaml then apply:
#         - name: ETCD_INITIAL_CLUSTER_STATE
#           value: new
#         - name: ETCD_INITIAL_CLUSTER
#           value: openebs-etcd-0=http://openebs-etcd-0.openebs-etcd-headless.openebs.svc.cluster.local:2380
kubectl delete pod -l app.kubernetes.io/name=etcd -n openebs
```

If no `nvme_tcp` kernel module available:

```sh
kubectl delete daemonset openebs-csi-node -n openebs
```

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

```sh
kubectl get zv -n openebs
zfs list
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: fio
spec:
  restartPolicy: Never
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
