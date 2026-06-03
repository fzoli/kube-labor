# Intel GPU Plugin Setup (QSV / VAAPI)

Enables `gpu.intel.com/i915` resource in Kubernetes so pods can access Intel GPU for hardware-accelerated video decode (QSV/VAAPI).

## Prerequisites

```bash
# Node Feature Discovery (required for NodeFeatureRule CRD)
helm repo add nfd https://kubernetes-sigs.github.io/node-feature-discovery/charts
helm repo update
helm install nfd nfd/node-feature-discovery \
  --namespace node-feature-discovery --create-namespace \
  --set enableNodeFeatureApi=true

# Intel Device Plugins Operator (required for GpuDevicePlugin CRD)
helm repo add intel https://intel.github.io/helm-charts/
helm install intel-device-plugins-operator intel/intel-device-plugins-operator \
  --namespace kube-system
```

## Fix: Operator OOMKilled

The operator default memory limit (120Mi) is too low and causes CrashLoopBackOff:

```bash
kubectl patch deployment inteldeviceplugins-controller-manager -n kube-system --type=json -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "512Mi"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "256Mi"}
]'

kubectl rollout status deployment/inteldeviceplugins-controller-manager -n kube-system
```

## Install GPU Plugin

```bash
helm install intel-gpu-plugin intel/intel-device-plugins-gpu \
  --namespace kube-system

# Verify
kubectl get nodes -o json | jq '.items[].status.allocatable | with_entries(select(.key | startswith("gpu.intel.com")))'
# Expected: { "gpu.intel.com/i915": "1", "gpu.intel.com/monitoring": "1" }
```

## Patch: Enable Sharing for Multiple Pods

Default `sharedDevNum: 1` means only one pod can use the GPU at a time.
For media transcode workloads (e.g. multiple camera streams), increase it:

```bash
kubectl patch gpudeviceplugin gpudeviceplugin-sample --type=merge -p '{"spec":{"sharedDevNum":10}}'
```

Note: shared mode has no guaranteed bandwidth per pod — suitable for thumbnailing/analytics, not latency-critical workloads.

## Log Rotation

`/var/log/pods` grows unboundedly. Add logrotate config on the node:

```bash
sudo tee /etc/logrotate.d/k8s-pods <<'EOF'
/var/log/pods/*/*.log {
    rotate 3
    daily
    compress
    missingok
    notifempty
    maxsize 100M
    copytruncate
}
EOF
```

## Usage in Pod

```yaml
resources:
  limits:
    gpu.intel.com/i915: "1"
```

The device plugin automatically mounts the correct `/dev/dri/renderD*` device into the container (handles renderD128/renderD129 swap transparently).
