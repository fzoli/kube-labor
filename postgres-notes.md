```sh
kubectl create namespace local-path-storage

git clone https://github.com/rancher/local-path-provisioner.git
cd local-path-provisioner

helm install local-path-storage ./deploy/chart/local-path-provisioner --namespace local-path-storage
```

```yaml
#postgres-values.yaml
primary:
  persistence:
    enabled: true
    storageClass: "local-path"
    size: 2Gi

  nodeSelector:
    kubernetes.io/hostname: "cka02-worker-01"

  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                  - "cka02-worker-01"

auth:
  username: myuser
  password: mypassword
  database: mydatabase
```

```sh
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install my-postgres bitnami/postgresql -f postgres-values.yaml
```

```sh
kubectl logs my-postgres-postgresql-0
```

```sh
kubectl run -i --tty debug --image=bitnami/postgresql --restart=Never -- bash
# in container:
psql -h my-postgres-postgresql -U myuser -d mydatabase
```
