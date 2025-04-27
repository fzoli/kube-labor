# Prepare

```sh
./k8s-prepare.sh master
./k8s-prepare.sh net
```

# Activate WireGuard

```sh
sudo apt install wireguard-tools
cilium upgrade --reuse-values --set encryption.enabled=true --set encryption.type=wireguard
```
