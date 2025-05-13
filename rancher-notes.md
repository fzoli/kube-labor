```sh
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
kubectl create namespace cattle-system
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=rancher.example.com \
  --set ingress.tls.source=letsEncrypt \
  --set letsEncrypt.email=info@example.com
```

Reset password:

```
kubectl -n cattle-system exec -it $(kubectl -n cattle-system get pods -l app=rancher -o jsonpath="{.items[0].metadata.name}") -- reset-password
```
