# 08 — Validation

> **Prerequisites:** 05–07 complete.

## 8.1 — Node and GPU health

On each GPU worker (or via BCM):

```bash
nvidia-smi
nvidia-smi -q            # ECC errors, retired pages, clocks
nvidia-smi topo -m       # NVLink/NVSwitch topology — compare against the BOM
nvidia-container-cli info
lspci -nn | grep -i -E 'nvidia|ethernet'
ip -br link
ip -br addr
```

```bash
cmsh -c "device list"                       # all nodes [OK]
kubectl get nodes -o wide                   # all Ready
```

Expected `nvidia-smi`: all GPUs visible, driver/CUDA matching the 04
baseline. Record actuals for the site.

- [ ] All expected GPU devices visible; no critical ECC/retired-page alerts
- [ ] NVLink/NVL topology matches the BOM
- [ ] Container runtime sees the GPUs (`nvidia-container-cli info`)

## 8.2 — DNS and service endpoints **[restored]**

```bash
nslookup $FQDN_RUNAI          # → $IP_RUNAI
nslookup $FQDN_KGATEWAY       # → $IP_KGATEWAY
nslookup $FQDN_INFERENCE      # → $IP_INFERENCE
curl -vk https://$FQDN_RUNAI/ | head -5
```

## 8.3 — Workload smoke test

```bash
kubectl get pods -n runai-backend
kubectl get pods -n runai
kubectl get pods -n gpu-operator
kubectl get storageclass
```

> **Field note [client]:** the client's platform validation (08) and
> known-working baseline (12) are the reference for "healthy" — BCM 11,
> k8s 1.34, Run:ai 2.26.x, GPU Operator v26.3.1, NFS CSI 4.13.4. Any
> deviation from these versions is a deliberate decision; log it in 10.

## 8.4 — Node roles **[restored]**

Label nodes for workload scheduling:

```bash
kubectl get nodes
kubectl label nodes <node-name> node-role.kubernetes.io/worker=true
```

- [ ] Every node labeled per its role; GPU nodes carry NVIDIA capacity
      labels (`nvidia.com/gpu.count` etc.)
