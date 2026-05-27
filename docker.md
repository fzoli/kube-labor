Ingress test

```sh
docker run -d \       
  --name test-nginx \
  --label "traefik.enable=true" \
  --label "traefik.http.routers.test-nginx.rule=Host(\`test-nginx.example.com\`)" \
  --label "traefik.http.routers.test-nginx.entrypoints=web" \
  --label "traefik.http.services.test-nginx.loadbalancer.server.port=80" \
  nginx
```