```sh
helm install traefik traefik/traefik \
  --namespace ingress-traefik --create-namespace \
  --version 35.1.0 \
  -f traefik-values.yaml
kubectl apply -f traefik-mlkemtls.yaml
kubectl apply -f traefik-redirect.yaml
```

```sh
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.12.0 \
  --set installCRDs=true
kubectl apply -f cert-manager.yaml
```

```sh
kubectl apply -f hello-kubernetes-first.yaml
kubectl apply -f hello-kubernetes-second.yaml
```

```sh
kubectl apply -f hello-kubernetes-ingress.yaml
kubectl apply -f hello-kubernetes-ingress-redirect.yaml
```
