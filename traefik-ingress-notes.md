# Prepare

```sh
./k8s-prepare.sh master
kubectl taint nodes cka02-master-01 node-role.kubernetes.io/control-plane:NoSchedule-
kubectl label nodes cka02-master-01 ingress-ready=yep
./k8s-prepare.sh net
sudo snap install helm --classic
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

# Install ingress

In order to bind to ports 80 and 443, `NET_BIND_SERVICE` is required. However, the Helm chart does not properly use this capability, so we are forced to run as root.

```yaml
#traefik-values.yaml
hostNetwork: true
ports:
  web:
    port: 80
  websecure:
    port: 443

securityContext:
  capabilities:
    drop: [ALL]
    add: [NET_BIND_SERVICE]
  readOnlyRootFilesystem: true
  runAsGroup: 0
  runAsNonRoot: false
  runAsUser: 0
```

```sh
helm install traefik traefik/traefik --namespace ingress-traefik -f traefik-values.yaml
```

# Deploy test app (HTTP)

```yaml
#base-app-deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: example-app
  labels:
    app: example
spec:
  replicas: 2
  selector:
    matchLabels:
      app: example
  template:
    metadata:
      labels:
        app: example
    spec:
      containers:
        - name: example-app
          image: hashicorp/http-echo
          args:
            - "-text=Hello from Kubernetes"
          ports:
            - containerPort: 5678
```

```yaml
#base-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: example-service
spec:
  selector:
    app: example
  ports:
    - protocol: TCP
      port: 80
      targetPort: 5678
  type: ClusterIP
```

```yaml
#base-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: test.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: example-service
                port:
                  number: 80
```

# Setup cert manager

```sh
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.12.0 \
  --set installCRDs=true
```

# Deploy ACME cert manager

```yaml
#cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: info@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
```

# Deploy test app (HTTPS)

```yaml
# tls-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - test.example.com
      secretName: example-tls
  rules:
    - host: test.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: example-service
                port:
                  number: 80
```

The `example.com` domain must be replaced both in the email addresses and in the hostnames.
