# Prepare

```sh
./k8s-prepare.sh master
kubectl taint nodes cka02-master-01 node-role.kubernetes.io/control-plane:NoSchedule-
kubectl label nodes cka02-master-01 ingress-ready=yep
./k8s-prepare.sh net
sudo snap install helm --classic
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

# Install ingress

```sh
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace \
  --set controller.kind=DaemonSet --set controller.hostNetwork=true --set controller.dnsPolicy=ClusterFirstWithHostNet --set controller.service.type="" --set controller.hostPort.enabled=true --set controller.hostPort.http=80 --set controller.hostPort.https=443 \
  --set controller.nodeSelector."ingress-ready"="yep"
```

or

```yaml
#ingress-values.yaml
controller:
  kind: DaemonSet
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  service:
    type: ""
  hostPort:
    enabled: true
    http: 80
    https: 443
  nodeSelector:
    ingress-ready: "yep"
```

```sh
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace -f ingress-values.yaml
```

# Deploy test app (HTTP)

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
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
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
          class: nginx
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
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
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
