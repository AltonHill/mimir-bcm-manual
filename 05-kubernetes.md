# 05 — Kubernetes Deployment

> **Prerequisites:** 04 complete (GPU image validated on hardware).

## 5.1 — Generate the installer config

```bash
cm-kubernetes-setup
```

Walk the dialog:

| Prompt | Selection |
|---|---|
| Action | Deploy |
| Kubernetes version | `$K8S_VERSION` (lab dialog showed 1.35; baseline is 1.34 — pick deliberately) |
| DockerHub registry mirror | Leave blank |
| Cluster name | `$CLUSTER_NAME`-k8s (lab: `runai-cluster`) |
| Domain name | `cluster.local` |
| External FQDN | `$FQDN_KGATEWAY` |
| Service network / netmask | `$K8S_SERVICE_NET` / `$K8S_SERVICE_MASK` |
| Pod network / netmask | `$K8S_POD_NET` / `$K8S_POD_MASK` |
| Expose API externally | No |
| Internal network | `internalnet` |
| Master nodes | `k8s-ctrl-1`, `k8s-ctrl-2`, `k8s-ctrl-3` |
| Worker categories | `$CAT_GPU` (plus `$CAT_WRK` if using VM/CPU workers) |
| Etcd nodes | all three control-plane nodes (odd count) |
| Etcd spool directory | `/var/lib/etcd` (verify — not `/var/lib/etc`) |
| API proxy port | `10443` |
| CNI | Tigera Operator — Calico (recommended) |
| Kyverno | No |
| Operators | See full set below — select all 14 |
| DGX network policies | No |
| MetalLB mode | L2 ARP advertisement |
| Kgateway IP | `$IP_KGATEWAY` |
| MetalLB pools | Leave empty |
| Expose gateways externally | Yes |
| Permissions Manager | Yes |
| StorageClass | Local Path enabled + default (NFS takes over in 07) |
| Local path | `/cm/shared/apps/Kubernetes/$CLUSTER_NAME-k8s/var/volumes` |
| Grafana persistent storage | Yes |
| Save config | `/root/cm-kubernetes-setup.conf` (default) |

### Full operator set **[restored]**

> The client kept the complete BCM 11 operator selection from the
> proven reference install. Don't trim this before deployment —
> removing components can invalidate the working baseline. Treat
> later removal as its own optimization project with dependency and
> rollback validation.

- [ ] NVIDIA GPU Operator (`$GPU_OPERATOR_VERSION`; `cdi.enabled` +
      `nfd.enabled`; use the preinstalled BCM image driver)
- [ ] Network Operator (`$NET_OPERATOR_VERSION`; `nfd.enabled` +
      `sriovNetworkOperator.enabled`; no predefined GPU config, no DGX
      network policies)
- [ ] MetalLB (L2 ARP; Kgateway IP `$IP_KGATEWAY`)
- [ ] Kgateway
- [ ] Knative Operator (Serving)
- [ ] Kubeflow Training Operator
- [ ] Kubernetes MPI Operator
- [ ] LeaderWorkerSet Operator
- [ ] Kubernetes Metrics Server
- [ ] Kubernetes State Metrics
- [ ] Prometheus Operator Stack
- [ ] Prometheus Adapter
- [ ] Grafana Operator
- [ ] NIM Operator

> **Field note [client]:** the client kept Network Operator + SR-IOV for
> parity with the working install — validate against the site's NICs
> (client had Cisco UCS VICs; DGX nodes differ). Do not apply DGX-specific
> network policy.

## 5.2 — Deploy and monitor

```bash
cm-kubernetes-setup -c /root/cm-kubernetes-setup.conf
```

In a second session:

```bash
tail -f /var/log/cm-kubernetes-setup.log
watch kubectl get pods -n gpu-operator   # ignore initial restarts; wait for Running/Completed
```

## 5.3 — Validate

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get storageclass
kubectl get ipaddresspools,l2advertisements -A
FIRST_GPU_WORKER="${GPU_WORKERS%% *}"
kubectl describe node "$FIRST_GPU_WORKER" | grep -A8 -i nvidia
```

- [ ] All nodes `Ready`; GPU nodes show NVIDIA labels/capacity
- [ ] `gpu-operator` pods Running/Completed
- [ ] MetalLB pools and L2 advertisements present
