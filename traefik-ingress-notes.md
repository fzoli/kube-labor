# Prepare

```sh
./k8s-prepare.sh master
kubectl taint nodes cka02-master-01 node-role.kubernetes.io/control-plane:NoSchedule-
kubectl label nodes cka02-master-01 ingress-ready=true
./k8s-prepare.sh net
sudo snap install helm --classic
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

# Install ingress

In order to bind to ports 80 and 443, `NET_BIND_SERVICE` is required. However, the Helm chart does not properly use this capability, so we are forced to run as root.

```yaml
#traefik-values.yaml
nodeSelector:
  ingress-ready: "true"

hostNetwork: true

ports:
  web:
    port: 80
  websecure:
    port: 443
    hostPort: 443
    http3:
      enabled: true
      advertisedPort: 443

service:
  single: false

# Enable dashboard without exposing it
ingressRoute:
  dashboard:
    enabled: true

# Custom image that supports TLS curve X25519MLKEM768
image:
  repository: progfarkas/pqtraefik
  tag: v3.0.1-2
versionOverride: v3.0.1

# Enable default namespace
providers:
  kubernetesCRD:
    enabled: true
    namespaces:
      - ingress-traefik
      - default
  kubernetesIngress:
    allowExternalNameServices: true

# Configure logger plugin
experimental:
  plugins:
    traefiklogger:
      moduleName: github.com/fzoli/traefiklogger
      version: v0.10.0

# Allow bind to port 80 and 443
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
helm install traefik traefik/traefik \
  --namespace ingress-traefik --create-namespace \
  --version 35.1.0 \
  -f traefik-values.yaml
```

# Access Traefik dashboard

```sh
kubectl port-forward $(kubectl get pods --selector "app.kubernetes.io/name=traefik" --output=name -n ingress-traefik) 8085:8080 -n ingress-traefik
```

Open:
http://127.0.0.1:8085/dashboard/

# Deploy test app (base without HTTPS)

The `example.com` domain should be replaced in both email addresses and hostnames.

For testing without a DNS server, you can use `nip.io`\
If your IP address is `1.2.3.4`, simply replace `test.example.com` with `test.1-2-3-4.nip.io`

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

# Deploy TLS option

```yaml
# mlkemtls.yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  namespace: default
  name: mlkemtls
spec:
  sniStrict: false
  minVersion: VersionTLS13
  curvePreferences:
    - X25519MLKEM768
    - CurveP521
    - CurveP384
```

# Deploy logger middleware

```yaml
#loggermw.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  namespace: default
  name: jsonlogger
spec:
  plugin:
    traefiklogger:
      Enabled: true
      Name: json-logger
      LogFormat: json
```

# Deploy HTTPS ingress

```yaml
# tls-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls.options: default-mlkemtls@kubernetescrd
    traefik.ingress.kubernetes.io/router.middlewares: default-jsonlogger@kubernetescrd
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


# Redirect to HTTPS

Use it like `traefik.ingress.kubernetes.io/router.middlewares: default-redirect-to-https@kubernetescrd` in the HTTP middleware.

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  namespace: default
  name: redirect-to-https
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

# Proxy

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ipify-proxy-service
  namespace: default
spec:
  type: ExternalName
  externalName: api.ipify.org. # FQDN
  ports:
    - port: 443
      targetPort: 443
      protocol: TCP
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ipify-proxy-headers
  namespace: default
spec:
  headers:
    customRequestHeaders:
      Host: "api.ipify.org"
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ipify-proxy-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls.options: default-mlkemtls@kubernetescrd
    traefik.ingress.kubernetes.io/router.middlewares: default-ipify-proxy-headers@kubernetescrd,default-jsonlogger@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - ipify.example.com
      secretName: ipify-tls
  rules:
    - host: ipify.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ipify-proxy-service
                port:
                  number: 443
```

# TLS passthrough

## External service

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: ipify-route-tcp
  namespace: default
spec:
  entryPoints:
    - websecure
  routes:
  - match: HostSNI(`ipify.example.com`)
    services:
    - name: ipify-proxy-service
      port: 443
  tls:
    passthrough: true
```

## Internal service

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: argocd-route-tcp
  namespace: default
spec:
  entryPoints:
    - websecure
  routes:
  - match: HostSNI(`argocd.example.com`)
    services:
    - name: argocd-server
      port: 443
  tls:
    passthrough: true
    certResolver: letsencrypt-prod
    domains:
      - main: "argocd.example.com"
        sans:
          - "*.example.com"
    secretName: argocd-server-tls # used by pods
```
