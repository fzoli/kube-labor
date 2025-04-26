# Prepare

```sh
./k8s-prepare.sh master
kubectl taint nodes cka02-master-01 node-role.kubernetes.io/control-plane:NoSchedule-
./k8s-prepare.sh net
sudo snap install helm --classic
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace \
  --set controller.kind=DaemonSet --set controller.hostNetwork=true --set controller.dnsPolicy=ClusterFirstWithHostNet --set controller.service.type="" --set controller.hostPort.enabled=true --set controller.hostPort.http=80 --set controller.hostPort.https=443
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
