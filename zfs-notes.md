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
